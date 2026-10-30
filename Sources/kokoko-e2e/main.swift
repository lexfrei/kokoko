import Foundation
import KokokoAudio
import KokokoCore
import KokokoMIDI
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
        guard let pair = pairs.first(where: { $0.name == "kokoko-vep" }) else {
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
                if seen.count >= 2 { break }
            }
            return seen
        }
        let eventsTimeout = Task {
            try? await Task.sleep(for: .seconds(60))
            eventsTask.cancel()
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

        let seen = await eventsTask.value
        eventsTimeout.cancel()
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
