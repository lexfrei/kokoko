import CoreMIDI
import Foundation
import KokokoCore
import KokokoMIDI

// Exploration of a connected EP device; asks it to play one sound aloud.
// --command-scan sends every command except DFU with an empty payload and
// may change device state or crash the firmware.

@MainActor
@main
struct Explore {
    static var session0: SysExSession?
    static func main() async throws {
        let pairs = enumerateMIDIPairs().filter {
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty($0.destination, kMIDIPropertyOffline, &offline)
            return offline == 0
        }
        var files: DeviceFileService?
        for pair in pairs {
            guard let wire = try? CoreMIDIWire(pair: pair),
                  let identity = try? await identifyDevice(on: wire, timeout: .seconds(2)) else { continue }
            let session = SysExSession(wire: wire, identityCode: identity.deviceID)
            session0 = session
            guard let meta = try? await session.greet() else { continue }
            print("device: \(meta.sku) base=\(meta.baseSKU) os=\(meta.osVersion) mode=\(meta.mode)")
            let service = DeviceFileService(session: session)
            try await service.initialize()
            files = service
            break
        }
        guard let files else {
            print("no device")
            return
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

        func dumpTree(_ path: String, _ depth: Int) async {
            let indent = String(repeating: "  ", count: depth)
            do {
                let id = try await resolve(path)
                let meta = (try? await files.getMetadata(fileID: id)) ?? [:]
                let interesting = meta.filter { ["active", "sym", "name", "slots", "free_space_in_bytes", "max_capacity"].contains($0.key) }
                print("\(indent)\(path) id=\(id) meta=\(interesting.isEmpty ? "-" : "\(interesting)")")
                for child in try await files.list(nodeID: id) where !child.isFile {
                    await dumpTree(path + "/" + child.name, depth + 1)
                }
            } catch {
                print("\(indent)\(path) error: \(error)")
            }
        }
        await dumpTree("/projects", 0)

        // --- real sound metadata ---
        let soundsID = try await resolve("/sounds")
        let sounds = try await files.list(nodeID: soundsID)
        print("sounds: \(sounds.count) files")
        for node in sounds.prefix(3) {
            let meta = try await files.getMetadata(fileID: node.id)
            print("  \(node.name) meta keys: \(meta.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }

        // --- playback one short sound (audible!) ---
        if let first = sounds.first(where: { $0.isFile }) {
            print("playing 1s of \(first.name)...")
            try? await files.startPlayback(fileID: first.id, offset: 0, length: 1000)
            try await Task.sleep(for: .milliseconds(1300))
        }

        // --- command surface scan: empty payload, short timeout, skip DFU ---
        if CommandLine.arguments.contains("--command-scan") {
            print("command scan (empty payload, 500ms):")
            var results: [String] = []
            for cmd: UInt8 in 0...127 {
                if cmd == 3 { continue } // DFU
                do {
                    _ = try await session0!.call(command: cmd, payload: [], timeout: .milliseconds(500))
                    results.append("\(cmd): ok")
                } catch SessionError.deviceError(let status, _) {
                    results.append("\(cmd): status=\(status)")
                } catch SessionError.timeout {
                    results.append("\(cmd): timeout")
                } catch {
                    results.append("\(cmd): error \(error)")
                }
            }
            for r in results { print("  " + r) }
        }

        print("explore done")
    }
}
