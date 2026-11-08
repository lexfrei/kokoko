import Foundation
import KokokoCore

public enum MetadataDraftSaveResult: Equatable, Sendable {
    case saved(MetadataEditForm)
    case failed(form: MetadataEditForm, message: String, needsReadback: Bool)
    case stale, invalid
}

public enum MetadataEditorPhase: Sendable {
    case loading, ready, loadFailed, saving
}

public enum MetadataEditSubmission: Equatable, Sendable {
    case invalid, waiting, unchanged
    case write(request: UUID, form: MetadataEditForm, refreshBeforeWrite: Bool)
}

public struct InlineMetadataEdit: Sendable {
    public let session = UUID()
    public let id: UInt16
    public let name: String
    public let generation: Int
    public private(set) var request: UUID? = UUID()
    public private(set) var phase: MetadataEditorPhase = .loading
    public var form: MetadataEditForm?
    public private(set) var note: String?
    public private(set) var needsReadback = false

    public init(id: UInt16, name: String, generation: Int) {
        self.id = id
        self.name = name
        self.generation = generation
    }

    public var canCancel: Bool { phase != .saving }
    public var canSubmit: Bool { phase == .ready && form?.changes != nil }
    public var blocksFilterChange: Bool {
        phase == .loading || phase == .saving || needsReadback
            || (form != nil && form?.changes?.isEmpty != true)
    }

    public func isCurrent(selection: Set<UInt16>, visible: Set<UInt16>, tab: HeaderTab, generation: Int) -> Bool {
        self.generation == generation && tab == .sounds && selection == [id] && visible.contains(id)
    }

    public mutating func beginLoad() -> UUID? {
        guard phase == .loadFailed else { return nil }
        let request = UUID()
        self.request = request
        phase = .loading
        return request
    }

    public mutating func loaded(request: UUID, metadata: [String: JSONValue]?, error: String?) -> Bool {
        guard phase == .loading, self.request == request else { return false }
        self.request = nil
        form = metadata.map(MetadataEditForm.init)
        note = error ?? (metadata == nil ? "metadata could not be read" : nil)
        phase = metadata == nil ? .loadFailed : .ready
        return true
    }

    public mutating func prepareSave() -> MetadataEditSubmission {
        guard phase != .loading, phase != .saving else { return .waiting }
        guard let form, let changes = form.changes else { return .invalid }
        guard !changes.isEmpty || needsReadback else { return .unchanged }
        let request = UUID()
        self.request = request
        phase = .saving
        return .write(request: request, form: form, refreshBeforeWrite: needsReadback)
    }

    public mutating func finished(request: UUID, result: MetadataDraftSaveResult) -> Bool {
        guard phase == .saving, self.request == request else { return false }
        self.request = nil
        phase = .ready
        switch result {
        case .saved(let form):
            self.form = form
            note = nil
            needsReadback = false
        case .failed(let form, let message, let needsReadback):
            self.form = form
            note = message
            self.needsReadback = needsReadback
        case .stale:
            note = "editing context changed; refresh metadata before saving"
            needsReadback = true
        case .invalid:
            note = "correct the invalid metadata fields"
        }
        return true
    }
}
