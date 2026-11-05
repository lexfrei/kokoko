import Foundation
import KokokoCore
import KokokoMIDI

public struct SoundRange: Identifiable, Hashable, Sendable {
    public let id: Int
    public let lower: UInt16
    public let upper: UInt16

    /// Navigation marks, not a device-advertised slot limit.
    public static let all = (0..<10).map { SoundRange(index: $0) }

    private init(index: Int) {
        id = index
        lower = UInt16(index == 0 ? 1 : index * 100)
        upper = UInt16(index * 100 + 99)
    }

    public var label: String { String(format: "%03d-%03d", lower, upper) }
    public func contains(_ slot: UInt16) -> Bool { (lower...upper).contains(slot) }
}

public enum SoundSectionID: Hashable, Sendable {
    case range(Int)
    case other
}

public struct SoundSection: Identifiable, Equatable, Sendable {
    public let id: SoundSectionID
    public let title: String
    public let total: Int
    public let slots: [UInt16]

    public func emptyText(hasSnapshot: Bool, fresh: Bool) -> String {
        guard hasSnapshot else { return "not loaded" }
        guard fresh else { return "not refreshed" }
        return total == 0 ? "empty" : "no matches"
    }
}

public func soundSections(all: [UInt16], visible: Set<UInt16>) -> [SoundSection] {
    let ordered = all.sorted()
    var sections = SoundRange.all.map { range in
        let slots = ordered.filter(range.contains)
        return SoundSection(
            id: .range(range.id), title: range.label, total: slots.count,
            slots: slots.filter(visible.contains))
    }
    let other = ordered.filter { slot in !SoundRange.all.contains(where: { $0.contains(slot) }) }
    if !other.isEmpty {
        sections.append(
            SoundSection(
                id: .other, title: "other slots", total: other.count,
                slots: other.filter(visible.contains)))
    }
    return sections
}

public func soundCountsText(total: Int?, shown: Int, fresh: Bool) -> String {
    guard let total else { return "sounds ? / shown ?" }
    return "sounds \(total) / shown \(shown)" + (fresh ? "" : " (stale)")
}

public struct SoundStorage: Equatable, Sendable {
    public let totalBytes: Int64?
    public let freeBytes: Int64?
    public let usedBytes: Int64?
    public let invalid: Bool

    public init(metadata: [String: JSONValue]) {
        func bytes(_ key: String) -> Int64? {
            guard let value = metadata[key]?.intValue, value >= 0 else { return nil }
            return Int64(exactly: value)
        }
        let total = bytes("max_capacity")
        let free = bytes("free_space_in_bytes")
        if let total, let free, free > total {
            totalBytes = nil
            freeBytes = nil
            usedBytes = nil
            invalid = true
            return
        }
        totalBytes = total
        freeBytes = free
        usedBytes = if let total, let free { total - free } else { nil }
        invalid = ["max_capacity", "free_space_in_bytes"].contains { metadata[$0] != nil && bytes($0) == nil }
    }

    public var text: String {
        "used \(storageByteText(usedBytes)) / free \(storageByteText(freeBytes)) / total \(storageByteText(totalBytes))"
    }
}

public func storageByteText(_ bytes: Int64?) -> String {
    guard let bytes, bytes >= 0 else { return "?" }
    if bytes >= 1_048_576 { return String(format: "%.1f MiB", Double(bytes) / 1_048_576) }
    if bytes >= 1024 { return String(format: "%.1f KiB", Double(bytes) / 1024) }
    return "\(bytes) B"
}

public struct SoundStorageState: Sendable {
    public private(set) var value: SoundStorage?
    public private(set) var stale = false
    public private(set) var message: String?
    private var generation: Int?
    private var request: UUID?

    public init() {}

    public var text: String {
        (value?.text ?? "used ? / free ? / total ?") + (stale ? " (stale)" : "")
    }

    public mutating func begin(generation: Int) -> UUID {
        if self.generation != generation {
            self = SoundStorageState()
            self.generation = generation
        }
        let request = UUID()
        self.request = request
        stale = value != nil
        message = nil
        return request
    }

    public mutating func invalidate() {
        request = nil
        stale = value != nil
        message = value == nil ? "storage needs refresh" : nil
    }

    public mutating func finish(request: UUID, generation: Int, result: Result<SoundStorage, any Error>) -> Bool {
        guard self.request == request, self.generation == generation else { return false }
        self.request = nil
        stale = false
        switch result {
        case .success(let value):
            self.value = value
            if value.invalid {
                message = "storage metadata is invalid"
            } else if value.totalBytes == nil && value.freeBytes == nil {
                message = "storage metadata is unavailable"
            } else {
                message = nil
            }
        case .failure(let error):
            value = nil
            message = error.localizedDescription
        }
        return true
    }
}

public struct SoundDirectoryRead: Sendable {
    public let nodes: Result<[FSNode], any Error>
    public let storage: Result<SoundStorage, any Error>
}

public func readSoundStorage(files: DeviceFileService, root: UInt16) async -> Result<SoundStorage, any Error> {
    await readSoundStorageSteps(get: { try await files.getMetadata(fileID: root) })
}

package func readSoundStorageSteps(get: @Sendable () async throws -> [String: JSONValue]) async -> Result<SoundStorage, any Error> {
    do { return .success(SoundStorage(metadata: try await get())) } catch { return .failure(error) }
}

public func readSoundDirectory(files: DeviceFileService, root: UInt16) async -> SoundDirectoryRead {
    await readSoundDirectorySteps(
        list: { try await files.list(nodeID: root) },
        storage: { await readSoundStorage(files: files, root: root) })
}

package func readSoundDirectorySteps(
    list: @Sendable () async throws -> [FSNode],
    storage: @Sendable () async -> Result<SoundStorage, any Error>
) async -> SoundDirectoryRead {
    let nodes: Result<[FSNode], any Error>
    do { nodes = .success(try await list()) } catch { nodes = .failure(error) }
    return SoundDirectoryRead(nodes: nodes, storage: await storage())
}
