import Foundation
import KokokoCore
import CoreMIDI
import KokokoMIDI

// Read-only probe against real hardware: identify, greet, file init, list.
// Sends no write commands.

@MainActor
@main
struct Probe {
    static func main() async {
        let pairs = enumerateMIDIPairs()
        for pair in pairs {
            var offline: Int32 = -1
            MIDIObjectGetIntegerProperty(pair.destination, kMIDIPropertyOffline, &offline)
            var driver: Int32 = 0
            MIDIObjectGetIntegerProperty(pair.destination, kMIDIPropertyDriverVersion, &driver)
            print("pair \(pair.name): offline=\(offline) driverVer=\(driver) src=\(pair.source) dst=\(pair.destination)")
        }
        for pair in pairs {
            print("--- \(pair.name)")
            do {
                let wire = try CoreMIDIWire(pair: pair)
                var identity: Identity.Reply?
                for attempt in 1...3 {
                    if let reply = try? await identifyDevice(on: wire, timeout: .seconds(2)) {
                        identity = reply
                        break
                    }
                    print("  identity attempt \(attempt) no reply")
                }
                guard let identity else { continue }
                print("  identity: sku=\(identity.sku) deviceID=\(identity.deviceID)")
                let session = SysExSession(wire: wire, identityCode: identity.deviceID)
                let meta = try await session.greet()
                print("  os=\(meta.osVersion) serial=\(meta.serial) mode=\(meta.mode) sku=\(meta.sku) base=\(meta.baseSKU)")

                let files = DeviceFileService(session: session)
                try await files.initialize()
                print("  file init ok")

                let root = try await files.list(nodeID: 0)
                print("  root: \(root.map { "\($0.id):\($0.name)" })")
                if let sounds = root.first(where: { $0.name == "sounds" }) {
                    let metaSounds = try? await files.getMetadata(fileID: sounds.id, key: "formats")
                    print("  /sounds formats: \(String(describing: metaSounds))")
                    let nodes = try await files.list(nodeID: sounds.id)
                    for node in nodes {
                        print("  sound \(node.id): \(node.name) \(node.size)b flags=\(node.flags)")
                    }
                }
            } catch {
                print("  error: \(error)")
            }
        }
        print("probe done")
    }
}
