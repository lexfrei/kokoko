import Foundation
import KokokoCore
import KokokoLibrary

extension KokokoCoreChecks {
    static func recycleBinChecks() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoko-bin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let bin = RecycleBin(root: root)
            eq(try bin.entries().count, 0, "bin empty before first use")

            let kick = SoundBackup(nodeID: 7, pcm: [1, 2, 3, 4],
                                   metadata: ["name": .string("kick"), "channels": .int(1)])
            let snare = SoundBackup(nodeID: 9, pcm: Array(repeating: 0xAB, count: 300),
                                    metadata: ["name": .string("snare")])
            let first = try bin.add(kick, deletedAt: Date(timeIntervalSince1970: 100))
            let second = try bin.add(snare, deletedAt: Date(timeIntervalSince1970: 200))

            let listed = try RecycleBin(root: root).entries()
            eq(listed.map(\.id), [second.id, first.id], "bin lists newest first, survives reopen")
            eq(listed.last?.originalSlot, 7, "bin entry keeps original slot")
            eq(listed.last?.name, "kick", "bin entry keeps display name")

            let loaded = try bin.load(first)
            eq(loaded.pcm, kick.pcm, "bin pcm round trip")
            eq(loaded.metadata, kick.metadata, "bin metadata round trip")
            eq(loaded.nodeID, 7, "bin load restores node id")

            let again = try bin.add(kick, deletedAt: Date(timeIntervalSince1970: 300))
            check(again.id != first.id, "deleting the same slot twice keeps both copies")

            try bin.remove(first)
            eq(try bin.entries().map(\.id), [again.id, second.id], "bin remove drops one entry")

            // A crash between writing the pcm and the info file leaves a bare directory.
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("half-written"), withIntermediateDirectories: true)
            eq(try bin.entries().count, 2, "bin ignores entries without info")
            try FileManager.default.removeItem(at: root.appendingPathComponent("half-written"))

            let broken = root.appendingPathComponent("broken")
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try Data("{not json".utf8).write(to: broken.appendingPathComponent("info.json"))
            eq(try bin.entries().count, 2, "bin skips an unreadable info file")
            try FileManager.default.removeItem(at: broken)

            check((try? bin.load(first)) == nil, "bin load of a removed entry throws")
            check((try? bin.remove(first)) == nil, "bin remove of a removed entry throws")

            // NaN is not representable in JSON, so the info write fails after the pcm landed.
            let unwritable = SoundBackup(nodeID: 3, pcm: [9], metadata: ["x": .double(.nan)])
            check((try? bin.add(unwritable)) == nil, "bin add with unwritable metadata throws")
            let dirs = try FileManager.default.contentsOfDirectory(atPath: root.path)
            eq(dirs.count, 2, "failed bin add leaves no directory behind")
        } catch {
            check(false, "recycle bin threw \(error)")
        }
    }
}
