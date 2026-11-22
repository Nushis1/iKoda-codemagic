import KodaCore
import LocalAuthentication
import SwiftUI

extension AppModel {
    /// Always scans: Face ID, with the passcode when it fails, as the rest of iOS does.
    func authenticate(_ reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
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

/// What a locked playlist shows until it is unlocked: its cover blurred behind a lock, and the
/// Face ID prompt at once (the button asks again after a cancel).
struct LockedPlaylistView: View {
    let playlist: UserPlaylist
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 28) {
            PlaylistCover(playlist: playlist, size: 220, cornerRadius: 24)
                .blur(radius: 28)
                .overlay {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 96, height: 96)
                        .glassEffect(.regular, in: .circle)
                }
            VStack(spacing: 6) {
                Text(playlist.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Locked")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { _ = await app.unlock(playlist.id) }
            } label: {
                Label("Unlock with Face ID", systemImage: "faceid")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // The same cover, large and soft, so the page takes the playlist's colours.
            PlaylistCover(playlist: playlist, size: 400, cornerRadius: 0)
                .blur(radius: 90)
                .opacity(0.45)
                .ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { _ = await app.unlock(playlist.id) }
    }
}
