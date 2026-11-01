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
            try await DeviceLibrary(files: files).resolve(path)
        }

        let soundsID = try await resolve("/sounds")
        let initialList = try await files.list(nodeID: soundsID)
        check(initialList.map(\.name).sorted() == ["kick", "snare"],
              "seeded sounds — got \(initialList.map(\.name).sorted())")

        // --- lock release after a failed transfer, isolated and first ---
        // Runs before any other fault injection on a connection of its own, so a lock
        // left held by a failed transfer shows up here by name instead of as a hang later.
        do {
            let lockWire = FaultyWire(inner: try CoreMIDIWire(pair: pair))
            let lockFiles = DeviceFileService(session: SysExSession(wire: lockWire, identityCode: identity.deviceID))
            try await lockFiles.initialize(subscribe: false)
            let probeID = initialList[0].id
            let expected = try await files.get(fileID: probeID).data
            lockWire.failAfterSend = { $0.payload.starts(with: [FileSub.get, 1]) }
            check((try? await lockFiles.get(fileID: probeID)) == nil, "a download that fails midway reports it")
            lockWire.failAfterSend = nil
            // Polled rather than awaited: a lock that is never released would hang an await.
            let nextRead = ReadBox()
            Task { nextRead.set(try? await lockFiles.get(fileID: probeID).data) }
            for _ in 0..<100 where nextRead.value == nil {
                try await Task.sleep(for: .milliseconds(100))
            }
            check(nextRead.value == expected, "a failed transfer releases the file service lock for the next one")
            if nextRead.value == nil {
                print("file service lock still held after a failed transfer; later results would be meaningless")
                exit(1)
            }
        }

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
        check(backup.projectMetadata["/projects"]?["active"] == nil,
              "backup leaves out the projects selection, which names no node in the tree")

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
                check(false, "failed upload into an assigned slot fails the restore")
            } catch {
                check(error.localizedDescription == WireError.timeout.localizedDescription,
                      "a failed upload into an assigned slot carries the cause as user-facing text — got \(error)")
            }
            faulty.beforeFailure = nil
            let afterNodes = try await files.list(nodeID: soundsID)
            let bystanderID = await bystander.id
            check(bystanderID.map { id in afterNodes.contains { $0.id == id } } == true,
                  "failed restore leaves another writer's new sound alone")
            check(try afterNodes.count == countBefore + 1 && bin.entries().count == 1,
                  "failed upload into an assigned slot removes only its own partial node — \(countBefore) vs \(afterNodes.count)")
            faulty.failAfterSend = nil
        } else {
            check(false, "bin entry for slot \(victim) missing")
        }

        // A failed init never names the node: nothing may be deleted, not even the
        // node the device created for it, since its id is unknown.
        if let entry = try bin.entries().first {
            let beforeInit = Set(try await files.list(nodeID: soundsID).map(\.id))
            faulty.failAfterSend = { $0.payload.starts(with: [FileSub.put, 0]) && $0.payload.count > 4 }
            do {
                _ = try await faultyLibrary.restore(entry, from: bin)
                check(false, "bin restore with a failed init into an assigned slot reports a possible partial sound")
            } catch RecycleBinError.partialSoundMayRemain {
                check(true, "bin restore with a failed init into an assigned slot reports a possible partial sound")
            } catch {
                check(false, "bin restore with a failed init into an assigned slot reports a possible partial sound — got \(error)")
            }
            faulty.failAfterSend = nil
            let afterInit = Set(try await files.list(nodeID: soundsID).map(\.id))
            check(afterInit.isSuperset(of: beforeInit) && afterInit.count == beforeInit.count + 1,
                  "bin restore with a failed init deletes nothing and leaves the node it cannot name — \(beforeInit.count) vs \(afterInit.count)")
            for orphan in afterInit.subtracting(beforeInit) { try await files.delete(fileID: orphan) }
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
        check(ownerAfter == ownerPCM && countAfterTaken == countBeforeTaken,
              "failed backup upload into an assigned slot removes only its own partial node and keeps the owner — \(countBeforeTaken) vs \(countAfterTaken)")

        let beforeInitTaken = Set(try await files.list(nodeID: soundsID).map(\.id))
        faulty.failAfterSend = { $0.payload.starts(with: [FileSub.put, 0]) && $0.payload.count > 4 }
        check((try? await faultyLibrary.restore(intoTaken)) == nil, "backup restore into an assigned slot reports a failed init")
        faulty.failAfterSend = nil
        let afterInitTaken = Set(try await files.list(nodeID: soundsID).map(\.id))
        let ownerAfterInit = try await files.get(fileID: owner).data
        check(ownerAfterInit == ownerPCM && afterInitTaken.isSuperset(of: beforeInitTaken)
                && afterInitTaken.count == beforeInitTaken.count + 1,
              "failed backup init into an assigned slot deletes nothing and keeps the owner — \(beforeInitTaken.count) vs \(afterInitTaken.count)")
        for orphan in afterInitTaken.subtracting(beforeInitTaken) { try await files.delete(fileID: orphan) }

        // --- backup: a short download is an error, not a smaller sound ---
        faulty.truncateGets = true
        do {
            _ = try await faultyLibrary.backup(deviceSKU: "TE032AS001", osVersion: "2.1.0", scope: .sounds)
            check(false, "backup rejects a truncated sound")
        } catch FileServiceError.truncated(let id, let expected, let got) {
            check(got < expected, "backup rejects a truncated sound — node \(id): \(got) of \(expected)")
        } catch {
            check(false, "backup rejects a truncated sound — got \(error)")
        }
        faulty.truncateGets = false
        let fullBackup = try await faultyLibrary.backup(deviceSKU: "TE032AS001", osVersion: "2.1.0", scope: .sounds)
        check(!fullBackup.sounds.isEmpty, "backup succeeds once reads are whole")

        // --- backup: metadata that cannot be read is reported, not dropped silently ---
        check(fullBackup.report.unreadMetadata.isEmpty && fullBackup.report.message == nil,
              "a backup that read every node's metadata reports nothing")
        if let unreadSound = try await files.list(nodeID: soundsID).first(where: { $0.isFile }) {
            let projectsRootID = try await resolve("/projects")
            let failingGets = [unreadSound.id, projectsRootID].map { Array(GetMetadataRequest(fileID: $0, page: 0).bytes.prefix(4)) }
            faulty.failAfterSend = { frame in failingGets.contains { frame.payload.starts(with: $0) } }
            let partial = try await faultyLibrary.backup(deviceSKU: "TE032AS001", osVersion: "2.1.0")
            faulty.failAfterSend = nil
            check(partial.report.unreadMetadata == [unreadSound.name, "/projects"],
                  "backup reports the sound and the project node whose metadata could not be read — got \(partial.report.unreadMetadata)")
            check(partial.sounds.first { $0.nodeID == unreadSound.id }?.metadata == [:],
                  "backup keeps a sound whose metadata could not be read, without metadata")
            check(partial.report.message?.contains(unreadSound.name) == true,
                  "backup report message names the sound — got \(partial.report.message ?? "nil")")
        } else {
            check(false, "a sound to back up without metadata")
        }

        // --- download: a sound whose format cannot be read is not written with a guessed one ---
        if let unknownFormat = try await files.list(nodeID: soundsID).first(where: { $0.isFile }) {
            let failingGet = Array(GetMetadataRequest(fileID: unknownFormat.id, page: 0).bytes.prefix(4))
            faulty.failAfterSend = { $0.payload.starts(with: failingGet) }
            let wavs = try? await faultyLibrary.downloadMany([unknownFormat.id])
            faulty.failAfterSend = nil
            check(wavs == nil, "download fails when the sound's format metadata cannot be read")
            let whole = try await faultyLibrary.downloadMany([unknownFormat.id])
            check(whole.count == 1, "download succeeds once the format metadata can be read")
        } else {
            check(false, "a sound to download without format metadata")
        }

        // --- backup restore is safe to repeat ---
        func soundCount() async throws -> Int { try await files.list(nodeID: soundsID).count }
        func copies(of pcm: [UInt8]) async throws -> Int {
            var n = 0
            for node in try await files.list(nodeID: soundsID) where Int(node.size) == pcm.count {
                if try await files.get(fileID: node.id).data == pcm { n += 1 }
            }
            return n
        }
        let first = SoundBackup(nodeID: 901, pcm: Array(repeating: 0xE5, count: 300), metadata: ["name": .string("again a")])
        let second = SoundBackup(nodeID: 902, pcm: Array(repeating: 0xF6, count: 300), metadata: ["name": .string("again b")])
        let twice = DeviceBackup(deviceSKU: "TE032AS001", osVersion: "2.1.0", createdAt: Date(),
                                 sounds: [first, second], projectMetadata: [:])
        // The upload of the second sound never starts, so the first one is the only thing restored.
        faulty.failBeforeSend = { $0.payload.starts(with: [FileSub.put, 0]) && $0.payload.count > 4
            && (UInt16($0.payload[3]) << 8 | UInt16($0.payload[4])) == 902 }
        check((try? await faultyLibrary.restore(twice)) == nil, "backup restore stops when an upload fails midway")
        faulty.failBeforeSend = nil
        try await library.restore(twice)
        let firstCopies = try await copies(of: first.pcm)
        let secondCopies = try await copies(of: second.pcm)
        check(firstCopies == 1 && secondCopies == 1,
              "retried backup restore does not duplicate what already landed — \(firstCopies), \(secondCopies)")

        try await files.setMetadata(fileID: 901, ["name": .string("stale")])
        try await library.restore(twice)
        let renamed = try await files.getMetadata(fileID: 901)["name"]?.stringValue
        check(renamed == "again a", "repeated backup restore reapplies metadata — got \(renamed ?? "nil")")

        // Twins: same PCM, and the first one lands in the slot that is the second one's original id.
        let twinProbe = try await files.put(parentID: soundsID, name: "probe", data: [0])
        try await files.delete(fileID: twinProbe)
        let twinPCM = Array(repeating: UInt8(0x2A), count: 300)
        let twinOccupied = try await files.list(nodeID: soundsID).map(\.id).sorted()[0]
        try await library.restore(DeviceBackup(
            deviceSKU: "TE032AS001", osVersion: "2.1.0", createdAt: Date(),
            sounds: [SoundBackup(nodeID: twinOccupied, pcm: twinPCM, metadata: ["name": .string("twin a")]),
                     SoundBackup(nodeID: twinProbe + 1, pcm: twinPCM, metadata: ["name": .string("twin b")])],
            projectMetadata: [:]))
        let twinCopies = try await copies(of: twinPCM)
        check(twinCopies == 2, "two backup sounds with identical PCM both land — \(twinCopies)")

        // A backup that lists the same original id twice: the second sound must not
        // be taken for the first one that this run just put back.
        let dupSlot = try await files.list(nodeID: soundsID).map(\.id).sorted()[0]
        let dupPCM = try await files.get(fileID: dupSlot).data
        let dupBefore = try await copies(of: dupPCM)
        try await library.restore(DeviceBackup(
            deviceSKU: "TE032AS001", osVersion: "2.1.0", createdAt: Date(),
            sounds: [SoundBackup(nodeID: dupSlot, pcm: dupPCM, metadata: ["name": .string("dup a")]),
                     SoundBackup(nodeID: dupSlot, pcm: dupPCM, metadata: ["name": .string("dup b")])],
            projectMetadata: [:]))
        let dupCopies = try await copies(of: dupPCM)
        // The first matches the occupant and is skipped; the second needs its own slot.
        check(dupCopies == dupBefore + 1, "a backup with a repeated sound id keeps both sounds — \(dupBefore) to \(dupCopies)")

        let reads = GetLog()
        faulty.failBeforeSend = { frame in
            if frame.payload.starts(with: [FileSub.get, 0]) && frame.payload.count > 3 {
                reads.record(UInt16(frame.payload[2]) << 8 | UInt16(frame.payload[3]))
            }
            return false
        }
        let otherSize = SoundBackup(nodeID: 901, pcm: Array(repeating: 0x3B, count: 299), metadata: ["name": .string("other size")])
        try await faultyLibrary.restore(DeviceBackup(deviceSKU: "TE032AS001", osVersion: "2.1.0", createdAt: Date(),
                                                     sounds: [otherSize], projectMetadata: [:]))
        faulty.failBeforeSend = nil
        check(!reads.ids.contains(901), "a size mismatch falls back without reading the occupant")

        let snapshot = try await library.backup(deviceSKU: "TE032AS001", osVersion: "2.1.0", scope: .sounds)
        let countBeforeSame = try await soundCount()
        try await library.restore(snapshot)
        let countAfterSame = try await soundCount()
        check(countAfterSame == countBeforeSame,
              "restoring a backup onto the same sounds adds nothing — \(countBeforeSame) vs \(countAfterSame)")

        let lookalike = SoundBackup(nodeID: 901, pcm: Array(repeating: 0x17, count: 300), metadata: ["name": .string("lookalike")])
        let countBeforeLook = try await soundCount()
        try await library.restore(DeviceBackup(deviceSKU: "TE032AS001", osVersion: "2.1.0", createdAt: Date(),
                                               sounds: [lookalike], projectMetadata: [:]))
        let lookCopies = try await copies(of: lookalike.pcm)
        let countAfterLook = try await soundCount()
        check(countAfterLook == countBeforeLook + 1 && lookCopies == 1,
              "a same-size occupant with other bytes is kept and the sound goes elsewhere")

        let countBeforeUnreadable = try await soundCount()
        faulty.failBeforeSend = { $0.payload.starts(with: [FileSub.get, 0]) && $0.payload.count > 3
            && (UInt16($0.payload[2]) << 8 | UInt16($0.payload[3])) == 901 }
        let unreadable = DeviceBackup(deviceSKU: "TE032AS001", osVersion: "2.1.0", createdAt: Date(),
                                      sounds: [first], projectMetadata: [:])
        check((try? await faultyLibrary.restore(unreadable)) != nil, "an unreadable occupant does not abort the restore")
        faulty.failBeforeSend = nil
        let countAfterUnreadable = try await soundCount()
        check(countAfterUnreadable == countBeforeUnreadable + 1,
              "an unreadable occupant falls back to an assigned slot — \(countBeforeUnreadable) vs \(countAfterUnreadable)")

        // --- backup restore: pad references follow a sound that moved ---
        let projectsID = try await resolve("/projects")
        _ = try await files.put(parentID: projectsID, name: "99", data: [], isDirectory: true)
        func pad(_ name: String) async throws -> UInt16 {
            try await files.put(parentID: projectsID, name: name, data: [], isDirectory: true)
        }
        func sym(_ pad: UInt16) async throws -> Int? { try await files.getMetadata(fileID: pad)["sym"]?.intValue }
        func landedAt(_ pcm: [UInt8]) async throws -> [UInt16] {
            var ids: [UInt16] = []
            for node in try await files.list(nodeID: soundsID) where Int(node.size) == pcm.count {
                if try await files.get(fileID: node.id).data == pcm { ids.append(node.id) }
            }
            return ids
        }
        func restoreWithPads(_ sounds: [SoundBackup], _ pads: [UInt16: Int]) async throws {
            let names = Dictionary(uniqueKeysWithValues: try await files.list(nodeID: projectsID).map { ($0.id, $0.name) })
            let byPath = Dictionary(uniqueKeysWithValues: pads.compactMap { id, sym in
                names[id].map { ("/projects/\($0)", ["sym": JSONValue.int(sym)]) }
            })
            try await library.restore(DeviceBackup(
                deviceSKU: "TE032AS001", osVersion: "2.1.0", createdAt: Date(), sounds: sounds,
                projectMetadata: byPath, projectArchives: ["99": [1, 2, 3]]))
        }

        let padOwner = try await files.list(nodeID: soundsID).map(\.id).sorted()[0]
        let wanderer = SoundBackup(nodeID: padOwner, pcm: Array(repeating: 0x4C, count: 300),
                                   metadata: ["name": .string("wanderer")])
        let movedPad = try await pad("pad moved")
        let foreignPad = try await pad("pad foreign")
        let oddPad = try await pad("pad odd")
        let notInBackup = try await files.list(nodeID: soundsID).map(\.id).sorted()[1]
        try await restoreWithPads([wanderer], [movedPad: Int(padOwner), foreignPad: Int(notInBackup), oddPad: -1])
        let wandererAt = try await landedAt(wanderer.pcm).first
        let movedSym = try await sym(movedPad)
        check(wandererAt != nil && wandererAt != padOwner && movedSym == wandererAt.map(Int.init),
              "a pad follows its sound to an assigned slot — sym \(movedSym.map(String.init) ?? "nil"), landed \(wandererAt.map(String.init) ?? "nil")")
        check(try await sym(foreignPad) == Int(notInBackup), "a pad naming a sound outside the backup keeps its reference")
        check(try await sym(oddPad) == -1, "a pad reference outside the id range passes through")

        // In place: a sound that lands in its own original slot keeps its pads.
        let homeSlot: UInt16 = 950
        let homer = SoundBackup(nodeID: homeSlot, pcm: Array(repeating: 0x5D, count: 300), metadata: ["name": .string("homer")])
        let homePad = try await pad("pad home")
        try await restoreWithPads([homer], [homePad: Int(homeSlot)])
        let homerAt = try await landedAt(homer.pcm)
        let homeSym = try await sym(homePad)
        check(homerAt == [homeSlot] && homeSym == Int(homeSlot),
              "a pad whose sound landed in its original slot keeps its reference")

        // Repeated id: the first sound takes the original slot, the pad must stay with it.
        let dupHome: UInt16 = 951
        let dupFirst = SoundBackup(nodeID: dupHome, pcm: Array(repeating: 0x6E, count: 300), metadata: ["name": .string("dup first")])
        let dupSecond = SoundBackup(nodeID: dupHome, pcm: Array(repeating: 0x7F, count: 300), metadata: ["name": .string("dup second")])
        let dupPad = try await pad("pad dup")
        try await restoreWithPads([dupFirst, dupSecond], [dupPad: Int(dupHome)])
        let dupSym = try await sym(dupPad)
        let dupFirstAt = try await landedAt(dupFirst.pcm)
        check(dupFirstAt == [dupHome] && dupSym == Int(dupHome),
              "a repeated sound id does not pull the pad off the sound in the original slot — sym \(dupSym.map(String.init) ?? "nil")")
        // Again: now the first sound is found already in place and only its metadata is reapplied.
        try await restoreWithPads([dupFirst, dupSecond], [dupPad: Int(dupHome)])
        let dupSymAgain = try await sym(dupPad)
        check(dupSymAgain == Int(dupHome),
              "a repeated sound id keeps the pad on a sound found already in place — sym \(dupSymAgain.map(String.init) ?? "nil")")

        // Chain: A's assigned slot is B's original id, so B moves on too.
        let padA = try await pad("pad chain a")
        let padB = try await pad("pad chain b")
        let chainProbe = try await files.put(parentID: soundsID, name: "probe", data: [0])
        try await files.delete(fileID: chainProbe)
        let chainTaken = try await files.list(nodeID: soundsID).map(\.id).sorted()[0]
        let chainA = SoundBackup(nodeID: chainTaken, pcm: Array(repeating: 0x81, count: 300), metadata: ["name": .string("chain a")])
        let chainB = SoundBackup(nodeID: chainProbe + 1, pcm: Array(repeating: 0x92, count: 300), metadata: ["name": .string("chain b")])
        try await restoreWithPads([chainA, chainB], [padA: Int(chainTaken), padB: Int(chainProbe + 1)])
        let aAt = try await landedAt(chainA.pcm).first.map(Int.init)
        let bAt = try await landedAt(chainB.pcm).first.map(Int.init)
        let symA = try await sym(padA)
        let symB = try await sym(padB)
        check(aAt == Int(chainProbe + 1) && symA == aAt && symB == bAt && bAt != aAt,
              "chained moves map each pad one step — a \(symA.map(String.init) ?? "nil")/\(aAt.map(String.init) ?? "nil"), b \(symB.map(String.init) ?? "nil")/\(bAt.map(String.init) ?? "nil")")
        // --- one transfer at a time per device ---
        // The device keeps a single transfer state and data pages carry only a page
        // number, so overlapping multi-page transfers must not interleave.
        let pcmX = (0..<640).map { UInt8($0 % 251) }
        let pcmY = (0..<640).map { UInt8(255 - $0 % 251) }
        let soundX = try await files.put(parentID: soundsID, name: "parallel x", data: pcmX)
        let soundY = try await files.put(parentID: soundsID, name: "parallel y", data: pcmY)
        var mixedReads = 0
        var rightLengthWrongBytes = 0
        for _ in 0..<5 {
            async let readX = files.get(fileID: soundX)
            async let readY = files.get(fileID: soundY)
            let (gotX, gotY) = try await (readX.data, readY.data)
            if gotX != pcmX || gotY != pcmY { mixedReads += 1 }
            if (gotX.count == pcmX.count && gotX != pcmX) || (gotY.count == pcmY.count && gotY != pcmY) {
                rightLengthWrongBytes += 1
            }
        }
        check(mixedReads == 0,
              "parallel downloads each get their own bytes — \(mixedReads) of 5 rounds mixed, \(rightLengthWrongBytes) with a right-length wrong copy")

        let pcmZ = (0..<640).map { UInt8(($0 * 7) % 256) }
        let pcmW = (0..<640).map { UInt8(($0 * 13) % 256) }
        async let putZ = try? files.put(parentID: soundsID, name: "parallel z", data: pcmZ)
        async let putW = try? files.put(parentID: soundsID, name: "parallel w", data: pcmW)
        let (soundZ, soundW) = await (putZ, putW)
        var landedBoth = false
        if let soundZ, let soundW {
            let backZ = try await files.get(fileID: soundZ).data
            let backW = try await files.get(fileID: soundW).data
            landedBoth = backZ == pcmZ && backW == pcmW
        }
        check(landedBoth, "parallel uploads each land their own bytes — ids \(soundZ.map(String.init) ?? "failed"), \(soundW.map(String.init) ?? "failed")")


        // --- bin restore: a stale entry for a sound that is already back ---
        // restore drops its entry only after the sound is back; if that drop fails, the
        // entry stays, and restoring it again must not upload a second copy.
        let staleSlot = try await files.list(nodeID: soundsID).map(\.id).sorted()[0]
        let stalePCM = try await files.get(fileID: staleSlot).data
        let staleMeta = try await files.getMetadata(fileID: staleSlot)
        let staleEntry = try bin.add(SoundBackup(nodeID: staleSlot, pcm: stalePCM, metadata: staleMeta))
        let countBeforeStale = try await files.list(nodeID: soundsID).count
        let staleBack = try await library.restore(staleEntry, from: bin)
        let countAfterStale = try await files.list(nodeID: soundsID).count
        let staleGone = try !bin.entries().contains { $0.id == staleEntry.id }
        check(staleBack == staleSlot && countAfterStale == countBeforeStale && staleGone,
              "restoring a stale bin entry adds no copy and drops the entry — \(countBeforeStale) vs \(countAfterStale), slot \(staleBack)")

        // Same PCM, but the entry carries settings the slot does not have: the entry is
        // the only copy of them, so it is restored rather than dropped.
        var tunedMeta = staleMeta
        tunedMeta["name"] = .string("tuned before delete")
        let tunedEntry = try bin.add(SoundBackup(nodeID: staleSlot, pcm: stalePCM, metadata: tunedMeta))
        let tunedBack = try await library.restore(tunedEntry, from: bin)
        let tunedName = try await files.getMetadata(fileID: tunedBack)["name"]?.stringValue
        check(tunedName == "tuned before delete",
              "a bin entry whose metadata differs from the slot is restored, not dropped — got \(tunedName ?? "nil") in \(tunedBack)")

        // Same size, other bytes: the occupant is a different sound.
        let lookalikeBinPCM = stalePCM.map { $0 ^ 0xFF }
        let lookalikeBinEntry = try bin.add(SoundBackup(nodeID: staleSlot, pcm: lookalikeBinPCM, metadata: staleMeta))
        let lookalikeBinBack = try await library.restore(lookalikeBinEntry, from: bin)
        let lookalikeBinData = try await files.get(fileID: lookalikeBinBack).data
        check(lookalikeBinBack != staleSlot && lookalikeBinData == lookalikeBinPCM,
              "a same-size occupant with other bytes does not count as the binned sound")

        // An occupant that cannot be read back is not taken for the same sound.
        let unreadableEntry = try bin.add(SoundBackup(nodeID: staleSlot, pcm: stalePCM, metadata: staleMeta))
        faulty.failBeforeSend = { $0.payload.starts(with: [FileSub.get, 0]) && $0.payload.count > 3
            && (UInt16($0.payload[2]) << 8 | UInt16($0.payload[3])) == staleSlot }
        let unreadableBack = try? await faultyLibrary.restore(unreadableEntry, from: bin)
        faulty.failBeforeSend = nil
        let countAfterUnreadableBin = try await files.list(nodeID: soundsID).count
        check(unreadableBack != nil && unreadableBack != staleSlot && countAfterUnreadableBin == countAfterStale + 3,
              "an unreadable occupant falls back to a normal bin restore")

        // Bytes match but the slot's metadata cannot be read: not proven the same, so restore normally.
        let metaUnreadableEntry = try bin.add(SoundBackup(nodeID: staleSlot, pcm: stalePCM, metadata: staleMeta))
        let countBeforeMetaUnreadable = try await files.list(nodeID: soundsID).count
        faulty.failBeforeSend = { $0.payload.starts(with: [FileSub.metadata, 2]) && $0.payload.count > 3
            && (UInt16($0.payload[2]) << 8 | UInt16($0.payload[3])) == staleSlot }
        let metaUnreadableBack = try? await faultyLibrary.restore(metaUnreadableEntry, from: bin)
        faulty.failBeforeSend = nil
        let countAfterMetaUnreadable = try await files.list(nodeID: soundsID).count
        check(metaUnreadableBack != nil && metaUnreadableBack != staleSlot
                && countAfterMetaUnreadable == countBeforeMetaUnreadable + 1,
              "unreadable occupant metadata falls back to a normal bin restore")

        // --- metadata types survive a round trip through the device ---
        let typedID = try await files.list(nodeID: soundsID).map(\.id).sorted()[0]
        let typed: [String: JSONValue] = ["kk.flag": .bool(true), "kk.nothing": .null, "kk.ratio": .double(2.5)]
        try await files.setMetadata(fileID: typedID, typed)
        let typedBack = try await files.getMetadata(fileID: typedID)
        check(typed.allSatisfy { typedBack[$0.key] == $0.value },
              "bool, null and fractional metadata come back unchanged — got \(typed.keys.sorted().map { "\($0)=\(typedBack[$0].map { "\($0)" } ?? "missing")" })")

        // --- metadata that JSON cannot carry is an error, not a crash ---
        let unwritable: [String: JSONValue] = ["kk.bad": .double(.nan)]
        do {
            try await files.setMetadata(fileID: typedID, unwritable)
            check(false, "unserializable metadata is refused on set")
        } catch FileServiceError.unserializableMetadata {
            check(true, "unserializable metadata is refused on set")
        }
        let countBeforeBadPut = try await files.list(nodeID: soundsID).count
        do {
            _ = try await files.put(parentID: soundsID, name: "bad meta", data: [1, 2], metadata: unwritable)
            check(false, "unserializable metadata is refused on upload")
        } catch FileServiceError.unserializableMetadata {
            let countAfterBadPut = try await files.list(nodeID: soundsID).count
            check(countAfterBadPut == countBeforeBadPut, "unserializable metadata is refused on upload before anything is sent")
        }

        // --- moves: a single move, a swap and a bulk move, as the app sends them ---
        func data(_ id: UInt16) async -> [UInt8]? { try? await files.get(fileID: id).data }
        func run(_ plan: [(from: UInt16, to: UInt16)]) async throws {
            for step in plan { try await files.move(fileID: step.from, toParent: soundsID, newFileID: step.to) }
        }
        for (slot, byte) in [(200, 1), (220, 2), (221, 3), (230, 4), (232, 5)] as [(UInt16, UInt8)] {
            _ = try await files.put(parentID: soundsID, name: "mv\(slot)", data: [byte, byte], fileID: slot)
        }
        do {
            try await run([(200, 210)])
            let ids = Set(try await files.list(nodeID: soundsID).map(\.id))
            let moved = await data(210)
            check(ids.contains(210) && !ids.contains(200) && moved == [1, 1],
                  "a move puts the sound in the new slot and frees the old one")
        } catch {
            check(false, "a move puts the sound in the new slot and frees the old one — threw \(error)")
        }
        do {
            try await run(planSwap(220, 221, occupied: Set(try await files.list(nodeID: soundsID).map(\.id))))
            let swappedLow = await data(220), swappedHigh = await data(221)
            check(swappedLow == [3, 3] && swappedHigh == [2, 2], "a swap trades the two sounds' slots")
        } catch {
            check(false, "a swap trades the two sounds' slots — threw \(error)")
        }
        do {
            let occupied = Set(try await files.list(nodeID: soundsID).map(\.id))
            if let plan = planBulkMove(selected: [232, 230], occupied: occupied, start: 240) {
                try await run(plan)
                let first = await data(240), second = await data(241)
                check(first == [4, 4] && second == [5, 5], "a bulk move puts the selection on consecutive slots in order")
            } else {
                check(false, "a bulk move puts the selection on consecutive slots in order — no plan")
            }
        } catch {
            check(false, "a bulk move puts the selection on consecutive slots in order — threw \(error)")
        }
        do {
            try await files.move(fileID: 210, toParent: soundsID, newFileID: 220)
            check(false, "a move onto a taken slot is refused")
        } catch SessionError.deviceError(let status, _) {
            let keptMoved = await data(210), keptTarget = await data(220)
            check(status == .specificError(16) && keptMoved == [1, 1] && keptTarget == [3, 3],
                  "a move onto a taken slot is refused and changes nothing")
        } catch {
            check(false, "a move onto a taken slot is refused and changes nothing — threw \(error)")
        }

        eventsTask.cancel()
        let seen = await eventsTask.value
        check(seen.contains(.moved(oldNodeID: 200, parentID: soundsID, newNodeID: 210)), "moved event seen")
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

final class GetLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [UInt16] = []
    var ids: [UInt16] { lock.withLock { _ids } }
    func record(_ id: UInt16) { lock.withLock { _ids.append(id) } }
}

final class ReadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [UInt8]?
    var value: [UInt8]? { lock.withLock { _value } }
    func set(_ value: [UInt8]?) { lock.withLock { _value = value } }
}
