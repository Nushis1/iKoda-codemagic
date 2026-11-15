import KodaRenewerKit
import SwiftUI

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
        Task {
            do {
                account = try await Renewer.signIn(email: email, password: password) { [weak self] request in
                    await self?.ask(request)
                }
                state = .signedIn(email)
            } catch {
                account = nil
                state = .failed(error.localizedDescription)
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
        state = .signingIn
        pending?.resume(returning: answer)
        pending = nil
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
                developerError = error.localizedDescription
            }
            isReading = false
        }
    }

    func signOut() {
        account = nil
        developer = nil
        developerError = nil
        state = .signedOut
    }
}
