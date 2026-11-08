import CryptoKit
import Foundation
import KokokoCore

public struct WaveformDescriptor: Equatable, Sendable {
    public let size: Int
    public let channels: Int
    public let sampleRate: Int

    public init?(size: Int, metadata: [String: JSONValue]) {
        guard size >= 0, size <= Int(UInt32.max),
              let channels = metadata["channels"]?.intValue, (1...2).contains(channels),
              let rate = metadata["samplerate"]?.intValue, (1...65535).contains(rate),
              size.isMultiple(of: channels * 2) else { return nil }
        self.size = size
        self.channels = channels
        sampleRate = rate
    }

    public func matches(_ record: WaveformPeakRecord) -> Bool {
        record.size == size && record.channels == channels && record.sampleRate == sampleRate && record.encoding == "s16le"
    }
}

public struct WaveformPeakRecord: Codable, Equatable, Sendable {
    public let frameCount: Int
    public let size: Int
    public let channels: Int
    public let sampleRate: Int
    public let encoding: String
    public let peaks: [Double]

    public init?(pcm: [UInt8], channels: Int, sampleRate: Int) {
        guard (1...2).contains(channels), (1...65535).contains(sampleRate),
              pcm.count <= Int(UInt32.max), pcm.count.isMultiple(of: channels * 2) else { return nil }
        size = pcm.count
        frameCount = pcm.count / (channels * 2)
        self.channels = channels
        self.sampleRate = sampleRate
        encoding = "s16le"
        peaks = Waveform(pcm: pcm, channels: channels, sampleRate: sampleRate,
                         columns: min(512, max(frameCount, 1)), loopStart: nil, loopEnd: nil).peaks
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        frameCount = try values.decode(Int.self, forKey: .frameCount)
        size = try values.decode(Int.self, forKey: .size)
        channels = try values.decode(Int.self, forKey: .channels)
        sampleRate = try values.decode(Int.self, forKey: .sampleRate)
        encoding = try values.decode(String.self, forKey: .encoding)
        peaks = try values.decode([Double].self, forKey: .peaks)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid waveform peaks"))
        }
    }

    fileprivate var isValid: Bool {
        (1...2).contains(channels) && (1...65535).contains(sampleRate) && encoding == "s16le"
            && size >= 0 && size <= Int(UInt32.max) && size.isMultiple(of: channels * 2)
            && frameCount == size / (channels * 2) && peaks.count == min(512, max(frameCount, 1))
            && peaks.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

public struct WaveformIntent: Sendable {
    public struct Request: Equatable, Sendable {
        public let slot: UInt16
        fileprivate let generation: Int
        fileprivate let epoch: UUID
        fileprivate let id: UUID
    }

    private var epoch = UUID()
    private var current: Request?

    public init() {}

    public mutating func begin(slot: UInt16, generation: Int) -> Request {
        let request = Request(slot: slot, generation: generation, epoch: epoch, id: UUID())
        current = request
        return request
    }

    public func isCurrent(_ request: Request, generation: Int) -> Bool {
        current == request && request.epoch == epoch && request.generation == generation
    }

    public mutating func invalidate() {
        epoch = UUID()
        current = nil
    }
}

public struct WaveformCache: Sendable {
    private struct Payload: Codable {
        let owner: String
        let schema: Int
        let algorithm: Int
        let namespace: String
        let slot: UInt16
        let record: WaveformPeakRecord
    }

    private struct Envelope: Codable {
        let payload: Data
        let sha256: String
    }

    private struct Entry {
        let url: URL
        let payload: Payload
        let bytes: Int
        let used: Date
    }

    private let root: URL
    private let directory: URL?
    private let namespace: String
    private let maximumBytes: Int
    private var memory: [UInt16: WaveformPeakRecord] = [:]
    private var recency: [UInt16] = []
    private let fileLimit = 32768

    public init(root: URL, model: String, serial: String, maximumBytes: Int = 64 * 1024 * 1024) {
        self.root = root.standardizedFileURL
        self.maximumBytes = max(0, min(maximumBytes, 64 * 1024 * 1024))
        namespace = Self.digest(Data(("\(model.utf8.count):\(model)\(serial.utf8.count):\(serial)").utf8))
        directory = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : root.standardizedFileURL.appendingPathComponent(namespace, isDirectory: true)
    }

    public mutating func load(slot: UInt16, size: Int, channels: Int? = nil, sampleRate: Int? = nil) -> WaveformPeakRecord? {
        let record = memory[slot] ?? file(slot: slot).flatMap { read($0)?.payload.record }
        guard let record else { return nil }
        guard record.size == size, channels == nil || record.channels == channels,
              sampleRate == nil || record.sampleRate == sampleRate else {
            invalidate(slots: [slot])
            return nil
        }
        remember(record, slot: slot)
        if let url = file(slot: slot), read(url) != nil {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        return record
    }

    public mutating func store(_ record: WaveformPeakRecord, slot: UInt16) {
        guard record.isValid else { return }
        remember(record, slot: slot)
        guard let directory, safeDirectory(directory), let url = file(slot: slot) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard safeDirectory(directory) else { return }
            if FileManager.default.fileExists(atPath: url.path) || isSymlink(url) {
                guard read(url) != nil else { return }
            }
            let payload = Payload(owner: "kokoko-waveform-peaks", schema: 1, algorithm: 1,
                                  namespace: namespace, slot: slot, record: record)
            let data = try JSONEncoder().encode(payload)
            let encoded = try JSONEncoder().encode(Envelope(payload: data, sha256: Self.digest(data)))
            guard encoded.count <= fileLimit, encoded.count <= maximumBytes else { return }
            let entries = ownedEntries(allNamespaces: true).filter { $0.url != url }.sorted { $0.used < $1.used }
            var bytes = entries.reduce(0) { $0 + $1.bytes } + encoded.count
            for entry in entries where bytes > maximumBytes {
                guard read(entry.url) != nil else { return }
                try FileManager.default.removeItem(at: entry.url)
                bytes -= entry.bytes
            }
            guard bytes <= maximumBytes, safeDirectory(directory) else { return }
            try encoded.write(to: url, options: .atomic)
        } catch {}
    }

    public mutating func invalidate(slots: Set<UInt16>?) {
        for slot in Array(memory.keys) where slots == nil || slots!.contains(slot) {
            memory[slot] = nil
            recency.removeAll { $0 == slot }
        }
        for entry in ownedEntries() where slots == nil || slots!.contains(entry.payload.slot) {
            if read(entry.url) != nil { try? FileManager.default.removeItem(at: entry.url) }
        }
    }

    private mutating func remember(_ record: WaveformPeakRecord, slot: UInt16) {
        memory[slot] = record
        recency.removeAll { $0 == slot }
        recency.append(slot)
        while memory.count * fileLimit > maximumBytes, let oldest = recency.first {
            memory[oldest] = nil
            recency.removeFirst()
        }
    }

    private func file(slot: UInt16) -> URL? {
        directory?.appendingPathComponent(Self.digest(Data(String(slot).utf8)) + ".wfp")
    }

    private func ownedEntries(allNamespaces: Bool = false) -> [Entry] {
        guard let directory, safeDirectory(root) else { return [] }
        let directories: [URL]
        if allNamespaces {
            directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        } else {
            directories = [directory]
        }
        return directories.filter { Self.isDigest($0.lastPathComponent) && safeDirectory($0) }.flatMap {
            ((try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []).compactMap(read)
        }
    }

    private func read(_ url: URL) -> Entry? {
        let directory = url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().path == root.path, Self.isDigest(directory.lastPathComponent),
              safeDirectory(directory),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= fileLimit,
              let data = try? Data(contentsOf: url), data.count == size,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.sha256 == Self.digest(envelope.payload),
              let payload = try? JSONDecoder().decode(Payload.self, from: envelope.payload),
              payload.owner == "kokoko-waveform-peaks", payload.schema == 1, payload.algorithm == 1,
              payload.namespace == directory.lastPathComponent, payload.record.isValid,
              url.lastPathComponent == Self.digest(Data(String(payload.slot).utf8)) + ".wfp"
        else { return nil }
        return Entry(url: url, payload: payload, bytes: size,
                     used: attributes[.modificationDate] as? Date ?? .distantPast)
    }

    private func safeDirectory(_ url: URL) -> Bool {
        var path = url
        while path.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
               attributes[.type] as? FileAttributeType != .typeDirectory { return false }
            path.deleteLastPathComponent()
        }
        return true
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
