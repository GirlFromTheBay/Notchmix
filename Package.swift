// swift-tools-version:6.0
import PackageDescription

// Notchmix: per-app volume in the menu bar.
// Pure Apple frameworks, no third-party dependencies.
let package = Package(
    name: "Notchmix",
    platforms: [.macOS("26.0")],
    targets: [
        // C11 real-time render callback. Kept in C so the audio thread can
        // never reach the Swift runtime (no allocation, no locks, no ARC).
        .target(name: "CAudioRender"),

        // Core Audio control plane: discovery, taps, devices, permission.
        .target(
            name: "NotchmixCore",
            dependencies: ["CAudioRender"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),

        // SwiftUI panel and its observable model.
        .target(name: "NotchmixUI", dependencies: ["NotchmixCore"]),

        // The app itself: starts the menu bar controller and nothing else.
        .executableTarget(name: "Notchmix", dependencies: ["NotchmixUI"]),

        // Developer tool, never bundled: lists what discovery sees and can
        // render the panel to a PNG for layout checks.
        .executableTarget(name: "NotchmixProbe", dependencies: ["NotchmixCore", "NotchmixUI"]),

        .testTarget(name: "NotchmixTests", dependencies: ["NotchmixCore", "NotchmixUI", "CAudioRender"]),
    ],
    swiftLanguageModes: [.v5]
)
