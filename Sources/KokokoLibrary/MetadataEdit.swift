import Foundation
import KokokoCore
import KokokoMIDI

/// Text fields with the constraints documented in docs/protocol.md.
/// Edited fields and unresolved writes are sent; untouched fields are not.
public struct MetadataEditForm: Equatable, Sendable {
    private enum Rule {
        case range(ClosedRange<Int>)
        case atLeast(Int)
        case text
    }

    private static let rules: [(key: String, rule: Rule)] = [
        ("sound.rootnote", .range(1...127)),
        ("sound.bpm", .range(60...180)),
        ("sound.pitch", .range(-12...12)),
        ("sound.pan", .range(-16...16)),
        ("sound.amplitude", .range(0...200)),
        ("envelope.attack", .range(0...255)),
        ("envelope.release", .range(0...255)),
        ("sound.loopstart", .atLeast(0)),
        ("sound.loopend", .atLeast(0)),
        ("sound.playmode", .text),
        ("time.mode", .text),
    ]

    public static let keys = rules.map(\.key)

    public var text: [String: String]
    private var initial: [String: String]
    private var baseline: [String: JSONValue]
    private var unconfirmed = Set<String>()

    public init(metadata: [String: JSONValue]) {
        var text: [String: String] = [:]
        for key in Self.keys {
            text[key] = switch metadata[key] {
            case .int(let value)?: String(value)
            case .double(let value)?: String(value)
            case .string(let value)?: value
            case .bool(let value)?: String(value)
            case nil, .null?: ""
            case let other?: "\(other)"
            }
        }
        self.text = text
        initial = text
        baseline = metadata
    }

    public mutating func rebase(on metadata: [String: JSONValue]) {
        var refreshed = MetadataEditForm(metadata: metadata)
        for key in Self.keys {
            let raw = text[key] ?? ""
            if text[key] == initial[key], !unconfirmed.contains(key) {
                if metadata[key]?.normalizedNumbers == baseline[key]?.normalizedNumbers {
                    refreshed.text[key] = raw
                    refreshed.initial[key] = raw
                }
                continue
            }
            refreshed.text[key] = raw
            switch value(for: key) {
            case .success(let desired?):
                if metadata[key]?.normalizedNumbers == desired.normalizedNumbers {
                    refreshed.initial[key] = raw
                } else if raw == refreshed.initial[key] {
                    refreshed.unconfirmed.insert(key)
                }
            case .success(nil):
                if refreshed.initial[key] == "" { refreshed.initial[key] = raw }
            case .failure:
                break
            }
        }
        self = refreshed
    }

    mutating func markUnconfirmed(_ keys: Set<String>) {
        unconfirmed.formUnion(keys)
    }

    /// Why the field's text cannot be saved, or nil if it can.
    public func error(for key: String) -> String? {
        guard case .failure(let reason) = value(for: key) else { return nil }
        return reason.text
    }

    /// The keys to send, or nil while any field has an error.
    public var changes: [String: JSONValue]? {
        var result: [String: JSONValue] = [:]
        for key in Self.keys {
            switch value(for: key) {
            case .success(let value?): result[key] = value
            case .success(nil): continue
            case .failure: return nil
            }
        }
        return result
    }

    private struct Reason: Error {
        let text: String
    }

    private func value(for key: String) -> Result<JSONValue?, Reason> {
        guard let rule = Self.rules.first(where: { $0.key == key })?.rule else { return .success(nil) }
        let raw = text[key] ?? ""
        let before = initial[key] ?? ""
        guard raw != before || unconfirmed.contains(key) else { return .success(nil) }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return before.isEmpty ? .success(nil) : .failure(Reason(text: "a value is required"))
        }
        switch rule {
        case .text:
            return .success(.string(trimmed))
        case .range(let range):
            guard let number = Int(trimmed) else { return .failure(Reason(text: "a whole number")) }
            guard range.contains(number) else {
                return .failure(Reason(text: "\(range.lowerBound)...\(range.upperBound)"))
            }
            return .success(.int(number))
        case .atLeast(let low):
            guard let number = Int(trimmed) else { return .failure(Reason(text: "a whole number")) }
            guard number >= low else { return .failure(Reason(text: "\(low) or more")) }
            return .success(.int(number))
        }
    }
}

public struct MetadataSaveResult: Sendable {
    /// What went wrong, or nil when the write was confirmed and read back.
    public let message: String?
    /// The metadata read back from the device, or nil if that read failed.
    public let current: [String: JSONValue]?
}

public func saveMetadata(files: DeviceFileService, fileID: UInt16,
                         changes: [String: JSONValue]) async -> MetadataSaveResult {
    await saveMetadataSteps(changes,
                            set: { try await files.setMetadata(fileID: fileID, $0) },
                            get: { try await files.getMetadata(fileID: fileID) })
}

/// Writes `changes` and reads the metadata back whatever the write's
/// outcome, so the editor shows what the device holds instead of a guess.
package func saveMetadataSteps(_ changes: [String: JSONValue],
                               set: @Sendable ([String: JSONValue]) async throws -> Void,
                               get: @Sendable () async throws -> [String: JSONValue]) async -> MetadataSaveResult {
    var problems: [String] = []
    do {
        try await set(changes)
    } catch {
        let verb = if case SessionError.deviceError = error { "refused" } else { "did not confirm" }
        problems.append("the device \(verb) the metadata write (\(error.localizedDescription))")
    }
    var current: [String: JSONValue]?
    do {
        current = try await get()
    } catch {
        problems.append("reading it back failed (\(error.localizedDescription))")
    }
    if problems.isEmpty, let current {
        let missing = changes.keys.filter {
            current[$0]?.normalizedNumbers != changes[$0]?.normalizedNumbers
        }.sorted()
        if !missing.isEmpty { problems.append("reading it back did not confirm: \(missing.joined(separator: ", "))") }
    }
    return MetadataSaveResult(message: problems.isEmpty ? nil : problems.joined(separator: "; "),
                              current: current)
}

public func saveMetadataDraft(files: DeviceFileService, fileID: UInt16, form: MetadataEditForm,
                              refreshBeforeWrite: Bool,
                              isCurrent: @escaping @Sendable () async -> Bool) async -> MetadataDraftSaveResult {
    await saveMetadataDraftSteps(form: form, refreshBeforeWrite: refreshBeforeWrite,
                                 set: { try await files.setMetadata(fileID: fileID, $0) },
                                 get: { try await files.getMetadata(fileID: fileID) },
                                 isCurrent: isCurrent)
}

package func saveMetadataDraftSteps(form: MetadataEditForm, refreshBeforeWrite: Bool,
                                   set: @Sendable ([String: JSONValue]) async throws -> Void,
                                   get: @Sendable () async throws -> [String: JSONValue],
                                   isCurrent: @Sendable () async -> Bool) async -> MetadataDraftSaveResult {
    guard await isCurrent() else { return .stale }
    guard form.changes != nil else { return .invalid }
    var form = form
    if refreshBeforeWrite {
        let current: [String: JSONValue]
        do {
            current = try await get()
        } catch {
            guard await isCurrent() else { return .stale }
            return .failed(form: form, message: "reading metadata before retry failed (\(error.localizedDescription))",
                           needsReadback: true)
        }
        guard await isCurrent() else { return .stale }
        form.rebase(on: current)
    }
    guard await isCurrent() else { return .stale }
    guard let changes = form.changes else {
        return .failed(form: form, message: "correct the invalid metadata fields", needsReadback: false)
    }
    guard !changes.isEmpty else { return .saved(form) }
    // An issued SET is not cancelled by closing its editor during readback.
    let result = await saveMetadataSteps(changes, set: set, get: get)
    if let current = result.current {
        form.rebase(on: current)
    } else {
        form.markUnconfirmed(Set(changes.keys))
    }
    if let message = result.message {
        return .failed(form: form, message: message, needsReadback: result.current == nil)
    }
    return .saved(form)
}
