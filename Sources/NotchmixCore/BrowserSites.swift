import Foundation
import IOKit.pwr_mgt

/// Works out which websites are playing audio in Safari.
///
/// Safari plays every tab through one shared audio process, so a tap can
/// only ever see "Safari". Two other facts identify the tab:
///
/// - macOS keeps a "WebKit Media Playback" power assertion on behalf of the
///   web content process of each page that is playing.
/// - Safari's scripting interface reports each tab's URL and the pid of the
///   web content process behind it.
///
/// Matching the two gives the sites. It names them; it cannot give them
/// separate volumes, because their audio is already mixed when it reaches
/// Core Audio.
public enum BrowserSites {
    public static let safariBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    public struct Tab: Equatable, Sendable {
        public let pid: pid_t
        public let url: String
    }

    public enum Result: Equatable, Sendable {
        case sites([String])
        /// The user declined to let this app ask Safari.
        case notPermitted
        case unavailable
    }

    /// Pids of web content processes that are playing media right now.
    /// A public IOKit query; needs no permission.
    public static func playingWebContentPIDs() -> Set<pid_t> {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return []
        }
        var pids: Set<pid_t> = []
        for assertion in byProcess.values.joined() {
            guard let name = assertion[kIOPMAssertionNameKey] as? String,
                  isWebContentPlayback(assertionName: name),
                  let pid = assertion["AssertionOnBehalfOfPID"] as? NSNumber else { continue }
            pids.insert(pid.int32Value)
        }
        return pids
    }

    static func isWebContentPlayback(assertionName name: String) -> Bool {
        name.contains("com.apple.WebKit.WebContent") && name.hasSuffix("WebKit Media Playback")
    }

    /// Asks Safari for its tabs. Blocks; shows the system consent prompt the
    /// first time. Call from a background queue.
    static func tabs(of bundleID: String) throws -> [Tab] {
        let everyTab = AppleEvents.every("bTab", of: AppleEvents.every("cwin", of: .null()))
        let urls = AppleEvents.leaves(
            of: try AppleEvents.get(AppleEvents.property("pURL", of: everyTab), from: bundleID, timeout: 3)
        )
        // "wpid": the pid of the WebContent process backing the tab.
        let pids = AppleEvents.leaves(
            of: try AppleEvents.get(AppleEvents.property("wpid", of: everyTab), from: bundleID, timeout: 3)
        )
        // Two requests, so a tab opened or closed in between shifts the
        // pairing. Rather than mislabel, report nothing this round.
        guard urls.count == pids.count else { return [] }
        return zip(pids, urls).compactMap { pid, url in
            guard let url = url.stringValue, pid.int32Value > 0 else { return nil }
            return Tab(pid: pid.int32Value, url: url)
        }
    }

    /// The short names of the sites playing audio in `bundleID`.
    public static func playingSites(in bundleID: String) -> Result {
        let playing = playingWebContentPIDs()
        guard !playing.isEmpty else { return .sites([]) }

        switch AppleEvents.permission(for: bundleID, askUser: true) {
        case .granted: break
        case .denied: return .notPermitted
        case .undetermined, .targetNotRunning: return .unavailable
        }
        guard let tabs = try? tabs(of: bundleID) else { return .unavailable }
        return .sites(siteNames(of: tabs, playing: playing))
    }

    static func siteNames(of tabs: [Tab], playing: Set<pid_t>) -> [String] {
        var names: [String] = []
        for tab in tabs where playing.contains(tab.pid) {
            if let name = SiteName.short(for: tab.url), !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }
}

/// Turns a URL into the name a person would call the site.
public enum SiteName {
    /// Second-level labels that are part of the public suffix, as in
    /// `bbc.co.uk` or `abc.net.au`.
    private static let suffixLabels: Set<String> = ["co", "com", "net", "org", "ac", "gov", "edu", "or", "ne"]

    /// `https://www.youtube.com/watch?v=1` gives `youtube`;
    /// `https://app.roll20.net/editor` gives `roll20`.
    public static func short(for urlString: String) -> String? {
        guard let host = URLComponents(string: urlString)?.host?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        // An IP address or a single-label host has no better name than itself.
        guard labels.count >= 2, labels.contains(where: { $0.contains(where: \.isLetter) }) else { return host }

        var nameIndex = labels.count - 2
        if labels.count >= 3, labels[labels.count - 1].count == 2, suffixLabels.contains(labels[nameIndex]) {
            nameIndex -= 1
        }
        return labels[nameIndex]
    }
}
