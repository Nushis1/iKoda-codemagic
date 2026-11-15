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

/// What Apple offers for two-factor sign-in, at the moment it asks.
public struct TwoFactorRequest: Sendable, Decodable {
    public struct Number: Sendable, Decodable, Identifiable {
        public let id: UInt32
        public let label: String
        public let mode: String
    }

    /// True while the way the code is to be sent hasn't been chosen yet.
    public let needsMethod: Bool
    /// True once a text message was chosen.
    public let sms: Bool
    public let selectedNumber: UInt32?
    /// The trusted phone numbers Apple can text.
    public let numbers: [Number]
}

/// The person's answer to a `TwoFactorRequest`.
public enum TwoFactorAnswer: Sendable {
    case devices
    case sms(UInt32)
    case resend
    case code(String)

    fileprivate var wire: String {
        switch self {
        case .devices: "devices"
        case .sms(let id): "sms:\(id)"
        case .resend: "resend"
        case .code(let digits): "code:\(digits)"
        }
    }
}

/// What an Apple ID has in the developer service: read-only, stage 3.
public struct DeveloperInfo: Sendable, Decodable {
    public struct Certificate: Sendable, Decodable, Identifiable {
        public let name: String?
        public let serialNumber: String?
        public let machine: String?
        public let status: String?
        public let expires: String?
        public var id: String { serialNumber ?? name ?? UUID().uuidString }
    }

    public struct AppIDs: Sendable, Decodable {
        public let used: Int
        public let max: Int?
        public let available: Int?
    }

    public struct Team: Sendable, Decodable, Identifiable {
        public let name: String?
        public let teamId: String
        public let type: String?
        public let status: String?
        public let certificates: [Certificate]
        public let appIDs: AppIDs
        public var id: String { teamId }
    }

    public let teams: [Team]
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

    /// Reads the account's developer teams, certificates and app-ID counts. Changes nothing.
    public func developerInfo() async throws -> DeveloperInfo {
        #if canImport(KodaRenewer)
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.blockingDeveloperInfo() })
            }
        }
        #else
        throw RenewerError.unavailable
        #endif
    }

    #if canImport(KodaRenewer)
    private func blockingDeveloperInfo() throws -> DeveloperInfo {
        var answer = [CChar](repeating: 0, count: 64 * 1024)
        var message = [CChar](repeating: 0, count: 1024)
        let ok = answer.withUnsafeMutableBufferPointer { out in
            message.withUnsafeMutableBufferPointer { error in
                koda_renewer_account_info(handle, out.baseAddress, out.count, error.baseAddress, error.count)
            }
        }
        guard ok else {
            let reason = String(cString: message)
            throw RenewerError.failed(reason.isEmpty ? "The developer account couldn't be read." : reason)
        }
        do {
            return try JSONDecoder().decode(DeveloperInfo.self, from: Data(String(cString: answer).utf8))
        } catch {
            throw RenewerError.failed("The developer account answer wasn't understood: \(error.localizedDescription)")
        }
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

    /// Signs in to an Apple ID. `ask` is called when Apple wants something for two-factor sign-in (how
    /// to send the code, then the code) and returns the person's answer, or nil to cancel.
    public static func signIn(email: String, password: String,
                              ask: @escaping @Sendable (TwoFactorRequest) async -> TwoFactorAnswer?) async throws -> RenewerAccount {
        #if canImport(KodaRenewer)
        try await withCheckedThrowingContinuation { continuation in
            // The Rust call blocks until the sign-in is over, so it gets a thread of its own.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try blockingSignIn(email: email, password: password, ask: ask) })
            }
        }
        #else
        throw RenewerError.unavailable
        #endif
    }
}

#if canImport(KodaRenewer)
private let startRenewer: Bool = koda_renewer_init()

/// What the C callback needs: the Swift closure that asks the person.
private final class AskBox: @unchecked Sendable {
    let ask: @Sendable (TwoFactorRequest) async -> TwoFactorAnswer?
    init(_ ask: @escaping @Sendable (TwoFactorRequest) async -> TwoFactorAnswer?) { self.ask = ask }
}

private final class Reply: @unchecked Sendable {
    var value: TwoFactorAnswer?
}

/// Called by Rust, on its own thread, when Apple wants something. Waits for the person to answer.
private let askPerson: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Bool = { user, request, buffer, capacity in
    guard let user, let request, let buffer, capacity > 1 else { return false }
    let box = Unmanaged<AskBox>.fromOpaque(user).takeUnretainedValue()
    guard let parsed = try? JSONDecoder().decode(TwoFactorRequest.self, from: Data(String(cString: request).utf8)) else { return false }
    let semaphore = DispatchSemaphore(value: 0)
    let reply = Reply()
    Task {
        reply.value = await box.ask(parsed)
        semaphore.signal()
    }
    semaphore.wait()
    guard let answer = reply.value else { return false }
    let bytes = Array(answer.wire.utf8.prefix(capacity - 1))
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
                            ask: @escaping @Sendable (TwoFactorRequest) async -> TwoFactorAnswer?) throws -> RenewerAccount {
    _ = startRenewer
    let directory: String
    do {
        directory = try storageDirectory()
    } catch {
        throw RenewerError.failed("Koda couldn't make a folder for the sign-in state: \(error.localizedDescription)")
    }
    let box = Unmanaged.passRetained(AskBox(ask))
    defer { box.release() }
    var message = [CChar](repeating: 0, count: 1024)
    let handle = email.withCString { emailPointer in
        password.withCString { passwordPointer in
            directory.withCString { directoryPointer in
                message.withUnsafeMutableBufferPointer { buffer in
                    koda_renewer_login(emailPointer, passwordPointer, directoryPointer, askPerson, box.toOpaque(),
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
