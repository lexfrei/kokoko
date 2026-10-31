import Foundation
import KokokoAudio
import KokokoCore
import KokokoMIDI
import KokokoLibrary
import VirtualEP

// End-to-end check: a virtual EP device and the client stack in one process,
// bytes crossing the real CoreMIDI transport both ways.

@MainActor
@main
struct E2E {
    static var failures = 0

    static func check(_ cond: Bool, _ name: String) {
        let line = cond ? "ok   \(name)" : "FAIL \(name)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        if !cond { failures += 1 }
    }

    static func main() async throws {
        let vep = VirtualEPDevice()
        try vep.start()

        // Give CoreMIDI a beat to publish the endpoints.
        try await Task.sleep(for: .milliseconds(300))

        let pairs = enumerateMIDIPairs()
        guard let pair = pairs.first(where: { $0.name == vep.name }) else {
            FileHandle.standardError.write(Data("FAIL virtual device not found among \(pairs.map(\.name))\n".utf8))
            exit(1)
        }
        check(true, "virtual device enumerated")

        let wire = try CoreMIDIWire(pair: pair)
        let identity = try await identifyDevice(on: wire)
        check(identity.sku == "TE032AS001", "identify sku — got \(identity.sku)")

        let session = SysExSession(wire: wire, identityCode: identity.deviceID)
        let meta = try await session.greet()
        check(meta.osVersion == "2.1.0", "greet os — got \(meta.osVersion)")
        check(meta.serial == "VEP0001", "greet serial — got \(meta.serial)")

        let files = DeviceFileService(session: session)
        try await files.initialize()
        check(true, "file service initialized")

        // Watch for events in the background.
        let eventsTask = Task { () -> [FileEvent] in
            var seen: [FileEvent] = []
            for await event in await session.fileEvents() {
                seen.append(event)
            }
            return seen
        }

        func resolve(_ path: String) async throws -> UInt16 {
            var current: UInt16 = 0
            for part in path.split(separator: "/") {
                let children = try await files.list(nodeID: current)
                guard let next = children.first(where: { $0.name == String(part) }) else {
                    throw WireError.noDevice
                }
                current = next.id
            }
            return current
        }

        let soundsID = try await resolve("/sounds")
        let initialList = try await files.list(nodeID: soundsID)
        check(initialList.map(\.name).sorted() == ["kick", "snare"],
              "seeded sounds — got \(initialList.map(\.name).sorted())")

        // Upload a synthesized device-format WAV.
        var pcm: [UInt8] = []
        for i in 0..<5000 {
            let v = Int16(sin(Double(i) / 5.0) * 12000)
            pcm.append(UInt8(UInt16(bitPattern: v) & 0xFF))
            pcm.append(UInt8(UInt16(bitPattern: v) >> 8))
        }
        let wav = makeWAV(pcm: pcm, channels: 1, sampleRate: 46875)
        let prepared = try prepareForUpload(fileData: Data(wav), fileName: "hat.wav")
        let newID = try await files.put(parentID: soundsID, name: "hihat", data: prepared.pcm)
        check(newID != 0, "put returned id \(newID)")

        var uploadMeta = prepared.metadata
        uploadMeta["name"] = .string("hihat")
        try await files.setMetadata(fileID: newID, uploadMeta)

        let afterUpload = try await files.list(nodeID: soundsID)
        check(afterUpload.contains(where: { $0.name == "hihat" && $0.id == newID }),
              "uploaded node listed")

        let readBack = try await files.get(fileID: newID)
        check(readBack.data == prepared.pcm,
              "round trip bytes — \(readBack.data.count) vs \(prepared.pcm.count)")

        let readMeta = try await files.getMetadata(fileID: newID)
        check(readMeta["channels"]?.intValue == 1,
              "metadata channels — got \(String(describing: readMeta["channels"]))")
        check(readMeta["samplerate"]?.intValue == 46875, "metadata samplerate")
        check(readMeta["name"]?.stringValue == "hihat", "metadata name")

        try await files.delete(fileID: newID)
        let afterDelete = try await files.list(nodeID: soundsID)
        check(!afterDelete.contains(where: { $0.id == newID }), "deleted node gone")

        // --- DeviceLibrary: backup/restore/batch over the same session ---
        let library = DeviceLibrary(files: files)
        let backup = try await library.backup(deviceSKU: "TE032AS001", osVersion: "2.1.0")
        check(backup.sounds.count == 2, "backup captured 2 sounds — got \(backup.sounds.count)")
        check(backup.projectMetadata.isEmpty == false, "backup captured project metadata")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try BackupStore.write(backup, to: dir)
        let reloaded = try BackupStore.read(from: dir)
        check(reloaded.sounds.count == backup.sounds.count, "backup store round trip")
        check(reloaded.sounds.first?.pcm == backup.sounds.first?.pcm, "backup store pcm identical")
        check(reloaded.sounds.first?.metadata == backup.sounds.first?.metadata,
              "backup store metadata identical")
        try? FileManager.default.removeItem(at: dir)

        let wavs = try await library.downloadMany(backup.sounds.map(\.nodeID))
        check(wavs.count == 2 && wavs.allSatisfy { $0.name.hasSuffix(".wav") }, "downloadMany wavs")
        if let first = wavs.first {
            let info = try parseWAV(first.wav)
            check(info.sampleRate == 46875 && info.channels == 1, "downloaded wav format")
        }

        // wipe + restore
        try await library.deleteMany(backup.sounds.map(\.nodeID))
        let wiped = try await files.list(nodeID: soundsID)
        check(wiped.isEmpty, "wiped after deleteMany")
        try await library.restore(backup)
        let restored = try await files.list(nodeID: soundsID)
        check(restored.count == 2, "restored 2 sounds")
        check(Set(restored.map(\.id)) == Set(backup.sounds.map(\.nodeID)), "restored original node ids")

        // --- settings over command 6 ---
        let settings = SettingsService(session: session)
        try await settings.initialize()
        let all = try await settings.getAll()
        if case .array(let groups)? = all["settings"] {
            check(groups.count == 2, "settings groups — got \(groups.count)")
        } else {
            check(false, "settings groups missing")
        }

        // --- recycle bin: delete keeps a local copy, restore puts it back ---
        let binDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: binDir) }
        let bin = RecycleBin(root: binDir)
        let binTargets = try await files.list(nodeID: soundsID).map(\.id).sorted()
        let freeSlot = binTargets[0], takenSlot = binTargets[1]
        let freePCM = try await files.get(fileID: freeSlot).data
        let freeMeta = try await files.getMetadata(fileID: freeSlot)

        try await library.deleteMany([freeSlot, takenSlot], into: bin)
        let afterBinDelete = try await files.list(nodeID: soundsID)
        check(!afterBinDelete.contains { [freeSlot, takenSlot].contains($0.id) }, "bin delete removes from device")
        let binned = try bin.entries()
        check(Set(binned.map(\.originalSlot)) == [freeSlot, takenSlot],
              "bin holds both deleted sounds — got \(binned.map(\.originalSlot))")

        if let entry = binned.first(where: { $0.originalSlot == freeSlot }) {
            let back = try await library.restore(entry, from: bin)
            check(back == freeSlot, "bin restore uses the free original slot — got \(back)")
            check(try await files.get(fileID: back).data == freePCM, "bin restore pcm identical")
            check(try await files.getMetadata(fileID: back) == freeMeta, "bin restore metadata identical")
        } else {
            check(false, "bin entry for slot \(freeSlot) missing")
        }

        let squatter = try await files.put(parentID: soundsID, name: "squatter", data: [0, 0],
                                           fileID: takenSlot)
        if let entry = try bin.entries().first(where: { $0.originalSlot == takenSlot }) {
            let back = try await library.restore(entry, from: bin)
            check(back != takenSlot && back != 0, "bin restore falls back when the slot is taken — got \(back)")
            let ids = try await files.list(nodeID: soundsID).map(\.id)
            check(ids.contains(squatter) && ids.contains(back), "bin restore keeps the slot occupant")
        } else {
            check(false, "bin entry for slot \(takenSlot) missing")
        }
        check(try bin.entries().isEmpty, "bin empty after restoring everything")

        // --- recycle bin under injected faults, over a second connection ---
        let faulty = FaultyWire(inner: try CoreMIDIWire(pair: pair))
        let faultySession = SysExSession(wire: faulty, identityCode: identity.deviceID)
        let faultyFiles = DeviceFileService(session: faultySession)
        try await faultyFiles.initialize(subscribe: false)
        let faultyLibrary = DeviceLibrary(files: faultyFiles)
        let victim = try await files.list(nodeID: soundsID).map(\.id).sorted()[0]
        let victimPCM = try await files.get(fileID: victim).data
        func onDevice() async throws -> Bool {
            try await files.list(nodeID: soundsID).contains { $0.id == victim }
        }

        faulty.failAfterSend = { $0.payload.first == FileSub.metadata && $0.payload.dropFirst().first == 2 }
        check((try? await faultyLibrary.deleteMany([victim], into: bin)) == nil, "bin delete fails when metadata read fails")
        check(try await onDevice() && bin.entries().isEmpty, "unreadable metadata: sound kept, bin untouched")

        faulty.failAfterSend = nil
        do {
            try await library.deleteMany([soundsID], into: bin)
            check(false, "bin delete refuses a non-sound node")
        } catch RecycleBinError.notASound(let id) {
            let stillThere = try await resolve("/sounds")
            check(id == soundsID && stillThere == soundsID, "bin delete refuses a non-sound node")
        }

        faulty.truncateGets = true
        check((try? await faultyLibrary.deleteMany([victim], into: bin)) == nil, "bin delete fails on a truncated read")
        check(try await onDevice() && bin.entries().isEmpty, "truncated read: sound kept, bin untouched")
        faulty.truncateGets = false

        faulty.failBeforeSend = { $0.payload.first == FileSub.delete }
        check((try? await faultyLibrary.deleteMany([victim], into: bin)) == nil, "bin delete reports a refused delete")
        check(try await onDevice() && bin.entries().isEmpty, "refused delete: sound kept, bin untouched")
        faulty.failBeforeSend = nil

        faulty.failAfterSend = { $0.payload.first == FileSub.delete }
        check((try? await faultyLibrary.deleteMany([victim], into: bin)) == nil, "bin delete reports a lost delete reply")
        let keptEntry = try bin.entries().first
        check(try await !onDevice() && bin.entries().count == 1 && keptEntry?.originalSlot == victim,
              "lost delete reply: device deleted, bin keeps the copy")
        check(try keptEntry.map { try bin.load($0).pcm } == victimPCM, "lost delete reply: binned copy is complete")

        faulty.failAfterSend = { $0.payload.first == FileSub.metadata && $0.payload.dropFirst().first != 2 }
        if let keptEntry {
            check((try? await faultyLibrary.restore(keptEntry, from: bin)) == nil, "bin restore fails when metadata write fails")
            check(try await !onDevice() && bin.entries().count == 1,
                  "failed metadata write: half-restored sound removed, entry kept")
            faulty.failAfterSend = nil
            let back = try await faultyLibrary.restore(keptEntry, from: bin)
            check(back == victim, "bin restore retry lands in the original slot — got \(back)")
        }
        faulty.failAfterSend = nil

        try await library.deleteMany([victim], into: bin)
        if let entry = try bin.entries().first {
            faulty.failAfterSend = { $0.payload.starts(with: [FileSub.put, 1]) && $0.payload.count > 4 }
            check((try? await faultyLibrary.restore(entry, from: bin)) == nil, "bin restore fails when an upload page fails")
            check(try await !onDevice() && bin.entries().count == 1, "failed upload: partial sound removed, entry kept")
            faulty.failAfterSend = nil
            let back = try await faultyLibrary.restore(entry, from: bin)
            check(back == victim, "bin restore after a failed upload lands in the original slot — got \(back)")
        } else {
            check(false, "bin entry for slot \(victim) missing")
        }

        try await library.deleteMany([victim], into: bin)
        _ = try await files.put(parentID: soundsID, name: "squatter2", data: [0, 0], fileID: victim)
        let countBefore = try await files.list(nodeID: soundsID).count
        if let entry = try bin.entries().first {
            faulty.failAfterSend = { $0.payload.starts(with: [FileSub.put, 1]) && $0.payload.count > 4 }
            // Another writer adds a sound while the failing upload is in flight.
            let bystander = Bystander()
            faulty.beforeFailure = {
                await bystander.set(try? await files.put(parentID: soundsID, name: "bystander", data: [1, 2]))
            }
            do {
                _ = try await faultyLibrary.restore(entry, from: bin)
                check(false, "failed upload into an assigned slot reports a possible partial sound")
            } catch RecycleBinError.partialSoundMayRemain {
                check(true, "failed upload into an assigned slot reports a possible partial sound")
            } catch {
                check(false, "failed upload into an assigned slot reports a possible partial sound — got \(error)")
            }
            faulty.beforeFailure = nil
            let afterNodes = try await files.list(nodeID: soundsID)
            let bystanderID = await bystander.id
            check(bystanderID.map { id in afterNodes.contains { $0.id == id } } == true,
                  "failed restore leaves another writer's new sound alone")
            check(try afterNodes.count == countBefore + 2 && bin.entries().count == 1,
                  "failed upload into an assigned slot deletes nothing — \(countBefore) vs \(afterNodes.count)")
            faulty.failAfterSend = nil
        } else {
            check(false, "bin entry for slot \(victim) missing")
        }

        let folder = try await files.put(parentID: soundsID, name: "folder", data: [], isDirectory: true)
        let binnedBefore = try bin.entries().count
        do {
            try await library.deleteMany([victim, folder], into: bin)
            check(false, "bin delete refuses a folder")
        } catch RecycleBinError.notASound(let id) {
            check(id == folder, "bin delete refuses a folder — got \(id)")
        }
        let afterFolder = try await files.list(nodeID: soundsID).map(\.id)
        check(try afterFolder.contains(victim) && afterFolder.contains(folder) && bin.entries().count == binnedBefore,
              "bin delete checks every id before deleting any")

        // --- library path lookup ---
        do {
            _ = try await library.resolve("/nope")
            check(false, "resolve reports a missing path")
        } catch FileServiceError.pathNotFound(let path) {
            check(path == "/nope", "resolve reports a missing path — got \(path)")
        } catch {
            check(false, "resolve reports a missing path — got \(error)")
        }

        // --- backup restore: slot bookkeeping and partial uploads ---
        // The simulator hands out ids in order, so the next assigned id is known.
        let probe = try await files.put(parentID: soundsID, name: "probe", data: [0])
        try await files.delete(fileID: probe)
        let nextAssigned = probe + 1
        let occupied = try await files.list(nodeID: soundsID).map(\.id).sorted()[0]
        let soundA = SoundBackup(nodeID: occupied, pcm: Array(repeating: 0xA1, count: 300),
                                 metadata: ["name": .string("restore a")])
        let soundB = SoundBackup(nodeID: nextAssigned, pcm: Array(repeating: 0xB2, count: 300),
                                 metadata: ["name": .string("restore b")])
        try await library.restore(DeviceBackup(deviceSKU: "TE032AS001", osVersion: "2.1.0",
                                               createdAt: Date(), sounds: [soundA, soundB],
                                               projectMetadata: [:]))
        var restoredPCM: [[UInt8]] = []
        for node in try await files.list(nodeID: soundsID) where node.size == 300 {
            restoredPCM.append(try await files.get(fileID: node.id).data)
        }
        check(restoredPCM.contains(soundA.pcm) && restoredPCM.contains(soundB.pcm),
              "backup restore keeps a sound placed into an assigned slot — \(restoredPCM.count) of 2")

        let loneSlot: UInt16 = 900
        let lone = SoundBackup(nodeID: loneSlot, pcm: Array(repeating: 0xC3, count: 300),
                               metadata: ["name": .string("restore c")])
        let loneBackup = DeviceBackup(deviceSKU: "TE032AS001", osVersion: "2.1.0", createdAt: Date(),
                                      sounds: [lone], projectMetadata: [:])
        func slotListed() async throws -> Bool {
            try await files.list(nodeID: soundsID).contains { $0.id == loneSlot }
        }
        faulty.failAfterSend = { $0.payload.starts(with: [FileSub.put, 1]) && $0.payload.count > 4 }
        check((try? await faultyLibrary.restore(loneBackup)) == nil, "backup restore reports a failed upload")
        check(try await !slotListed(), "failed backup upload leaves no partial sound in its slot")
        faulty.failAfterSend = { $0.payload.first == FileSub.metadata && $0.payload.dropFirst().first != 2 }
        check((try? await faultyLibrary.restore(loneBackup)) == nil, "backup restore reports a failed metadata write")
        check(try await !slotListed(), "failed backup metadata write leaves no partial sound in its slot")
        faulty.failAfterSend = nil
        try await faultyLibrary.restore(loneBackup)
        let loneBack = try await slotListed() ? try await files.get(fileID: loneSlot).data : []
        check(loneBack == lone.pcm, "backup restore retry lands in the original slot")

        let owner = try await files.list(nodeID: soundsID).map(\.id).sorted()[0]
        let ownerPCM = try await files.get(fileID: owner).data
        let countBeforeTaken = try await files.list(nodeID: soundsID).count
        let intoTaken = DeviceBackup(deviceSKU: "TE032AS001", osVersion: "2.1.0", createdAt: Date(),
                                     sounds: [SoundBackup(nodeID: owner, pcm: Array(repeating: 0xD4, count: 300),
                                                          metadata: ["name": .string("restore d")])],
                                     projectMetadata: [:])
        faulty.failAfterSend = { $0.payload.starts(with: [FileSub.put, 1]) && $0.payload.count > 4 }
        check((try? await faultyLibrary.restore(intoTaken)) == nil, "backup restore into an assigned slot reports a failed upload")
        faulty.failAfterSend = nil
        let ownerAfter = try await files.get(fileID: owner).data
        let countAfterTaken = try await files.list(nodeID: soundsID).count
        check(ownerAfter == ownerPCM && countAfterTaken >= countBeforeTaken,
              "failed backup upload into an assigned slot deletes nothing — \(countBeforeTaken) vs \(countAfterTaken)")

        eventsTask.cancel()
        let seen = await eventsTask.value
        check(seen.contains { if case .addedUpdated = $0 { true } else { false } },
              "added event seen")
        check(seen.contains { if case .deleted = $0 { true } else { false } },
              "deleted event seen")

        if failures > 0 {
            print("\(failures) e2e check(s) FAILED")
            exit(1)
        }
        print("e2e: all checks passed")
    }
}

/// Wire wrapper that injects faults: an outbound frame can be delivered and then
/// reported as failed (the device acted, the client saw an error), and GET data
/// replies after the first page can be cut to an empty page.
final class FaultyWire: MIDIWire, @unchecked Sendable {
    private let inner: MIDIWire
    private let lock = NSLock()
    private var _failAfterSend: (@Sendable (TEFrame) -> Bool)?
    private var _failBeforeSend: (@Sendable (TEFrame) -> Bool)?
    private var _truncateGets = false
    private var _beforeFailure: (@Sendable () async -> Void)?
    private var getDataRequests: Set<UInt16> = []

    init(inner: MIDIWire) {
        self.inner = inner
    }

    /// The frame never reaches the device: an unambiguous failure.
    var failBeforeSend: (@Sendable (TEFrame) -> Bool)? {
        get { lock.withLock { _failBeforeSend } }
        set { lock.withLock { _failBeforeSend = newValue } }
    }

    var failAfterSend: (@Sendable (TEFrame) -> Bool)? {
        get { lock.withLock { _failAfterSend } }
        set { lock.withLock { _failAfterSend = newValue } }
    }

    /// Runs before a frame that is about to fail is delivered. Running it later
    /// would let the device reply arrive first and the call succeed after all.
    var beforeFailure: (@Sendable () async -> Void)? {
        get { lock.withLock { _beforeFailure } }
        set { lock.withLock { _beforeFailure = newValue } }
    }

    var truncateGets: Bool {
        get { lock.withLock { _truncateGets } }
        set { lock.withLock { _truncateGets = newValue } }
    }

    func send(_ bytes: [UInt8]) async throws {
        let frame = TEFrame.parse(bytes)
        if let frame, frame.payload.starts(with: [FileSub.get, 1]),
           Array(frame.payload.dropFirst(2)) != [0, 0] {
            lock.withLock { _ = getDataRequests.insert(frame.requestID) }
        }
        if let frame, failBeforeSend?(frame) == true {
            throw WireError.noDevice
        }
        let failing = frame.map { failAfterSend?($0) ?? false } ?? false
        if failing { await beforeFailure?() }
        try await inner.send(bytes)
        if failing { throw WireError.timeout }
    }

    func setMessageHandler(_ handler: (@Sendable ([UInt8]) -> Void)?) {
        guard let handler else {
            inner.setMessageHandler(nil)
            return
        }
        inner.setMessageHandler { [self] bytes in handler(rewrite(bytes)) }
    }

    private func rewrite(_ bytes: [UInt8]) -> [UInt8] {
        guard let frame = TEFrame.parse(bytes), frame.kind == .response, frame.hasRequestID,
              lock.withLock({ _truncateGets && getDataRequests.remove(frame.requestID) != nil })
        else { return bytes }
        // Header through the status byte, then only the page number: an empty page.
        return Array(bytes[0...9]) + SevenBitCoding.pack(Array(frame.payload.prefix(2))) + [0xF7]
    }
}

actor Bystander {
    private(set) var id: UInt16?
    func set(_ id: UInt16?) { self.id = id }
}
