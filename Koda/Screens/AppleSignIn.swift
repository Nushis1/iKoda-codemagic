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

    /// Closes the code prompt without a code. A sign-in that is only waiting for Apple can't be stopped.
    func cancelCode() {
        if state == .needsCode { submit(code: nil) }
    }

    func clearFailure() {
        if case .failed = state { state = .signedOut }
    }

    func signOut() {
        account = nil
        state = .signedOut
    }
}

/// The window that opens from "Log In": the Apple ID and password, then the code Apple sent, in the same window.
struct AppleIDSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("koda.renewal.appleID") private var email = ""
    @State private var password = ""
    @State private var code = ""

    private var signIn: AppleSignIn { app.appleSignIn }

    var body: some View {
        NavigationStack {
            Form {
                switch signIn.state {
                case .needsCode:
                    Section {
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        Button("Confirm") {
                            signIn.submit(code: code)
                            code = ""
                        }
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: {
                        Text("Two-factor code")
                    } footer: {
                        Text("Apple sent a code to a device or phone number you trust. Type it here.")
                    }
                case .signingIn:
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Talking to Apple…")
                        }
                    }
                default:
                    Section {
                        TextField("Apple ID (e-mail)", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                        Button("Log In") {
                            let id = email.trimmingCharacters(in: .whitespacesAndNewlines)
                            let secret = password
                            password = ""
                            signIn.signIn(email: id, password: secret)
                        }
                        .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    } footer: {
                        Text("Use a separate Apple ID made for this, not your main one. The password goes to Apple through the tool and isn't saved.")
                    }
                    if case .failed(let message) = signIn.state {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Apple ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        signIn.cancelCode()
                        signIn.clearFailure()
                        dismiss()
                    }
                    .disabled(signIn.state == .signingIn)
                }
            }
            .interactiveDismissDisabled(signIn.isBusy)
            .onChange(of: signIn.state) { _, state in
                if case .signedIn = state { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
