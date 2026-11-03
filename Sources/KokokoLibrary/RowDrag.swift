import Foundation

public struct RowDragToken: Equatable, Sendable {
    public let id: UInt16
    public let nonce: UUID

    public init(id: UInt16, nonce: UUID = UUID()) {
        self.id = id
        self.nonce = nonce
    }

    public var payload: String { "kokoko-row:1:\(nonce.uuidString):\(id)" }

    public func matches(_ text: String) -> Bool { text == payload }
}

public struct RowDragContext: Sendable {
    public private(set) var active: RowDragToken?

    public init() {}

    public mutating func begin(_ token: RowDragToken) { active = token }

    public mutating func end(_ token: RowDragToken) {
        if active == token { active = nil }
    }

    /// Claims once before loading the payload: the native session can end
    /// before an asynchronous provider callback arrives.
    public mutating func claim(target: UInt16, busy: Bool) -> RowDragToken? {
        let token = active
        active = nil
        guard let token, token.id != target, !busy else { return nil }
        return token
    }
}
