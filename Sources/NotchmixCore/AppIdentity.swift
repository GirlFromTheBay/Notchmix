import AppKit
import Darwin
import Foundation

/// The user-facing app that an audio process belongs to.
public struct AppIdentity: Hashable, Sendable {
    /// Stable key for settings: the bundle identifier when there is one.
    public let id: String
    public let name: String
    /// Path of the owning `.app`, used to load its icon. `nil` for bare tools.
    public let bundlePath: String?

    public init(id: String, name: String, bundlePath: String?) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
    }
}

/// Raw process-table lookups. Syscalls only, safe from any thread.
public enum ProcessInspector {
    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = pid_t(bitPattern: info.pbi_ppid)
        return parent > 0 && parent != pid ? parent : nil
    }

    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` is what Activity Monitor
    /// and TCC use to attribute an XPC service to its app. It is the only way
    /// to tie `com.apple.WebKit.GPU` (whose parent is launchd) back to Safari.
    /// Looked up at runtime so a missing symbol degrades to the parent walk.
    private static let responsibility: ResponsibilityFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                                 "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    public static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let responsibility else { return nil }
        let responsible = responsibility(pid)
        return responsible > 0 && responsible != pid ? responsible : nil
    }

    /// The outermost `.app` on an executable path, so that
    /// `Chrome.app/Contents/Frameworks/…/Chrome Helper.app/…` maps to Chrome.
    public static func outermostAppBundle(inExecutablePath path: String) -> String? {
        var prefix = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + component
            if component.hasSuffix(".app") { return prefix }
        }
        return nil
    }

    /// The pid itself, then its responsible process, then its ancestors.
    static func lineage(of pid: pid_t, maxDepth: Int = 8) -> [pid_t] {
        var chain: [pid_t] = [pid]
        if let responsible = responsiblePID(of: pid) { chain.append(responsible) }
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parentPID(of: current), parent > 1 else { break }
            if !chain.contains(parent) { chain.append(parent) }
            current = parent
        }
        return chain
    }
}

/// Maps an audio-producing pid to the app a person would recognise.
///
/// Browser, Electron and Steam audio comes from helper processes; WebKit audio
/// comes from an XPC service. Each is resolved to its parent `.app` so the
/// mixer shows one row per app instead of one per process.
public final class AppIdentityResolver {
    struct BundleInfo {
        let identity: AppIdentity
        /// False for agents and helpers (`LSUIElement` / `LSBackgroundOnly`).
        let isUserFacing: Bool
    }

    private struct CachedResolution {
        let executablePath: String?
        let identity: AppIdentity?
    }

    private var bundleCache: [String: BundleInfo?] = [:]
    private var pidCache: [pid_t: CachedResolution] = [:]

    public init() {}

    /// Resolves `pid`, reusing the previous answer while the pid still runs
    /// the same executable (which also guards against pid reuse).
    public func resolve(pid: pid_t) -> AppIdentity? {
        resolve(pid: pid, executablePath: ProcessInspector.executablePath(of: pid))
    }

    /// As `resolve(pid:)`, for a caller that already read the path.
    public func resolve(pid: pid_t, executablePath path: String?) -> AppIdentity? {
        if let cached = pidCache[pid], cached.executablePath == path {
            return cached.identity
        }
        let identity = resolveUncached(pid: pid, executablePath: path)
        pidCache[pid] = CachedResolution(executablePath: path, identity: identity)
        return identity
    }

    /// Drops cached answers for processes that no longer exist.
    public func retainOnly(pids: Set<pid_t>) {
        pidCache = pidCache.filter { pids.contains($0.key) }
    }

    private func resolveUncached(pid: pid_t, executablePath ownPath: String?) -> AppIdentity? {
        let ownBundle = ownPath.flatMap(pathBundle(forExecutable:))

        // A normal app, or a helper nested inside one.
        if let ownBundle, ownBundle.isUserFacing, let identity = Self.visible(ownBundle.identity) {
            return identity
        }

        // No bundle, or an agent-style bundle: look for the app that owns it.
        // A hidden system agent is skipped rather than accepted, so a Safari
        // web app resolves to itself and not to the system's "Web App" host.
        let owners = ProcessInspector.lineage(of: pid).dropFirst()
        for candidate in owners {
            if let info = ProcessInspector.executablePath(of: candidate).flatMap(pathBundle(forExecutable:)),
               let identity = Self.visible(info.identity) {
                return identity
            }
        }
        // Some apps (Steam) re-exec from a path with no `.app` in it;
        // LaunchServices still remembers which bundle was launched.
        for candidate in owners {
            if let info = launchedBundle(of: candidate), let identity = Self.visible(info.identity) {
                return identity
            }
        }

        // A top-level menu bar app is its own owner.
        if let ownBundle { return Self.visible(ownBundle.identity) }

        // A bare executable. System daemons are not something to mix, and
        // skipping them here keeps LaunchServices out of the common case.
        guard let ownPath, !Self.isSystemPath(ownPath) else { return nil }
        if let info = launchedBundle(of: pid) { return Self.visible(info.identity) }
        let name = (ownPath as NSString).lastPathComponent
        return AppIdentity(id: "path:" + ownPath, name: name, bundlePath: nil)
    }

    private func pathBundle(forExecutable path: String) -> BundleInfo? {
        ProcessInspector.outermostAppBundle(inExecutablePath: path).flatMap(bundleInfo(at:))
    }

    private func launchedBundle(of pid: pid_t) -> BundleInfo? {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              url.pathExtension == "app" else { return nil }
        return bundleInfo(at: url.path)
    }

    func bundleInfo(at path: String) -> BundleInfo? {
        if let cached = bundleCache[path] { return cached }
        let info = Self.readBundleInfo(at: path)
        bundleCache[path] = info
        return info
    }

    static func readBundleInfo(at path: String) -> BundleInfo? {
        guard let bundle = Bundle(path: path) else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let localized = bundle.localizedInfoDictionary ?? [:]
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let rawName = (localized["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String)
            ?? (localized["CFBundleName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? fileName
        let name = cleaned(rawName)
        let identifier = bundle.bundleIdentifier ?? ("path:" + path)
        let isAgent = flag(info["LSUIElement"]) || flag(info["LSBackgroundOnly"])
        return BundleInfo(
            identity: AppIdentity(id: identifier, name: name.isEmpty ? fileName : name, bundlePath: path),
            isUserFacing: !isAgent
        )
    }

    /// Some apps pad their display name with invisible direction marks,
    /// which would otherwise sort them to the end of the list.
    static func cleaned(_ name: String) -> String {
        let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2060}\u{FEFF}")
            .union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        return name.trimmingCharacters(in: invisible)
    }

    /// Info.plist booleans are written as `true`, `1`, `"1"` or `"YES"`.
    static func flag(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.boolValue
        case let string as String: return ["1", "true", "yes"].contains(string.lowercased())
        default: return false
        }
    }

    /// Hides system UI agents (Control Center, Siri, Notification Center)
    /// while keeping the stock apps, Safari's cryptex location and Finder.
    static func visible(_ identity: AppIdentity) -> AppIdentity? {
        guard let path = identity.bundlePath, path.hasPrefix("/System/") else { return identity }
        if path.contains("/System/Applications/") { return identity }
        if path.hasSuffix("/CoreServices/Finder.app") { return identity }
        return nil
    }

    static func isSystemPath(_ path: String) -> Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
            .contains { path.hasPrefix($0) }
    }
}
