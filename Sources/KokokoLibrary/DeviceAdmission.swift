import Foundation

public struct DeviceAdmission: Sendable {
    public private(set) var operation = false
    private var preview: UUID?

    public init() {}

    public var occupied: Bool { operation || preview != nil }

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
}
