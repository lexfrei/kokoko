import Foundation

public final class WaveformCacheLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    public init() {}

    public var isCurrent: Bool { lock.withLock { active } }
    public func cancel() { lock.withLock { active = false } }
}

public actor WaveformCacheStore {
    public struct Token: Equatable, Sendable {
        fileprivate let session: UUID
        fileprivate let content: UUID
    }

    private let root: URL
    private var cache: WaveformCache
    private var session = UUID()
    private var content = UUID()

    public init(root: URL) {
        self.root = root
        cache = WaveformCache(root: root, model: "", serial: "")
    }

    public func configure(model: String, serial: String) -> UUID {
        session = UUID()
        content = UUID()
        cache = WaveformCache(root: root, model: model, serial: serial)
        return session
    }

    public func token(session: UUID) -> Token? {
        guard session == self.session else { return nil }
        return Token(session: session, content: content)
    }

    public func load(session: UUID, slot: UInt16, size: Int,
                     channels: Int? = nil, sampleRate: Int? = nil) -> WaveformPeakRecord? {
        guard session == self.session else { return nil }
        return cache.load(slot: slot, size: size, channels: channels, sampleRate: sampleRate)
    }

    @discardableResult
    public func store(_ record: WaveformPeakRecord, slot: UInt16, token: Token, lease: WaveformCacheLease) -> Bool {
        guard token.session == session, token.content == content, lease.isCurrent else { return false }
        cache.store(record, slot: slot)
        return true
    }

    public func invalidate(slots: Set<UInt16>?, session: UUID) {
        guard session == self.session else { return }
        content = UUID()
        cache.invalidate(slots: slots)
    }
}
