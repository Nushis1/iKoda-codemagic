import KodaCore
import LocalAuthentication
import SwiftUI

extension AppModel {
    /// Always scans: Face ID, with the passcode when it fails, as the rest of iOS does.
    func authenticate(_ reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }

    /// True once Liked Songs is open, the same way.
    func unlockLiked() async -> Bool {
        if likedUnlocked { return true }
        guard await authenticate("Unlock Liked Songs") else { return false }
        likedUnlocked = true
        return true
    }

    /// True once this playlist is open; a playlist already opened since Koda was last in the background doesn't ask again.
    func unlock(_ id: UUID) async -> Bool {
        if unlockedPlaylists.contains(id) { return true }
        guard await authenticate("Unlock this playlist") else { return false }
        unlockedPlaylists.insert(id)
        return true
    }
}

/// Lock with Face ID / Remove the lock, in a playlist's menus. Both scan first: locking to confirm
/// it is you (a device with no passcode fails here, and could never open it again), removing so
/// that a long press on its tile can't undo the lock for anyone holding the phone.
struct PlaylistLockMenuItem: View {
    let playlist: UserPlaylist
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library

    var body: some View {
        Button(playlist.isLocked ? "Remove Face ID Lock" : "Lock with Face ID",
               systemImage: playlist.isLocked ? "lock.open" : "lock") {
            Task {
                let locking = !playlist.isLocked
                guard await app.authenticate(locking ? "Confirm locking this playlist" : "Confirm removing the lock") else { return }
                library.setLocked(playlist.id, locking)
                app.unlockedPlaylists.remove(playlist.id)
            }
        }
    }
}

/// Lock with Face ID / Remove the lock, in the menu of Liked Songs; scans first, as the playlists' does.
struct LikedLockMenuItem: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library

    var body: some View {
        Button(library.likedLocked ? "Remove Face ID Lock" : "Lock with Face ID",
               systemImage: library.likedLocked ? "lock.open" : "lock") {
            Task {
                let locking = !library.likedLocked
                guard await app.authenticate(locking ? "Confirm locking Liked Songs" : "Confirm removing the lock") else { return }
                library.setLikedLocked(locking)
                app.likedUnlocked = false
            }
        }
    }
}

/// What a locked playlist shows until it is unlocked.
struct LockedPlaylistView: View {
    let playlist: UserPlaylist
    @Environment(AppModel.self) private var app

    var body: some View {
        LockedView(name: playlist.name, unlock: { await app.unlock(playlist.id) }) {
            PlaylistCover(playlist: playlist, size: 400, cornerRadius: 0)
        }
    }
}

/// What a locked screen shows until it is unlocked: black, with its cover only as a faint glow,
/// and a lock to tap. Nothing asks until it is tapped, so locking from the screen's own menu
/// doesn't scan twice in a row.
struct LockedView<Cover: View>: View {
    let name: String
    let unlock: () async -> Bool
    @ViewBuilder let cover: Cover
    @Environment(AppModel.self) private var app

    /// What the device unlocks with, for the line under the title.
    private var method: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return switch context.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: "your passcode"
        }
    }

    var body: some View {
        Button {
            Task { _ = await unlock() }
        } label: {
            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 46))
                Text("Tap to unlock")
                    .font(.title3.bold())
                Text("Using \(method)")
                    .foregroundStyle(.white.opacity(0.6))
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            ZStack {
                Color.black
                cover
                    .blur(radius: 90)
                    .opacity(0.3)
            }
            .ignoresSafeArea()
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .onAppear { app.showsLockScreen = true }
        .onDisappear { app.showsLockScreen = false }
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityLabel("\(name) is locked")
        .accessibilityHint("Unlocks with \(method)")
    }
}
