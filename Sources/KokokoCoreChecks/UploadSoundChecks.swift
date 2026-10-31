import Foundation
import KokokoCore
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
        } catch {
            check(false, "upload checks threw \(error)")
        }
    }
}
