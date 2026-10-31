import Foundation
import KokokoCore
import KokokoMIDI
import VirtualEP

extension KokokoCoreChecks {
    static func virtualDeviceChecks() async {
        let vep = VirtualEPDevice()
        do {
            try vep.start()
            try await Task.sleep(for: .milliseconds(300))
            guard let pair = enumerateMIDIPairs().first(where: { $0.name == vep.name }) else {
                check(false, "vep: device enumerated")
                return
            }
            let wire = try CoreMIDIWire(pair: pair)
            let identity = try await identifyDevice(on: wire)
            let session = SysExSession(wire: wire, identityCode: identity.deviceID)
            let files = DeviceFileService(session: session)
            try await files.initialize()
            let events = Task { () -> [FileEvent] in
                var seen: [FileEvent] = []
                for await event in await session.fileEvents() { seen.append(event) }
                return seen
            }
            try await Task.sleep(for: .milliseconds(100))

            let missing: UInt16 = 4000
            func rejectsMissingNode(_ label: String, _ operation: () async throws -> Void) async {
                do {
                    try await operation()
                    check(false, "\(label) — succeeded")
                } catch SessionError.deviceError(let status, _) {
                    eq(status, .specificError(16), label)
                } catch {
                    check(false, "\(label) — threw \(error)")
                }
            }
            await rejectsMissingNode("vep: delete of a missing node answers status 16") {
                try await files.delete(fileID: missing)
            }
            await rejectsMissingNode("vep: move of a missing node answers status 16") {
                try await files.move(fileID: missing, toParent: 1)
            }
            await rejectsMissingNode("vep: info of a missing node answers status 16") {
                _ = try await files.info(fileID: missing)
            }

            try await Task.sleep(for: .milliseconds(200))
            events.cancel()
            let seen = await events.value
            check(!seen.contains(.deleted(nodeID: missing)), "vep: no delete event for a missing node")
        } catch {
            check(false, "vep checks threw \(error)")
        }
    }
}
