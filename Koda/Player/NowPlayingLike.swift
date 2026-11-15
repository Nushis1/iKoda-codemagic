import KodaCore
import MediaPlayer

/// The heart on the Lock Screen and in Control Center's Now Playing card.
///
/// iOS draws that card itself, so the app can't place a button of its own in it. What it can do
/// is register the system's `likeCommand` (Settings → Playback → Like on Lock Screen turns it off); iOS then shows its own like control for the song
/// (filled in while the song is liked) and calls back when it is tapped. Where the control sits,
/// and how it looks, is up to iOS.
@MainActor
final class NowPlayingLike {
    private let player: Player
    private let library: Library
    private let settings: AppSettings

    init(player: Player, library: Library, settings: AppSettings) {
        self.player = player
        self.library = library
        self.settings = settings
        let command = MPRemoteCommandCenter.shared().likeCommand
        command.addTarget { @Sendable [weak self] event in
            // For a feedback command, `isNegative` means "undo": the song is already liked.
            let undo = (event as? MPFeedbackCommandEvent)?.isNegative ?? false
            Task { @MainActor in self?.set(liked: !undo) }
            return .success
        }
        refresh()
        track()
    }

    private func set(liked: Bool) {
        guard let song = player.current else { return }
        library.setLiked(song, liked)
        refresh()
    }

    /// Shows the song's current state: enabled while something plays, active while it is liked.
    private func refresh() {
        let command = MPRemoteCommandCenter.shared().likeCommand
        // Turned off in Settings, or nothing playing: a disabled command is left off the card.
        guard settings.showsLockScreenLike, let song = player.current else {
            command.isEnabled = false
            command.isActive = false
            return
        }
        let liked = library.isLiked(song)
        command.isEnabled = true
        command.isActive = liked
        command.localizedTitle = liked ? "Remove from Liked" : "Like"
        command.localizedShortTitle = liked ? "Unlike" : "Like"
    }

    /// Re-reads the state whenever the song changes, it is liked or unliked anywhere in the app,
    /// or the setting is switched.
    private func track() {
        withObservationTracking {
            _ = settings.showsLockScreenLike
            if let song = player.current { _ = library.isLiked(song) }
        } onChange: { [weak self] in
            // Called just before the change lands, so wait a turn to read the new value.
            Task { @MainActor in
                self?.refresh()
                self?.track()
            }
        }
    }
}
