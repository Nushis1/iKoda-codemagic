import KodaCore
import LocalAuthentication
import SwiftUI

extension AppModel {
    /// Face ID, with the passcode when it fails, as the rest of iOS does; true once this playlist is open.
    func unlock(_ id: UUID) async -> Bool {
        if unlockedPlaylists.contains(id) { return true }
        let ok = (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock this playlist")) == true
        if ok { unlockedPlaylists.insert(id) }
        return ok
    }
}

/// Lock with Face ID / Remove the lock, in a playlist's menus.
struct PlaylistLockMenuItem: View {
    let playlist: UserPlaylist
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library

    var body: some View {
        Button(playlist.isLocked ? "Remove Face ID Lock" : "Lock with Face ID",
               systemImage: playlist.isLocked ? "lock.open" : "lock") {
            Task {
                if playlist.isLocked {
                    // Asks first, or a long press on its tile would undo the lock for anyone holding the phone.
                    guard await app.unlock(playlist.id) else { return }
                    library.setLocked(playlist.id, false)
                } else if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
                    // A device with no passcode could never open it again, so it is not locked.
                    library.setLocked(playlist.id, true)
                    app.unlockedPlaylists.remove(playlist.id)
                }
            }
        }
    }
}

/// What a locked playlist shows until it is unlocked; asks at once, and again from the button.
struct LockedPlaylistView: View {
    let playlist: UserPlaylist
    @Environment(AppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label(playlist.name, systemImage: "lock.fill")
        } description: {
            Text("This playlist is locked.")
        } actions: {
            Button("Unlock") { Task { _ = await app.unlock(playlist.id) } }
                .buttonStyle(.borderedProminent)
        }
        .task { _ = await app.unlock(playlist.id) }
    }
}
