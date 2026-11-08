import Foundation

public struct DeviceAdmission: Sendable {
    public enum ForegroundRequest: Equatable, Sendable {
        case started, waiting(UUID), refused
    }

    public enum BackgroundRelease: Equatable, Sendable {
        case stale, idle, foreground(UUID)
    }

    public private(set) var operation = false
    private var preview: UUID?
    private var background: UUID?
    private var foreground: UUID?

    public init() {}

    public var foregroundWaiting: Bool { foreground != nil }
    public var userOccupied: Bool { operation || preview != nil || foregroundWaiting }
    public var occupied: Bool { userOccupied || background != nil }

    public mutating func beginOperation() -> Bool {
        guard !occupied else { return false }
        operation = true
        return true
    }

    public mutating func endOperation() -> Bool {
        guard operation else { return false }
        operation = false
        return true
    }

    public mutating func beginPreview() -> UUID? {
        guard !occupied else { return nil }
        let token = UUID()
        preview = token
        return token
    }

    public mutating func endPreview(_ token: UUID) -> Bool {
        guard preview == token else { return false }
        preview = nil
        return true
    }

    public mutating func beginBackground() -> UUID? {
        guard !occupied else { return nil }
        let token = UUID()
        background = token
        return token
    }

    public mutating func requestForeground() -> ForegroundRequest {
        guard !userOccupied else { return .refused }
        guard background != nil else {
            operation = true
            return .started
        }
        let token = UUID()
        foreground = token
        return .waiting(token)
    }

    public mutating func cancelForeground(_ token: UUID) -> Bool {
        guard foreground == token else { return false }
        foreground = nil
        return true
    }

    public mutating func endBackground(_ token: UUID) -> BackgroundRelease {
        guard background == token else { return .stale }
        background = nil
        guard let owner = foreground else { return .idle }
        foreground = nil
        operation = true
        return .foreground(owner)
    }
}
