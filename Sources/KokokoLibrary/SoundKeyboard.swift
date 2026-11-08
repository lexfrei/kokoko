import Foundation

public enum SoundFocus: Hashable, Sendable {
    case soundList, filter, bulkMove, allRanges, rangeJump(Int)
    case slotNumber(UInt16), slot(UUID), slotRefresh(UUID), rename(UInt16), rowAction(UInt16, RowAction), rowMenu(UInt16)
    case metadataField(UUID, String), metadataSave(UUID), metadataCancel(UUID), metadataRetry(UUID)
    case waveformPlay(UInt16), waveformRefresh(UInt16), waveformClose(UInt16)
}

public enum SoundKeyPhase: Sendable { case down, repeating, up }

public struct SoundKeyboard: Sendable {
    public var focus: SoundFocus?
    public var tab: HeaderTab = .sounds
    public var connected = false
    public var busy = false
    public var blocked = false
    public var selection: Set<UInt16> = []
    public var visible: Set<UInt16> = []

    public init() {}

    public func target(phase: SoundKeyPhase, modified: Bool) -> UInt16? {
        guard phase == .down, !modified, focus == .soundList, !blocked,
              AppCommand.auditionSelected.isEnabled(tab: tab, connected: connected, busy: busy,
                                                   selection: selection.count, modalOpen: false),
              let id = selection.first, visible.contains(id) else { return nil }
        return id
    }
}

public enum RenameSubmission: Equatable, Sendable {
    case invalid, unchanged, waiting, write(String)
}

public struct InlineRename: Equatable, Sendable {
    public let session = UUID()
    public let id: UInt16
    public let generation: Int
    public let original: String
    public var draft: String
    public private(set) var submitting = false
    public private(set) var error: String?

    public init(id: UInt16, generation: Int, name: String) {
        self.id = id
        self.generation = generation
        self.original = name
        self.draft = name
    }

    public func isCurrent(selection: Set<UInt16>, visible: Set<UInt16>, tab: HeaderTab, generation: Int) -> Bool {
        self.generation == generation && tab == .sounds && selection == [id] && visible.contains(id)
    }

    public var canCancel: Bool { !submitting }
    public var blocksFilterChange: Bool { submitting || hasChanges }

    private var hasChanges: Bool {
        draft != original && draft.trimmingCharacters(in: .whitespacesAndNewlines) != original
    }

    public mutating func prepare() -> RenameSubmission {
        guard !submitting else { return .waiting }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            error = "name must not be empty"
            return .invalid
        }
        error = nil
        guard hasChanges else { return .unchanged }
        submitting = true
        return .write(name)
    }

    public mutating func finish(error: String?) -> Bool {
        guard submitting else { return false }
        submitting = false
        self.error = error
        return error == nil
    }
}
