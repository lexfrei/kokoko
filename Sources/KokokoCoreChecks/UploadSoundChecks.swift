import Foundation
import KokokoCore
import KokokoLibrary
import KokokoMIDI
import VirtualEP

extension KokokoCoreChecks {
    static func uploadSoundChecks() async {
        let vep = VirtualEPDevice(name: "kokoko-vep-upload-\(getpid())")
        do {
            try vep.start()
            try await Task.sleep(for: .milliseconds(300))
            guard let pair = enumerateMIDIPairs().first(where: { $0.name == vep.name }) else {
                check(false, "upload: device enumerated")
                return
            }
            let wire = try CoreMIDIWire(pair: pair)
            let identity = try await identifyDevice(on: wire)
            let session = SysExSession(wire: wire, identityCode: identity.deviceID)
            let files = DeviceFileService(session: session)
            try await files.initialize()

            vep.refuseMetadataSet = true
            do {
                try await files.setMetadata(fileID: 1, ["name": .string("x")])
                check(false, "vep: a refused metadata set fails")
            } catch SessionError.deviceError(let status, _) {
                eq(status, .specificError(16), "vep: a refused metadata set answers status 16")
            }
            vep.refuseMetadataSet = false
            vep.refuseDelete = true
            do {
                try await files.delete(fileID: 3)
                check(false, "vep: a refused delete fails")
            } catch SessionError.deviceError(let status, _) {
                eq(status, .specificError(16), "vep: a refused delete answers status 16")
            }
            vep.refuseDelete = false
            check(try await files.list(nodeID: 1).contains { $0.id == 3 }, "vep: a refused delete keeps the node")
            try await files.setMetadata(fileID: 1, ["name": .string("kick")])
            eq(try await files.getMetadata(fileID: 1)["name"]?.stringValue, "kick",
               "vep: metadata set works again once refusal is off")

            let soundsRoot = try await DeviceLibrary(files: files).resolve("/sounds")
            let pcm = [UInt8](repeating: 0, count: 400)
            let slot = try await uploadSound(files: files, parent: soundsRoot, name: "up ok", pcm: pcm,
                                             metadata: ["channels": .int(1)])
            eq(try await files.getMetadata(fileID: slot)["name"]?.stringValue, "up ok",
               "upload: a sound lands with its name in metadata")

            vep.refuseMetadataSet = true
            do {
                _ = try await uploadSound(files: files, parent: soundsRoot, name: "up refused", pcm: pcm,
                                          metadata: ["channels": .int(1)])
                check(false, "upload: a refused metadata write fails the upload")
            } catch let error as UploadSoundError {
                guard case .metadataRefused(let refusedSlot, _, let removed) = error else { return }
                check(removed, "upload: the sound whose metadata was refused is removed")
                let left = try await files.list(nodeID: soundsRoot).map(\.id)
                check(!left.contains(refusedSlot), "upload: no nameless sound stays on the device")
                let text = error.localizedDescription
                check(text.contains(String(format: "%03d", refusedSlot)),
                      "upload: the error names the slot — got \(text)")
            }
            vep.refuseMetadataSet = false

            let before = Set(try await files.list(nodeID: soundsRoot).map(\.id))
            vep.refusePutDataFromPage = 1
            do {
                _ = try await files.put(parentID: soundsRoot, name: "cut short", data: pcm)
                check(false, "vep: a put refused partway fails")
            } catch FileServiceError.putIncomplete(let fileID, let underlying) {
                let after = Set(try await files.list(nodeID: soundsRoot).map(\.id))
                eq(after.subtracting(before), [fileID], "put: a transfer cut short names the node init created")
                check(underlying.contains("16"), "put: the incomplete put keeps the device's reason — got \(underlying)")
                try await files.delete(fileID: fileID)
            }
            vep.refusePutDataFromPage = nil

            vep.refusePutDataFromPage = 1
            do {
                _ = try await uploadSound(files: files, parent: soundsRoot, name: "up cut", pcm: pcm,
                                          metadata: ["channels": .int(1)])
                check(false, "upload: a put cut short fails the upload")
            } catch UploadSoundError.putIncomplete(_, _, let removed) {
                check(removed, "upload: a put cut short removes its partial sound")
            }
            vep.refusePutDataFromPage = nil
            eq(Set(try await files.list(nodeID: soundsRoot).map(\.id)), before,
               "upload: no partial sound stays on the device")

            // Restores into a device-assigned slot: slot 3 (kick) is taken, so the
            // device picks the slot, and the transfer is cut short after init.
            let library = DeviceLibrary(files: files)
            let longPCM = [UInt8](repeating: 1, count: 400)
            let taken = SoundBackup(nodeID: 3, pcm: longPCM, metadata: ["name": .string("dup kick")])
            vep.refusePutDataFromPage = 1
            do {
                try await library.restore(DeviceBackup(deviceSKU: "", osVersion: "", createdAt: Date(),
                                                       sounds: [taken], projectMetadata: [:]))
                check(false, "restore: a backup sound cut short fails the restore")
            } catch FileServiceError.putIncomplete {
                check(true, "restore: a backup sound cut short passes on the incomplete put")
            }
            vep.refusePutDataFromPage = nil
            eq(Set(try await files.list(nodeID: soundsRoot).map(\.id)), before,
               "restore: a backup sound cut short in an assigned slot leaves no partial node")

            let binRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("kokoko-bin-check-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: binRoot) }
            let bin = RecycleBin(root: binRoot)
            let entry = try bin.add(taken)
            vep.refusePutDataFromPage = 1
            do {
                _ = try await library.restore(entry, from: bin)
                check(false, "restore: a bin sound cut short fails the restore")
            } catch FileServiceError.putIncomplete {
                check(true, "restore: a bin sound cut short passes on the incomplete put")
            }
            vep.refusePutDataFromPage = nil
            eq(Set(try await files.list(nodeID: soundsRoot).map(\.id)), before,
               "restore: a bin sound cut short in an assigned slot leaves no partial node")

            // The partial node cannot be removed either: the user is told one may remain.
            vep.refusePutDataFromPage = 1
            vep.refuseDelete = true
            do {
                _ = try await library.restore(entry, from: bin)
                check(false, "restore: a bin sound cut short with a refused delete fails")
            } catch RecycleBinError.partialSoundMayRemain(let underlying) {
                check(underlying.contains("16"),
                      "restore: a partial sound that stays is reported with its cause — got \(underlying)")
            }
            vep.refusePutDataFromPage = nil
            vep.refuseDelete = false
            for orphan in Set(try await files.list(nodeID: soundsRoot).map(\.id)).subtracting(before) {
                try await files.delete(fileID: orphan)
            }
        } catch {
            check(false, "upload checks threw \(error)")
        }
    }
}
