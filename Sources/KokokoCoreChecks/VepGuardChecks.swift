import Foundation
import KokokoCore
import KokokoLibrary
import KokokoMIDI
import VirtualEP

extension KokokoCoreChecks {
    static func vepGuardChecks() async {
        let vep = VirtualEPDevice(name: "kokoko-vep-guards-\(getpid())")
        defer { vep.stop() }
        do {
            try vep.start()
            try await Task.sleep(for: .milliseconds(300))
            guard let pair = enumerateMIDIPairs().first(where: { $0.name == vep.name }) else {
                check(false, "vep guards: device enumerated")
                return
            }
            let wire = try CoreMIDIWire(pair: pair)
            let identity = try await identifyDevice(on: wire)
            let session = SysExSession(wire: wire, identityCode: identity.deviceID)
            let files = DeviceFileService(session: session)
            try await files.initialize()
            let soundsRoot = try await DeviceLibrary(files: files).resolve("/sounds")
            let kick = try await files.list(nodeID: soundsRoot).first { $0.isFile }?.id ?? 0

            // -1e400 parses as -infinity, which JSON cannot carry back out.
            _ = try await session.call(command: TECommand.file,
                                       payload: SetMetadataRequest(fileID: kick, json: #"{"x":-1e400}"#).bytes)
            do {
                _ = try await files.getMetadata(fileID: kick)
                check(false, "vep: metadata JSON cannot carry is refused on get")
            } catch SessionError.deviceError(let status, _) {
                eq(status, .specificError(16), "vep: metadata JSON cannot carry answers status 16 on get")
            }
        } catch {
            check(false, "vep guard checks threw \(error)")
        }
    }
}
