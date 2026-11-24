import Foundation

/// Spotify constants shared with `MediaPlayer`, which does the sending.
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

    public static func isPlaying(in notification: Notification) -> Bool? {
        (notification.userInfo?["Player State"] as? String).map { $0 == "Playing" }
    }
}

/// Supported desktop media players with Apple Events transport control.
public enum MediaPlayer: String, CaseIterable, Equatable, Sendable {
    case spotify = "com.spotify.client"
    case appleMusic = "com.apple.Music"

    public var bundleID: String { rawValue }

    public var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Music"
        }
    }

    public var eventClass: String {
        switch self {
        case .spotify: return "spfy"
        case .appleMusic: return "hook"
        }
    }

    public var stateNotification: Notification.Name {
        switch self {
        case .spotify: return SpotifyRemote.stateNotification
        case .appleMusic: return Notification.Name("com.apple.Music.playerInfo")
        }
    }

    public var isRunning: Bool { AppleEvents.isRunning(bundleID) }

    private static let queue = DispatchQueue(label: "Notchmix.MediaPlayer", qos: .userInitiated)

    /// Sends a command. The first use shows the system's prompt asking
    /// whether this app may control the player.
    public func send(_ command: SpotifyRemote.Command) {
        let bundleID = bundleID
        let eventClass = eventClass
        let eventID = command.eventID
        Self.queue.async {
            guard AppleEvents.permission(for: bundleID, askUser: true) == .granted else { return }
            try? AppleEvents.send(class: eventClass, id: eventID, to: bundleID, timeout: 5)
        }
    }

    public static func activePlayer(
        spotifyRunning: Bool,
        spotifyPlaying: Bool,
        musicRunning: Bool,
        musicPlaying: Bool,
        preferred: MediaPlayer? = nil
    ) -> MediaPlayer? {
        let spotifyActive = spotifyRunning && spotifyPlaying
        let musicActive = musicRunning && musicPlaying
        if spotifyActive && !musicActive { return .spotify }
        if musicActive && !spotifyActive { return .appleMusic }
        if spotifyRunning && musicRunning {
            if let preferred { return preferred }
            return .spotify
        }
        if spotifyRunning { return .spotify }
        if musicRunning { return .appleMusic }
        return nil
    }
}
