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
            await rejectsMissingNode("vep: metadata get of a missing node answers status 16") {
                _ = try await files.getMetadata(fileID: missing)
            }
            await rejectsMissingNode("vep: metadata set of a missing node answers status 16") {
                try await files.setMetadata(fileID: missing, ["name": .string("x")])
            }
            await rejectsMissingNode("vep: paged metadata set of a missing node answers status 16") {
                try await files.setMetadata(fileID: missing, ["name": .string(String(repeating: "x", count: 200))])
            }
            await rejectsMissingNode("vep: playback of a missing node answers status 16") {
                try await files.startPlayback(fileID: missing)
            }

            let root = try await files.list(nodeID: 0)
            guard let sounds = root.first(where: { $0.name == "sounds" }),
                  let sound = try await files.list(nodeID: sounds.id).first else {
                check(false, "vep: seeded /sounds with a sound")
                return
            }
            await rejectsMissingNode("vep: move into a missing parent answers status 16") {
                try await files.move(fileID: sound.id, toParent: missing)
            }
            await rejectsMissingNode("vep: delete of the root answers status 16") {
                try await files.delete(fileID: 0)
            }
            await rejectsMissingNode("vep: move of the root answers status 16") {
                try await files.move(fileID: 0, toParent: sounds.id, newFileID: 3100)
            }
            await rejectsMissingNode("vep: delete of a non-empty directory answers status 16") {
                try await files.delete(fileID: sounds.id)
            }
            let soundsAfter = try await files.list(nodeID: sounds.id)
            check(soundsAfter.contains { $0.id == sound.id }, "vep: refused operations leave the sound in place")

            func accepts(_ label: String, _ operation: () async throws -> Void) async {
                do {
                    try await operation()
                    check(true, label)
                } catch {
                    check(false, "\(label) — threw \(error)")
                }
            }
            await accepts("vep: playback of a known node is accepted") {
                try await files.startPlayback(fileID: sound.id)
            }
            await accepts("vep: move into an existing parent is accepted") {
                try await files.move(fileID: sound.id, toParent: sounds.id)
            }
            do {
                let original = try await files.get(fileID: sound.id).data
                let first = try await files.put(parentID: sounds.id, name: "alloc a", data: [1])
                try await files.move(fileID: sound.id, toParent: sounds.id, newFileID: first + 1)
                let second = try await files.put(parentID: sounds.id, name: "alloc b", data: [2])
                let movedData = try await files.get(fileID: first + 1).data
                check(second != first + 1 && movedData == original,
                      "vep: a new node never takes the id a moved node holds")
                let listed = try await files.list(nodeID: sounds.id).map(\.id)
                check(listed.contains(first + 1) && !listed.contains(sound.id),
                      "vep: a move with a new id re-keys the node")
            } catch {
                check(false, "vep: a move with a new id re-keys the node — threw \(error)")
            }
            do {
                let dir = try await files.put(parentID: sounds.id, name: "dir", data: [], isDirectory: true)
                let child = try await files.put(parentID: dir, name: "child", data: [7])
                try await files.move(fileID: dir, toParent: sounds.id, newFileID: 3000)
                let children = try await files.list(nodeID: 3000).map(\.id)
                check(children == [child], "vep: a moved directory keeps its children")
                try await files.delete(fileID: child)
                try await files.delete(fileID: 3000)
            } catch {
                check(false, "vep: a moved directory keeps its children — threw \(error)")
            }
            await accepts("vep: delete of an empty directory is accepted") {
                let empty = try await files.put(parentID: sounds.id, name: "empty", data: [], isDirectory: true)
                try await files.delete(fileID: empty)
            }

            try await Task.sleep(for: .milliseconds(200))
            events.cancel()
            let seen = await events.value
            check(seen.contains { if case .moved = $0 { true } else { false } }, "vep: an accepted move emits a moved event")
            check(!seen.contains(.deleted(nodeID: missing)), "vep: no delete event for a missing node")
            check(!seen.contains(.deleted(nodeID: 0)) && !seen.contains(.deleted(nodeID: sounds.id)),
                  "vep: no delete event for a refused delete")
        } catch {
            check(false, "vep checks threw \(error)")
        }
    }
}
