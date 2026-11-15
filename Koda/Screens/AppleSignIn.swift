import KodaRenewerKit
import SwiftUI

/// The state of signing in to an Apple ID through the renewal tool (stage 2). The password is
/// handed to the tool and not kept; the signed-in account lives here, in memory, until signed out
/// or until the screen goes away. Keeping the session between launches comes in a later stage.
@Observable
final class AppleSignIn {
    enum State: Equatable {
        case signedOut
        case signingIn
        case needsCode
        case signedIn(String)
        case failed(String)
    }

    private(set) var state = State.signedOut
    private var account: RenewerAccount?
    private var pendingCode: CheckedContinuation<String?, Never>?

    var isAskingForCode: Bool { state == .needsCode }

    var isBusy: Bool {
        switch state {
        case .signingIn, .needsCode: true
        default: false
        }
    }

    func signIn(email: String, password: String) {
        guard !isBusy else { return }
        state = .signingIn
        Task {
            do {
                account = try await Renewer.signIn(email: email, password: password) { [weak self] in
                    await self?.askForCode()
                }
                state = .signedIn(email)
            } catch {
                account = nil
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Called while the tool waits for the code Apple sent; the screen shows the prompt.
    private func askForCode() async -> String? {
        await withCheckedContinuation { continuation in
            pendingCode = continuation
            state = .needsCode
        }
    }

    /// The person typed the code, or cancelled with nil.
    func submit(code: String?) {
        let clean = code?.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .signingIn
        pendingCode?.resume(returning: clean?.isEmpty == false ? clean : nil)
        pendingCode = nil
    }

    func signOut() {
        account = nil
        state = .signedOut
    }
}
