import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func backupArchiveChecks() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("kokoko-archives-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        do {
            let projects = dir.appendingPathComponent("projects")
            try fm.createDirectory(at: dir.appendingPathComponent("sounds"), withIntermediateDirectories: true)
            try fm.createDirectory(at: projects, withIntermediateDirectories: true)
            let manifest = #"{"deviceSKU":"","osVersion":"","projectArchives":["01","02","03"]}"#
            try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json"))
            try Data([1, 2]).write(to: projects.appendingPathComponent("P01.tar"))
            // P02 is listed but missing; P03 and the unlisted P04 are present but cannot be read.
            try fm.createDirectory(at: projects.appendingPathComponent("P03.tar"), withIntermediateDirectories: true)
            try fm.createDirectory(at: projects.appendingPathComponent("P04.tar"), withIntermediateDirectories: true)
            let backup = try BackupStore.read(from: dir)
            eq(backup.projectArchives.keys.sorted(), ["01"], "backup archives: only the readable archive is loaded")
            eq(backup.unreadArchives, ["02", "03", "04"], "backup archives: a missing or unreadable archive is reported, not dropped")
            check(RestoreSummary(backup).message.hasSuffix("P02, P03 and P04 cannot be read from the backup; neither their archives nor their settings are restored."),
                  "backup archives: the confirmation built from a read backup names its unread archives")

            for stray in ["._P01.tar", "X01.tar", "X05.tar", "P0x.tar", "P.tar", "notes.tar", "P\u{0661}\u{0662}.tar"] {
                try Data([9]).write(to: projects.appendingPathComponent(stray))
            }
            let withStrays = try BackupStore.read(from: dir)
            eq(withStrays.projectArchives.keys.sorted(), ["01"],
               "backup archives: only P<digits>.tar files are read as project archives")
            eq(withStrays.unreadArchives, ["02", "03", "04"], "backup archives: stray files are not reported as unread")

            let soundsOnly = dir.appendingPathComponent("sounds-only")
            try fm.createDirectory(at: soundsOnly.appendingPathComponent("sounds"), withIntermediateDirectories: true)
            try Data(#"{"deviceSKU":"","osVersion":""}"#.utf8).write(to: soundsOnly.appendingPathComponent("manifest.json"))
            eq(try BackupStore.read(from: soundsOnly).unreadArchives, [],
               "backup archives: a backup without archives reports none unread")
        } catch {
            check(false, "backup archive checks threw \(error)")
        }
        var onlyUnreadSettings = DeviceBackup(deviceSKU: "", osVersion: "", createdAt: Date(), sounds: [],
                                              projectMetadata: ["/projects/02": ["bpm": .int(120)]])
        onlyUnreadSettings.unreadArchives = ["02"]
        check(!RestoreSummary(onlyUnreadSettings).message.contains("Project settings from the backup are applied"),
              "backup archives: settings that belong only to unread archives are not promised")
        var mixed = DeviceBackup(deviceSKU: "", osVersion: "", createdAt: Date(), sounds: [],
                                 projectMetadata: ["/projects/010": ["bpm": .int(1)], "/projects/02": ["bpm": .int(2)]])
        mixed.unreadArchives = ["01", "02"]
        check(RestoreSummary(mixed).message.contains("Project settings from the backup are applied"),
              "backup archives: settings of a readable project are still promised next to an unread one")
        eq(RestoreReport(unreadArchives: ["02", "03"]).message,
           "P02, P03 not restored: archive missing or unreadable in the backup",
           "backup archives: the restore report names the unread archives")
        eq(RestoreSummary(soundCount: 0, projects: ["01"], hasProjectSettings: false, unreadArchives: ["02"]).message,
           "P01 is replaced with the backup's archive where that slot exists on the device. "
               + "P02 cannot be read from the backup; neither its archive nor its settings are restored.",
           "backup archives: the confirmation names an archive it cannot read")
    }
}
