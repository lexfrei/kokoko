import Foundation

public enum WaveformMiniature {
    public static let columns = 24
    public static let placeholder = "[~]"
    public static func width(compact: Bool) -> Int { compact ? 32 : 96 }
}

public struct WaveformRowSnapshot: Equatable, Sendable {
    public let record: WaveformPeakRecord
    public let cached: Bool
    public var description: String { cached ? "cached audio, unverified" : "audio read from device" }
}

public struct WaveformRows: Sendable {
    public struct Request: Equatable, Sendable {
        public let slot: UInt16
        public let size: Int
        fileprivate let epoch: UUID
        fileprivate let id: UUID
    }

    private struct Entry: Sendable {
        let size: Int
        let snapshot: WaveformRowSnapshot?
        var request: Request?
    }

    public private(set) var epoch = UUID()
    private var entries: [UInt16: Entry] = [:]
    private var order: [UInt16] = []

    public init() {}

    public func needsLookup(slot: UInt16, size: Int) -> Bool {
        entries[slot]?.size != size
    }

    public func snapshot(slot: UInt16, size: Int) -> WaveformRowSnapshot? {
        guard entries[slot]?.size == size else { return nil }
        return entries[slot]?.snapshot
    }

    public mutating func beginLookup(slot: UInt16, size: Int) -> Request? {
        guard needsLookup(slot: slot, size: size) else { return nil }
        let request = Request(slot: slot, size: size, epoch: epoch, id: UUID())
        remember(slot: slot, size: size, record: nil)
        entries[slot]?.request = request
        return request
    }

    public func isCurrent(_ request: Request) -> Bool {
        request.epoch == epoch && entries[request.slot]?.request == request
    }

    @discardableResult
    public mutating func finishLookup(_ request: Request, record: WaveformPeakRecord?) -> Bool {
        guard isCurrent(request) else { return false }
        remember(slot: request.slot, size: request.size, record: record)
        return true
    }

    public mutating func reconcileCache(slot: UInt16, size: Int, record: WaveformPeakRecord?) {
        guard let record else {
            invalidate(slots: [slot])
            return
        }
        if snapshot(slot: slot, size: size)?.record != record { remember(slot: slot, size: size, record: record) }
    }

    public mutating func remember(slot: UInt16, size: Int, record: WaveformPeakRecord?, cached: Bool = true) {
        let snapshot = record.flatMap { $0.size == size ? WaveformRowSnapshot(record: $0, cached: cached) : nil }
        entries[slot] = Entry(size: size, snapshot: snapshot)
        order.removeAll { $0 == slot }
        order.append(slot)
        while order.count > 64 { entries[order.removeFirst()] = nil }
    }

    public mutating func cancelLookup(_ request: Request) {
        guard isCurrent(request) else { return }
        forget(slot: request.slot, size: request.size, epoch: request.epoch)
    }

    public mutating func forget(slot: UInt16, size: Int, epoch: UUID) {
        guard epoch == self.epoch, entries[slot]?.size == size else { return }
        entries[slot] = nil
        order.removeAll { $0 == slot }
    }

    public mutating func invalidate(slots: Set<UInt16>?) {
        let removed = order.filter { slots == nil || slots!.contains($0) || entries[$0]?.request != nil }
        for slot in removed { entries[slot] = nil }
        order.removeAll { removed.contains($0) }
        epoch = UUID()
    }
}
