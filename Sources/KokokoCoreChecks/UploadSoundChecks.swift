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
        } catch {
            check(false, "upload checks threw \(error)")
        }
    }
}
