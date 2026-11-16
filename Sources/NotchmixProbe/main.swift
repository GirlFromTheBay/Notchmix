import AppKit
import NotchmixCore
import NotchmixUI
import SwiftUI

// Developer tool. Not part of the app bundle.
//
//   NotchmixProbe                  list the audio processes discovery sees
//   NotchmixProbe --snapshot FILE  render the panel with sample data to a PNG
//   NotchmixProbe --menu-bar-check open the real panel for a second and
//                                      report the window the system built
//
// No mode creates a tap, so none needs or asks for any permission.

func listAudioApps() {
    let catalog = AudioProcessCatalog()
    let processes = catalog.processes()
    let groups = catalog.groups(from: processes)

    print("Audio capture permission: \(AudioCapturePermission.status)")
    print("Web content processes playing media: \(BrowserSites.playingWebContentPIDs().sorted())")
    print("HAL process objects: \(processes.count), resolved to \(groups.count) app(s)\n")
    for group in groups.sorted(by: { $0.identity.name < $1.identity.name }) {
        let state = group.isPlaying ? "PLAYING" : "idle   "
        print("\(state)  \(group.identity.name)  [\(group.identity.id)]  objects=\(group.processObjects.count)")
    }

    let resolved = Set(groups.flatMap(\.processObjects))
    let hidden = processes.filter { !resolved.contains($0.objectID) }
    if !hidden.isEmpty {
        print("\nNot shown (system daemons and agents):")
        for process in hidden {
            let path = ProcessInspector.executablePath(of: process.pid) ?? "?"
            let owner = ProcessInspector.responsiblePID(of: process.pid)
                .flatMap(ProcessInspector.executablePath(of:))
                .map { "  <- " + ($0 as NSString).lastPathComponent } ?? ""
            print("  pid \(process.pid)  \((path as NSString).lastPathComponent)\(owner)\(process.isRunningOutput ? "  (playing)" : "")")
        }
    }
}

@MainActor
func sampleModel() -> MixerModel {
    let apps = [
        ("com.apple.Music", "Music", "/System/Applications/Music.app"),
        ("com.apple.Safari", "Safari", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"),
        ("com.apple.TV", "TV", "/System/Applications/TV.app"),
    ].map {
        MixerApp(
            id: $0.0, name: $0.1, bundlePath: $0.2, isPlaying: true,
            detail: $0.0 == "com.apple.Safari" ? "youtube, roll20" : nil
        )
    }

    return MixerModel(
        preview: MixerSnapshot(
            apps: apps,
            output: OutputState(name: "MacBook Pro Speakers", volume: 0.6, isMuted: false, hasVolumeControl: true)
        ),
        settings: [
            "com.apple.Safari": AppSetting(volume: 0.35),
            "com.apple.TV": AppSetting(volume: 0.7, isMuted: true),
        ],
        spotifyRunning: true
    )
}

@MainActor
func renderSnapshot(to path: String) {
    let model = sampleModel()

    // Offscreen drawing has no window server behind it, so there is no glass.
    // A flat backdrop close to the panel's usual tone stands in for it.
    let isLight = CommandLine.arguments.contains("--light")
    let backdrop = isLight ? Color(white: 0.86) : Color(white: 0.2)
    let host = NSHostingView(
        rootView: MixerPanel(model: model)
            .background(backdrop)
            .environment(\.colorScheme, isLight ? .light : .dark)
    )
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()

    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        fatalError("Could not create a bitmap for the panel")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode the panel as PNG")
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(Int(size.width))x\(Int(size.height)) pt panel to \(path)")
    } catch {
        fatalError("Could not write \(path): \(error)")
    }
}

/// Runs the app's own menu bar controller with sample data and no audio
/// engine, opens its panel for a moment, and reports what the system built.
@MainActor
final class MenuBarCheck: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController(model: sampleModel())
        self.controller = controller
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            controller.togglePanel()
            // Sample twice while the popover animates in, to see it move.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self.sample("during open", controller) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.report(controller) }
        }
    }

    private func sample(_ label: String, _ controller: MenuBarController) {
        guard let window = controller.panelWindow else {
            print("  \(label): no window yet")
            return
        }
        print("  \(label): alpha=\(String(format: "%.2f", window.alphaValue)) frame=\(Int(window.frame.width))x\(Int(window.frame.height))")
    }

    private func report(_ controller: MenuBarController) {
        guard controller.isPanelShown, let window = controller.panelWindow else {
            print("RESULT: the panel did not open")
            exit(1)
        }
        sample("settled", controller)
        print("Panel window: \(window.className) level=\(window.level.rawValue) key=\(window.isKeyWindow) " +
              "shadow=\(window.hasShadow) opaque=\(window.isOpaque)")
        if let screen = window.screen {
            print("  top edge \(Int(screen.frame.maxY - window.frame.maxY)) pt below the top of the screen")
        }
        print("View hierarchy:")
        dump(window.contentView?.superview ?? window.contentView, depth: 0)

        controller.togglePanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            print("RESULT: panel opened at \(Int(window.frame.width))x\(Int(window.frame.height)) pt and " +
                  (controller.isPanelShown ? "DID NOT close" : "closed"))
            exit(controller.isPanelShown ? 1 : 0)
        }
    }

    private func dump(_ view: NSView?, depth: Int) {
        guard let view, depth < 6 else { return }
        var line = String(repeating: "  ", count: depth + 1) + view.className
        line += " \(Int(view.frame.width))x\(Int(view.frame.height))"
        if let layer = view.layer, layer.cornerRadius > 0 { line += " radius=\(layer.cornerRadius)" }
        if let effect = view as? NSVisualEffectView { line += " material=\(effect.material.rawValue)" }
        if let glass = view as? NSGlassEffectView { line += " glass radius=\(glass.cornerRadius)" }
        print(line)
        view.subviews.forEach { dump($0, depth: depth + 1) }
    }
}

if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"),
   CommandLine.arguments.count > flag + 1 {
    let path = CommandLine.arguments[flag + 1]
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        renderSnapshot(to: path)
    }
} else if CommandLine.arguments.contains("--menu-bar-check") {
    setvbuf(stdout, nil, _IONBF, 0)
    MainActor.assumeIsolated {
        let check = MenuBarCheck()
        let application = NSApplication.shared
        application.delegate = check
        application.setActivationPolicy(.accessory)
        application.run()
    }
} else {
    listAudioApps()
}
