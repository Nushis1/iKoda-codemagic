import Foundation
#if canImport(KodaRenewer)
import KodaRenewer
#endif

public enum RenewerError: LocalizedError, Sendable {
    /// This build has no Rust core (Mac, or a build made without it).
    case unavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The renewal tool isn't part of this build."
        case .failed(let message): message
        }
    }
}

/// A signed-in Apple ID. Keep it as long as it is needed; it signs out when released.
public final class RenewerAccount: @unchecked Sendable {
    #if canImport(KodaRenewer)
    fileprivate let handle: OpaquePointer

    fileprivate init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        koda_renewer_account_free(handle)
    }
    #endif
}

/// Koda's own renewal tool: the Rust core (Apple ID, certificate, signing), seen from Swift.
public enum Renewer {
    /// True in builds that carry the Rust core.
    public static var isAvailable: Bool {
        #if canImport(KodaRenewer)
        true
        #else
        false
        #endif
    }

    /// 1 when the core answers; 0 when it isn't there. Using it here also makes sure the linker keeps the core.
    public static func ping() -> Int {
        #if canImport(KodaRenewer)
        Int(koda_renewer_ping())
        #else
        0
        #endif
    }

    /// Signs in to an Apple ID. `code` is asked for the two-factor code and returns what the person
    /// typed, or nil to cancel. It runs while the sign-in waits.
    public static func signIn(email: String, password: String,
                              code: @escaping @Sendable () async -> String?) async throws -> RenewerAccount {
        #if canImport(KodaRenewer)
        try await withCheckedThrowingContinuation { continuation in
            // The Rust call blocks until the sign-in is over, so it gets a thread of its own.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try blockingSignIn(email: email, password: password, code: code) })
            }
        }
        #else
        throw RenewerError.unavailable
        #endif
    }
}

#if canImport(KodaRenewer)
private let startRenewer: Bool = koda_renewer_init()

/// What the C callback needs: the Swift closure that asks for the code.
private final class CodeBox: @unchecked Sendable {
    let ask: @Sendable () async -> String?
    init(_ ask: @escaping @Sendable () async -> String?) { self.ask = ask }
}

private final class Answer: @unchecked Sendable {
    var value: String?
}

/// Called by Rust, on its own thread, when Apple wants a code. Waits for the person to type it.
private let askForCode: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int) -> Bool = { user, buffer, capacity in
    guard let user, let buffer, capacity > 1 else { return false }
    let box = Unmanaged<CodeBox>.fromOpaque(user).takeUnretainedValue()
    let semaphore = DispatchSemaphore(value: 0)
    let answer = Answer()
    Task {
        answer.value = await box.ask()
        semaphore.signal()
    }
    semaphore.wait()
    guard let code = answer.value, !code.isEmpty else { return false }
    let bytes = Array(code.utf8.prefix(capacity - 1))
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return true
}

/// A folder inside the app's own space where the tool keeps its sign-in state. The current folder,
/// which the library would otherwise use, is read-only on an iPhone.
private func storageDirectory() throws -> String {
    let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let folder = base.appendingPathComponent("KodaRenewer", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.path
}

private func blockingSignIn(email: String, password: String,
                            code: @escaping @Sendable () async -> String?) throws -> RenewerAccount {
    _ = startRenewer
    let directory: String
    do {
        directory = try storageDirectory()
    } catch {
        throw RenewerError.failed("Koda couldn't make a folder for the sign-in state: \(error.localizedDescription)")
    }
    let box = Unmanaged.passRetained(CodeBox(code))
    defer { box.release() }
    var message = [CChar](repeating: 0, count: 1024)
    let handle = email.withCString { emailPointer in
        password.withCString { passwordPointer in
            directory.withCString { directoryPointer in
                message.withUnsafeMutableBufferPointer { buffer in
                    koda_renewer_login(emailPointer, passwordPointer, directoryPointer, askForCode, box.toOpaque(),
                                       buffer.baseAddress, buffer.count)
                }
            }
        }
    }
    guard let handle else {
        let reason = String(cString: message)
        throw RenewerError.failed(reason.isEmpty ? "The sign-in failed." : reason)
    }
    return RenewerAccount(handle: handle)
}
#endif
