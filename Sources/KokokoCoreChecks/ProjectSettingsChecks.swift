import Foundation
import KokokoCore
import KokokoLibrary
import KokokoMIDI
import VirtualEP

extension KokokoCoreChecks {
    private static func connect(_ vep: VirtualEPDevice) async throws -> DeviceFileService? {
        try vep.start()
        try await Task.sleep(for: .milliseconds(300))
        guard let pair = enumerateMIDIPairs().first(where: { $0.name == vep.name }) else { return nil }
        let wire = try CoreMIDIWire(pair: pair)
        let identity = try await identifyDevice(on: wire)
        let files = DeviceFileService(session: SysExSession(wire: wire, identityCode: identity.deviceID))
        try await files.initialize()
        return files
    }

    static func projectSettingsChecks() async {
        let source = VirtualEPDevice(name: "kokoko-vep-settings-source-\(getpid())")
        let target = VirtualEPDevice(name: "kokoko-vep-settings-target-\(getpid())")
        do {
            guard let from = try await connect(source), let to = try await connect(target) else {
                check(false, "project settings: devices enumerated")
                return
            }
            func dir(_ files: DeviceFileService, _ parent: UInt16, _ name: String) async throws -> UInt16 {
                try await files.put(parentID: parent, name: name, data: [], isDirectory: true)
            }

            // Source: /projects/{01,02,03}, /projects/01/groups/{A,B}.
            let srcRoot = try await DeviceLibrary(files: from).resolve("/projects")
            let src01 = try await dir(from, srcRoot, "01")
            let src02 = try await dir(from, srcRoot, "02")
            let src03 = try await dir(from, srcRoot, "03")
            let srcGroups = try await dir(from, src01, "groups")
            _ = try await dir(from, srcGroups, "A")
            let srcB = try await dir(from, srcGroups, "B")
            let src02x = try await dir(from, src02, "x")
            try await from.setMetadata(fileID: srcRoot, ["active": .int(Int(src02))])
            try await from.setMetadata(fileID: srcGroups, ["active": .int(Int(srcB))])
            try await from.setMetadata(fileID: src01, ["bpm": .int(120)])
            try await from.setMetadata(fileID: src02, ["active": .int(Int(src02x))])
            try await from.setMetadata(fileID: src03, ["bpm": .int(90), "active": .int(3000)])
            let backup = try await DeviceLibrary(files: from).backup(deviceSKU: "", osVersion: "", scope: .projects)
            eq(backup.projectMetadata["/projects/01/groups"]?["active"], .string("/projects/01/groups/B"),
               "project settings: an active selection is backed up as the path of its target")
            eq(backup.projectMetadata["/projects/03"], ["bpm": .int(90)],
               "project settings: an active selection that names no node in the tree is not backed up")

            // Target: the same names created in another order, so every id differs;
            // no 03 and no 02/x.
            let dstRoot = try await DeviceLibrary(files: to).resolve("/projects")
            _ = try await dir(to, dstRoot, "spacer 1")
            _ = try await dir(to, dstRoot, "spacer 2")
            let dst02 = try await dir(to, dstRoot, "02")
            let dst01 = try await dir(to, dstRoot, "01")
            let dstGroups = try await dir(to, dst01, "groups")
            _ = try await dir(to, dstGroups, "A")
            let dstB = try await dir(to, dstGroups, "B")
            check(dst02 != src02 && dstB != srcB && dst01 != src01, "project settings: target ids differ from the source")

            var noArchives = backup
            noArchives.projectArchives = [:]
            let report = try await DeviceLibrary(files: to).restore(noArchives)
            eq(try await to.getMetadata(fileID: dstRoot)["active"], .int(Int(dst02)),
               "project settings: the active project points at the target's node for its path")
            eq(try await to.getMetadata(fileID: dstGroups)["active"], .int(Int(dstB)),
               "project settings: the active group points at the target's node for its path")
            eq(try await to.getMetadata(fileID: dst01)["bpm"], .int(120),
               "project settings: settings land on the node at the same path, without archives")
            eq(try await to.getMetadata(fileID: dst02)["active"], nil,
               "project settings: an active value whose target path is missing is not written")
            eq(report.unappliedSettings, ["/projects/02 active", "/projects/03"],
               "project settings: a missing path and a missing active target are reported")
            eq(report.skippedProjects, [], "project settings: no archive was skipped")

            target.refuseMetadataSet = true
            let refused = try await DeviceLibrary(files: to).restore(DeviceBackup(
                deviceSKU: "", osVersion: "", createdAt: Date(), sounds: [],
                projectMetadata: ["/projects/01": ["bpm": .int(1)]]))
            target.refuseMetadataSet = false
            eq(refused.unappliedSettings, ["/projects/01"], "project settings: a refused write is reported")
            eq(try await to.getMetadata(fileID: dst01)["bpm"], .int(120), "project settings: a refused write changes nothing")

            let skippedProject = try await DeviceLibrary(files: to).restore(DeviceBackup(
                deviceSKU: "", osVersion: "", createdAt: Date(), sounds: [],
                projectMetadata: ["/projects/07": ["bpm": .int(1)], "/projects/07/groups": ["active": .string("/projects/07/groups/A")],
                                  "/projects/08": ["bpm": .int(1)]],
                projectArchives: ["07": [1]]))
            eq(skippedProject.skippedProjects, ["07"], "project settings: an archive without a slot is skipped")
            eq(skippedProject.unappliedSettings, ["/projects/08"],
               "project settings: settings under a skipped project are not listed again")

            // An older backup keyed settings by node id: none of them is applied.
            let legacyDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("kokoko-legacy-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: legacyDir) }
            try FileManager.default.createDirectory(at: legacyDir.appendingPathComponent("sounds"),
                                                    withIntermediateDirectories: true)
            let legacyManifest = #"{"deviceSKU":"","osVersion":"","projectMetadata":{"7":{"active":9},"9":{"bpm":100}}}"#
            try Data(legacyManifest.utf8).write(to: legacyDir.appendingPathComponent("manifest.json"))
            let legacy = try BackupStore.read(from: legacyDir)
            eq(legacy.legacyProjectSettings, 2, "project settings: id-keyed settings of an older backup are counted")
            eq(legacy.projectMetadata.count, 0, "project settings: id-keyed settings of an older backup are not loaded")
            let before = try await to.getMetadata(fileID: dst01)
            let legacyReport = try await DeviceLibrary(files: to).restore(legacy)
            eq(legacyReport.legacySettings, 2, "project settings: a restore reports the older backup's settings")
            eq(try await to.getMetadata(fileID: dst01), before, "project settings: an older backup changes no project node")

            eq(RestoreReport(skippedProjects: ["07"], unappliedSettings: ["/projects/03"], legacySettings: 2).message,
               "P07 skipped: no such project slot on the device; settings not applied: /projects/03; "
                   + "2 project settings from an older backup not applied",
               "project settings: the report names every part")
            eq(RestoreReport().message, nil, "project settings: an empty report has no message")
        } catch {
            check(false, "project settings checks threw \(error)")
        }
    }
}
