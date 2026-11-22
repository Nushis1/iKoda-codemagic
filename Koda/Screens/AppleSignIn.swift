import KodaCore
import KodaRenewerKit
import SwiftUI
import UIKit

/// The state of signing in to an Apple ID through the renewal tool. The password is handed to the
/// tool and not kept; the signed-in account lives here, in memory, until signed out or until Koda
/// quits. Keeping the session between launches comes in a later stage.
@Observable
final class AppleSignIn {
    enum State: Equatable {
        case signedOut
        case signingIn
        /// Apple wants to know how the code should reach the person: the trusted devices or a text.
        case needsMethod
        /// Apple sent a code and wants it typed.
        case needsCode
        case signedIn(String)
        case failed(String)
    }

    private(set) var state = State.signedOut
    /// What Apple offered the last time it asked (the trusted phone numbers, mainly).
    private(set) var request: TwoFactorRequest?
    private var account: RenewerAccount?
    private var email = ""
    /// Signing Koda into a file, stage 4: made, not installed.
    enum Signing: Equatable {
        case idle
        case working
        case done(URL)
        case failed(String)
    }
    private(set) var signing = Signing.idle
    /// The person cancelled the two-factor question: the library then reports "aborting" as an error,
    /// which is not one, so it is not shown.
    private var cancelled = false
    /// What the signed-in Apple ID has in the developer service, once read.
    private(set) var developer: DeveloperInfo?
    private(set) var developerError: String?
    private(set) var isReading = false
    private var pending: CheckedContinuation<TwoFactorAnswer?, Never>?

    var isAskingForMethod: Bool { state == .needsMethod }
    var isAskingForCode: Bool { state == .needsCode }

    var isBusy: Bool {
        switch state {
        case .signingIn, .needsMethod, .needsCode: true
        default: false
        }
    }

    func signIn(email: String, password: String) {
        guard !isBusy else { return }
        state = .signingIn
        cancelled = false
        self.email = email
        Task {
            do {
                account = try await Renewer.signIn(email: email, password: password) { [weak self] request in
                    await self?.ask(request)
                }
                state = .signedIn(email)
            } catch {
                account = nil
                state = cancelled ? .signedOut : .failed(Self.plain(error.localizedDescription))
            }
        }
    }

    /// Called while the tool waits for the person; the screen shows the matching question.
    private func ask(_ request: TwoFactorRequest) async -> TwoFactorAnswer? {
        await withCheckedContinuation { continuation in
            pending = continuation
            self.request = request
            state = request.needsMethod ? .needsMethod : .needsCode
        }
    }

    /// The person's answer, or nil when they cancelled.
    func answer(_ answer: TwoFactorAnswer?) {
        var answer = answer
        if case .code(let digits) = answer {
            let clean = digits.trimmingCharacters(in: .whitespacesAndNewlines)
            answer = clean.isEmpty ? nil : .code(clean)
        }
        if answer == nil { cancelled = true }
        state = .signingIn
        pending?.resume(returning: answer)
        pending = nil
    }

    /// What the library says is long and full of file names. The few things the person can act on are
    /// put plainly (a wrong password above all); anything else is cut down to its first line.
    static func plain(_ raw: String) -> String {
        let text = raw.lowercased()
        let wrong = ["incorrect", "-20101", "-22406", "invalid apple id", "invalid credentials", "wrong password"]
        if wrong.contains(where: { text.contains($0) }) {
            return "Incorrect Apple ID or password."
        }
        if text.contains("locked") || text.contains("-20209") {
            return "This Apple ID is locked. Unlock it at iforgot.apple.com, then try again."
        }
        if text.contains("too many") || text.contains("429") {
            return "Apple says there were too many attempts. Wait a while and try again."
        }
        if text.contains("anisette") {
            return "Koda couldn't reach the server that vouches for this device with Apple. Try again in a while."
        }
        if ["timed out", "offline", "network", "internet", "connection"].contains(where: { text.contains($0) }) {
            return "Koda couldn't reach Apple. Check the connection and try again."
        }
        // Whatever else: the first message, without the "F /path/file.rs:12" the library appends.
        let withoutPaths = raw.replacingOccurrences(of: #"\s*F?\s*/\S+\.rs(:\d+)*"#, with: "", options: .regularExpression)
        let first = withoutPaths.split(separator: "•").first.map(String.init) ?? withoutPaths
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The sign-in failed." : String(trimmed.prefix(160))
    }

    /// Something the form can't send, such as an empty field.
    func report(_ message: String) {
        guard !isBusy else { return }
        state = .failed(message)
    }

    /// Reads the developer account (teams, certificates, app-ID counts). Changes nothing.
    func readDeveloperAccount() {
        guard let account, !isReading else { return }
        isReading = true
        developerError = nil
        Task {
            do {
                developer = try await account.developerInfo()
            } catch {
                developer = nil
                developerError = Self.plain(error.localizedDescription)
            }
            isReading = false
        }
    }

    /// Makes a certificate and profile for this iPhone on the Apple ID, signs a copy of Koda and packs it
    /// as a .ipa the person can save. Nothing is installed. It uses the account's limits (a certificate,
    /// App IDs, a device), so it asks first and isn't meant to be repeated.
    func signOwnApp() {
        guard let account, signing != .working else { return }
        signing = .working
        let email = email
        Task {
            do {
                guard let udid = ProvisioningProfile.current()?.devices.first else {
                    throw RenewerError.failed("Koda can't read this iPhone's identifier from the signature it was installed with.")
                }
                let signed = try await account.signApp(email: email, udid: udid,
                                                       deviceName: "Koda \(UIDevice.current.model)",
                                                       appPath: Bundle.main.bundlePath)
                let ipa = try await Task.detached { try Self.pack(app: URL(fileURLWithPath: signed)) }.value
                signing = .done(ipa)
            } catch {
                signing = .failed(Self.plain(error.localizedDescription))
            }
        }
    }

    /// A signed app folder as a .ipa: a Payload folder holding the app, zipped.
    nonisolated private static func pack(app: URL) throws -> URL {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("KodaSigned-\(UUID().uuidString)", isDirectory: true)
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        try files.createDirectory(at: payload, withIntermediateDirectories: true)
        try files.copyItem(at: app, to: payload.appendingPathComponent(app.lastPathComponent))
        let ipa = work.appendingPathComponent("Koda-signed.ipa")
        var coordination: NSError?
        var failure: Error?
        // The system zips a folder it is asked to read for uploading; the zip holds the folder itself.
        NSFileCoordinator().coordinate(readingItemAt: payload, options: .forUploading, error: &coordination) { zip in
            do {
                try files.copyItem(at: zip, to: ipa)
            } catch {
                failure = error
            }
        }
        if let coordination { throw coordination }
        if let failure { throw failure }
        return ipa
    }

    func signOut() {
        account = nil
        developer = nil
        developerError = nil
        signing = .idle
        state = .signedOut
    }
}
