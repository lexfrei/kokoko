import Foundation
import KokokoCore

public enum SessionError: Error {
    case timeout(command: UInt8, requestID: UInt16)
    case deviceError(TEStatus, message: String?)
    case notAGreetReply
}

extension SessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timeout(let command, _):
            return "device did not answer command \(command) in time"
        case .deviceError(let status, let message):
            let name = switch status {
            case .ok: "ok"
            case .error: "error"
            case .commandNotFound: "command not found"
            case .badRequest: "bad request"
            case .specificError(let byte): "command-specific error \(byte)"
            case .specificSuccess(let byte): "command-specific success \(byte)"
            case .unknown(let byte): "unknown status \(byte)"
            }
            let text = "device answered \(name)"
            guard let message, !message.isEmpty else { return text }
            return "\(text): \(message)"
        case .notAGreetReply:
            return "device sent an unreadable greet reply"
        }
    }
}

/// Request/response matching over one MIDIWire, per the TE frame protocol.
public actor SysExSession {
    private let wire: any MIDIWire
    private let identityCode: UInt8
    private var requestID: UInt16
    private var pending: [UInt16: CheckedContinuation<TEFrame, Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<FileEvent>.Continuation] = [:]
    private var logHandler: (@Sendable (String) -> Void)?

    public init(wire: any MIDIWire, identityCode: UInt8) {
        self.wire = wire
        self.identityCode = identityCode
        self.requestID = UInt16.random(in: 0..<4095)
        wire.setMessageHandler { [weak self] bytes in
            guard let self else { return }
            Task { await self.handleIncoming(bytes) }
        }
    }

    public func setLogHandler(_ handler: (@Sendable (String) -> Void)?) {
        logHandler = handler
    }

    private func nextRequestID() -> UInt16 {
        requestID = (requestID + 1) % 4096
        return requestID
    }

    /// Send a command and wait for the matching response.
    public func call(command: UInt8, payload: [UInt8] = [],
                     timeout: Duration = .seconds(20)) async throws -> TEFrame {
        let id = nextRequestID()
        let frame = TEFrame(identityCode: identityCode, requestID: id, command: command, payload: payload)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self else { return }
                await self.failPending(id: id, with: SessionError.timeout(command: command, requestID: id))
            }
            Task {
                do {
                    try await wire.send(frame.bytes)
                } catch {
                    timeoutTask.cancel()
                    self.failPending(id: id, with: error)
                }
            }
            // Store cancellation handle indirectly: failPending resumes exactly once.
            pendingTimeoutTasks[id] = timeoutTask
        }
    }

    private var pendingTimeoutTasks: [UInt16: Task<Void, Never>] = [:]

    private func failPending(id: UInt16, with error: Error) {
        if let continuation = pending.removeValue(forKey: id) {
            pendingTimeoutTasks.removeValue(forKey: id)?.cancel()
            continuation.resume(throwing: error)
        }
    }

    private func handleIncoming(_ bytes: [UInt8]) {
        guard let frame = TEFrame.parse(bytes) else { return }
        if frame.kind == .deviceLog {
            if let text = String(bytes: frame.payload, encoding: .utf8) {
                logHandler?(text)
            }
            return
        }
        if frame.hasRequestID, let continuation = pending[frame.requestID] {
            switch frame.status {
            case .ok:
                pending.removeValue(forKey: frame.requestID)
                pendingTimeoutTasks.removeValue(forKey: frame.requestID)?.cancel()
                continuation.resume(returning: frame)
            case .specificSuccess:
                // Intermediate success: the operation continues; keep waiting.
                break
            case let status:
                pending.removeValue(forKey: frame.requestID)
                pendingTimeoutTasks.removeValue(forKey: frame.requestID)?.cancel()
                let text = String(bytes: frame.payload, encoding: .utf8)
                continuation.resume(throwing: SessionError.deviceError(status ?? .error, message: text))
            }
            return
        }
        if frame.command == TECommand.file, let event = FileEvent.parse(frame.payload) {
            for continuation in eventContinuations.values {
                continuation.yield(event)
            }
        }
    }

    /// Stream of device-initiated file events (added/updated/deleted/moved/metadata).
    public func fileEvents() -> AsyncStream<FileEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id: id) }
            }
            eventContinuations[id] = continuation
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    /// GREET: fetch device metadata string.
    public func greet() async throws -> GreetMetadata {
        let frame = try await call(command: TECommand.greet)
        guard let text = String(bytes: frame.payload, encoding: .utf8) else {
            throw SessionError.notAGreetReply
        }
        return GreetMetadata.parse(text)
    }
}

/// Guards a single continuation resume across a timeout race.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

/// True when identifyDevice gave up because no TE identity reply arrived in time,
/// as on a port without a TE sampler; any other error is a real failure.
public func isNoIdentityReply(_ error: any Error) -> Bool {
    if case WireError.timeout = error { true } else { false }
}

/// Identify a TE device on a wire: send the universal identity request,
/// return the parsed reply.
public func identifyDevice(on wire: any MIDIWire, timeout: Duration = .seconds(5)) async throws -> Identity.Reply {
    try await withCheckedThrowingContinuation { continuation in
        let once = ResumeOnce()
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            if once.claim() {
                wire.setMessageHandler(nil)
                continuation.resume(throwing: WireError.timeout)
            }
        }
        wire.setMessageHandler { bytes in
            guard let reply = Identity.parseReply(bytes) else { return }
            if once.claim() {
                timeoutTask.cancel()
                continuation.resume(returning: reply)
            }
        }
        Task {
            do {
                try await wire.send(Identity.requestBytes)
            } catch {
                if once.claim() {
                    timeoutTask.cancel()
                    wire.setMessageHandler(nil)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
