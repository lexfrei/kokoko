import Foundation
import KokokoCore
import CoreMIDI
import KokokoAudio
import KokokoMIDI

// Probe of a connected EP device, read-only unless --write-test, which
// uploads, moves and deletes a test file and creates and deletes a test
// directory in /sounds.

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
                    if CommandLine.arguments.contains("--write-test") {
                        // Upload a tiny in-format sound, read it back, delete it.
                        var pcm: [UInt8] = []
                        for i in 0..<4000 {
                            let v = Int16(sin(Double(i) / 8.0) * 8000)
                            pcm.append(UInt8(UInt16(bitPattern: v) & 0xFF))
                            pcm.append(UInt8(UInt16(bitPattern: v) >> 8))
                        }
                        let wav = makeWAV(pcm: pcm, channels: 1, sampleRate: 46875)
                        let prepared = try prepareForUpload(fileData: Data(wav), fileName: "kokoko-test.wav")
                        let newID = try await files.put(parentID: sounds.id, name: "kokoko-test", data: prepared.pcm)
                        print("  write-test: uploaded id=\(newID)")
                        let afterUp = try await files.list(nodeID: sounds.id)
                        let listed = afterUp.first(where: { $0.id == newID })
                        print("  write-test: listed as name=\(listed?.name ?? "?") size=\(listed?.size ?? 0)")
                        let nodesNow = try await files.list(nodeID: sounds.id)
                        var free: UInt16 = 900
                        while nodesNow.contains(where: { $0.id == free }) { free += 1 }
                        try await files.move(fileID: newID, toParent: sounds.id, newFileID: free)
                        let afterMove = try await files.list(nodeID: sounds.id)
                        let moved = afterMove.first(where: { $0.id == free })
                        print("  write-test: renumbered to \(free), listed as \(moved?.name ?? "?")")
                        let back = try await files.get(fileID: free)
                        print("  write-test: readback \(back.data == prepared.pcm ? "MATCH" : "MISMATCH") (\(back.data.count)b)")
                        try await files.delete(fileID: free)
                        let afterDel = try await files.list(nodeID: sounds.id)
                        print("  write-test: deleted \(afterDel.contains(where: { $0.id == free }) ? "STILL PRESENT" : "gone")")

                        // Can /sounds hold folders?
                        do {
                            let dirID = try await files.put(parentID: sounds.id, name: "kokoko-dir", data: [],
                                                            capabilities: [FileCapability.read, FileCapability.write, FileCapability.delete],
                                                            isDirectory: true)
                            print("  write-test: dir create gave id=\(dirID)")
                            try await files.delete(fileID: dirID)
                            print("  write-test: dir deleted")
                        } catch {
                            print("  write-test: dir create failed: \(error)")
                        }
                    }
                    if CommandLine.arguments.contains("--settings-dump") {
                        let settings = SettingsService(session: session)
                        try await settings.initialize()
                        let all = try await settings.getAll()
                        let data = try JSONSerialization.data(
                            withJSONObject: all.mapValues(\.anyValue),
                            options: [.prettyPrinted, .sortedKeys])
                        let out = "/tmp/kokoko-settings-dump.json"
                        try data.write(to: URL(fileURLWithPath: out))
                        print("  settings dumped to \(out) (\(data.count) bytes)")
                    }
                    if CommandLine.arguments.contains("--download-smallest"),
                       let smallest = nodes.filter({ $0.isFile }).min(by: { $0.size < $1.size }) {
                        let got = try await files.get(fileID: smallest.id)
                        let expected = Int(smallest.size)
                        print("  download \(got.name): \(got.data.count)b (expected \(expected)) \(got.data.count == expected ? "MATCH" : "MISMATCH")")
                    }
                }
            } catch {
                print("  error: \(error)")
            }
        }
        print("probe done")
    }
}
