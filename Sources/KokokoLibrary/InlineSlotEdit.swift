import Foundation

public enum SlotEditSubmission: Equatable, Sendable {
    case invalid, unchanged, waiting
    case write(from: UInt16, to: UInt16)
}

public struct InlineSlotEdit: Sendable {
    public let session = UUID()
    public let generation: Int
    public private(set) var rowID: UInt16
    public private(set) var slot: UInt16?
    public var draft: String
    public private(set) var submitting = false
    public private(set) var error: String?
    private var attempted: (from: UInt16, to: UInt16)?

    public init(id: UInt16, generation: Int) {
        rowID = id
        slot = id
        self.generation = generation
        draft = String(id)
    }

    public var canCancel: Bool { !submitting }
    public var needsRefresh: Bool { slot == nil || slot != rowID }
    public var blocksFilterChange: Bool { submitting || needsRefresh || destination != slot }

    private var destination: UInt16? {
        guard !draft.isEmpty, draft.utf8.allSatisfy({ (48...57).contains($0) }),
              let target = UInt16(draft), target != 0 else { return nil }
        return target
    }

    public func isCurrent(selection: Set<UInt16>, visible: Set<UInt16>, tab: HeaderTab, generation: Int) -> Bool {
        guard self.generation == generation, tab == .sounds else { return false }
        if submitting { return true }
        return visible.contains(rowID) && selection == [slot ?? rowID]
    }

    public mutating func prepare() -> SlotEditSubmission {
        guard !submitting else { return .waiting }
        guard let slot else { return .invalid }
        guard let target = destination else {
            error = "enter a slot from 1 to 65535 using digits only"
            return .invalid
        }
        error = nil
        guard target != slot else { return .unchanged }
        attempted = (slot, target)
        submitting = true
        return .write(from: slot, to: target)
    }

    public mutating func recordLocation(at slot: UInt16?) {
        guard submitting else { return }
        self.slot = slot
    }

    public mutating func beginRefresh() -> Bool {
        guard !submitting, needsRefresh else { return false }
        submitting = true
        return true
    }

    public mutating func finish(at slot: UInt16?, error: String?, listed: Set<UInt16>?) -> Bool {
        guard submitting else { return false }
        submitting = false
        self.slot = slot
        self.error = error
        guard let slot else { return false }
        if listed?.contains(slot) == true { rowID = slot }
        return error == nil && listed?.contains(slot) == true
    }

    public mutating func reconcile(occupied: Set<UInt16>) -> [(from: UInt16, to: UInt16)] {
        var carried: [(from: UInt16, to: UInt16)] = []
        if slot == nil, let attempted {
            if stepLanded(attempted, occupied: occupied) {
                slot = attempted.to
                carried = [attempted]
            } else if occupied.contains(attempted.from), !occupied.contains(attempted.to) {
                slot = attempted.from
            }
        }
        if let slot, occupied.contains(slot) { rowID = slot }
        return carried
    }
}
