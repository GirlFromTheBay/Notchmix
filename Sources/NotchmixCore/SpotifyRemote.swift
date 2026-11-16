import Foundation

/// Transport control for the Spotify desktop app.
public enum SpotifyRemote {
    public static let bundleID = "com.spotify.client"

    /// Posted by Spotify to every app whenever playback changes. Reading it
    /// needs no permission; `userInfo["Player State"]` is `Playing`,
    /// `Paused` or `Stopped`.
    public static let stateNotification = Notification.Name("com.spotify.client.PlaybackStateChanged")

    public enum Command: Sendable {
        case previous
        case playPause
        case next

        /// Event IDs from Spotify's scripting dictionary (suite `spfy`).
        var eventID: String {
            switch self {
            case .previous: return "Prev"
            case .playPause: return "PlPs"
            case .next: return "Next"
            }
        }
    }

    private static let queue = DispatchQueue(label: "Notchmix.SpotifyRemote", qos: .userInitiated)

    public static var isRunning: Bool { AppleEvents.isRunning(bundleID) }

    /// Sends a command. The first use shows the system's prompt asking
    /// whether this app may control Spotify.
    public static func send(_ command: Command) {
        queue.async {
            guard AppleEvents.permission(for: bundleID, askUser: true) == .granted else { return }
            try? AppleEvents.send(class: "spfy", id: command.eventID, to: bundleID, timeout: 5)
        }
    }

    public static func isPlaying(in notification: Notification) -> Bool? {
        (notification.userInfo?["Player State"] as? String).map { $0 == "Playing" }
    }
}
