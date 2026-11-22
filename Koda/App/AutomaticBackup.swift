import CryptoKit
import Foundation
import KodaCore
import Security
import UIKit

/// The automatic copy of a library, kept in the Keychain.
///
/// Deleting an app on iOS deletes its files, but not the Keychain items it made, so a copy kept
/// there is still on the phone after Koda is deleted and installed again. (iCloud would also
/// do it, but it needs a paid developer account; the Keychain does not.) The copy is the same
/// JSON as Back Up Library, compressed and cut into pieces, because a Keychain item is meant
/// for small values. It stays on this iPhone: never synced and not carried to a new one.
///
/// It is only found again by a copy of Koda signed by the same team with the same bundle id,
/// which is what installing again with the same Apple ID gives.
nonisolated enum KeychainBackup {
    nonisolated struct Info: Codable, Equatable, Sendable {
        var date: Date
        var profile: String
        var liked: Int
        var plays: Int
        /// How many profiles the copy holds; nil in a copy from before it kept them all.
        var profiles: Int?
        /// How many pieces the copy is in, and their size together.
        var chunks = 0
        var bytes = 0
        /// Of the backup JSON before it was compressed: tells a copy that is already saved.
        var checksum: String
    }

    /// What the copy holds: the roster and each profile's library backup, by profile id.
    /// A copy from before it kept every profile is a plain library backup (`Library.backupData`).
    nonisolated struct AllProfiles: Codable, Sendable {
        static let format = "koda-ios-profiles"
        var format = AllProfiles.format
        var version = 1
        var roster: Data
        var libraries: [String: Data]
    }

    private static let service = "ivors.Koda.automaticBackup"
    private static let chunkSize = 128 * 1024
    private static let meta = "meta"

    private static func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private static func put(_ data: Data, account: String) -> Bool {
        var query = query(account)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        query[kSecValueData as String] = data
        // After the first unlock so a background save works; this device only, so it never syncs.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func get(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What is saved, without reading the copy itself.
    static func info() -> Info? {
        guard let data = get(meta) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Info.self, from: data)
    }

    /// Replace the saved copy with `backup`. The pieces go in first and the description last, so
    /// a save cut short leaves the old copy readable. Returns what was saved, nil if the Keychain refused.
    static func write(_ backup: Data, info: Info) -> Info? {
        guard let packed = try? (backup as NSData).compressed(using: .lzfse) as Data else { return nil }
        let pieces = stride(from: 0, to: packed.count, by: chunkSize).map { packed[$0..<min($0 + chunkSize, packed.count)] }
        let previous = self.info()?.chunks ?? 0
        for (index, piece) in pieces.enumerated() where !put(Data(piece), account: "chunk.\(index)") { return nil }
        var saved = info
        saved.chunks = pieces.count
        saved.bytes = packed.count
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let description = try? encoder.encode(saved), put(description, account: meta) else { return nil }
        if previous > pieces.count {
            for index in pieces.count..<previous { SecItemDelete(query("chunk.\(index)") as CFDictionary) }
        }
        return saved
    }

    /// The saved backup JSON, if every piece is there and it still adds up.
    static func read() -> Data? {
        guard let info = info() else { return nil }
        var packed = Data()
        for index in 0..<info.chunks {
            guard let piece = get("chunk.\(index)") else { return nil }
            packed.append(piece)
        }
        guard let backup = try? (packed as NSData).decompressed(using: .lzfse) as Data,
              checksum(backup) == info.checksum else { return nil }
        return backup
    }

    static func delete() {
        SecItemDelete(query() as CFDictionary)
    }
}

/// Keeps `KeychainBackup` up to date and brings it back on a fresh install.
@MainActor
final class AutomaticBackup {
    enum RestoreError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            "Koda couldn't read the automatic backup. The iPhone may be locked, or Koda was installed with a different Apple ID."
        }
    }

    private let library: Library
    private let roster: ProfileRoster
    private let settings: AppSettings
    private var savedChecksum: String?
    private var isSaving = false

    /// Fixed, so the same library always gives the same bytes and an unchanged one isn't saved again.
    /// A restore ignores the date inside the backup.
    private static let backupDate = Date(timeIntervalSince1970: 0)

    init(library: Library, roster: ProfileRoster, settings: AppSettings) {
        self.library = library
        self.roster = roster
        self.settings = settings
    }

    private var libraryIsEmpty: Bool {
        library.liked.isEmpty && library.history.isEmpty && library.songStats.isEmpty && library.recent.isEmpty
            && library.userPlaylists.isEmpty && library.albums.isEmpty && library.playlists.isEmpty
            && library.artists.isEmpty && library.dailyListening.isEmpty
    }

    /// Nothing worth keeping yet: a new install must not overwrite the copy it is about to restore.
    private var isFresh: Bool {
        libraryIsEmpty && roster.profiles.count == 1 && !roster.active.isSignedIn && roster.active.name.isEmpty
    }

    /// Every profile: the roster (names, faces, which accounts they are signed in to) and each one's
    /// library, which carries its search history, playlist locks and blocked phrases. The other
    /// profiles' libraries are read from their folders; the one in use from memory.
    /// shortcut: reads every other profile's library on each save, fine for a few profiles.
    private func profilesBackup() -> Data? {
        guard let rosterData = roster.backupData() else { return nil }
        var libraries: [String: Data] = [:]
        for profile in roster.profiles {
            let source = profile.id == roster.activeID ? library : Library(directory: roster.folder(for: profile.id))
            libraries[profile.id.uuidString] = source.backupData(at: Self.backupDate)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(AllProfiles(roster: rosterData, libraries: libraries))
    }

    var latest: KeychainBackup.Info? { KeychainBackup.info() }

    /// Save the library, if it changed since the last copy. Called as the app goes to the background,
    /// so the copy is in the Keychain before the app can be deleted from the Home Screen.
    func save() {
        guard settings.keepsAutomaticBackup, !isSaving, !isFresh,
              let backup = profilesBackup() else { return }
        let checksum = KeychainBackup.checksum(backup)
        guard checksum != (savedChecksum ?? KeychainBackup.info()?.checksum) else { return }
        let info = KeychainBackup.Info(date: Date(), profile: roster.active.displayName, liked: library.liked.count,
                                       plays: library.history.count, profiles: roster.profiles.count, checksum: checksum)
        isSaving = true
        // Compressing and writing takes a moment; ask iOS to let it finish after the app has left the screen.
        let application = UIApplication.shared
        let task = BackgroundTask()
        task.id = application.beginBackgroundTask(withName: "Koda automatic backup") {
            application.endBackgroundTask(task.id)
            task.id = .invalid
        }
        Task.detached(priority: .utility) { [weak self] in
            let saved = KeychainBackup.write(backup, info: info)
            await MainActor.run {
                self?.isSaving = false
                if saved != nil { self?.savedChecksum = checksum }
                application.endBackgroundTask(task.id)
                task.id = .invalid
            }
        }
    }

    /// Bring back the saved copy: its profiles (those here that it lacks stay, unless `discardingOthers`)
    /// and each one's library, the active one in memory. The caller moves the app to the active
    /// profile if it changed (`AppModel.activeProfileChanged`).
    func restore(discardingOthers: Bool = false) throws {
        guard let backup = KeychainBackup.read() else { throw RestoreError.unreadable }
        if let all = try? JSONDecoder().decode(AllProfiles.self, from: backup), all.format == AllProfiles.format {
            let before = roster.profiles.map(\.id)
            guard roster.restore(from: all.roster, keepingOthers: !discardingOthers) else { throw RestoreError.unreadable }
            library.open(directory: roster.folder(for: roster.activeID))
            for profile in roster.profiles {
                guard let data = all.libraries[profile.id.uuidString] else { continue }
                if profile.id == roster.activeID {
                    try library.restore(from: data)
                } else {
                    let other = Library(directory: roster.folder(for: profile.id))
                    try other.restore(from: data)
                    other.flush(force: true)
                }
            }
            // The empty profile a new install starts with has nothing in it worth keeping.
            let now = Set(roster.profiles.map(\.id))
            for id in before where !now.contains(id) { try? FileManager.default.removeItem(at: roster.folder(for: id)) }
        } else {
            try library.restore(from: backup)
        }
        savedChecksum = KeychainBackup.info()?.checksum
    }

    /// A new install of Koda, with a copy left by an earlier one: take it back, so nothing has to be
    /// searched for or listened to again. Does nothing once the welcome has been seen or the library has anything in it.
    func restoreOnNewInstall() {
        guard !settings.hasSeenOnboarding, settings.keepsAutomaticBackup, isFresh,
              KeychainBackup.info() != nil else { return }
        try? restore(discardingOthers: true)
    }

    func delete() {
        KeychainBackup.delete()
        savedChecksum = nil
    }
}

private final class BackgroundTask: @unchecked Sendable {
    var id = UIBackgroundTaskIdentifier.invalid
}
