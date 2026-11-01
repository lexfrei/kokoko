import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    /// A real archive from the system tar tool, so the checksum is checked
    /// against what tar writes rather than a hand-built header.
    static func systemTar() -> [UInt8]? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("kokoko-tar-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("pattern".utf8).write(to: dir.appendingPathComponent("song.json"))
            let out = dir.appendingPathComponent("P01.tar")
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["--create", "--format", "ustar", "--file", out.path, "--directory", dir.path, "song.json"]
            try tar.run()
            tar.waitUntilExit()
            return tar.terminationStatus == 0 ? Array(try Data(contentsOf: out)) : nil
        } catch {
            return nil
        }
    }

    /// One header and one data block laid out as the device writes them: name,
    /// size as unpadded octal, no "ustar" magic, then the given checksum text.
    static func deviceStyleArchive(checksumField: (Int) -> String) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int) {
            for (i, byte) in text.utf8.enumerated() { header[offset + i] = byte }
        }
        put("pads/a/p01", at: 0)
        put("0000644\0", at: 100)
        put("33\0", at: 124)
        put("0\0", at: 136)
        put("0", at: 156)
        let sum = header.enumerated().reduce(0) { $0 + Int((148..<156).contains($1.offset) ? 0x20 : $1.element) }
        put(String(checksumField(sum).prefix(8)), at: 148)
        return header + [UInt8](repeating: 1, count: 27) + [UInt8](repeating: 0, count: 485)
            + [UInt8](repeating: 0, count: 1024)
    }

    static func projectArchiveValidationChecks() {
        guard let tar = systemTar() else {
            check(false, "archive: the system tar tool made an archive")
            return
        }
        check(isValidProjectArchive(tar), "archive: a tar written by the system tar tool is valid")
        check(!isValidProjectArchive([]), "archive: an empty file is not an archive")
        check(!isValidProjectArchive([1, 2]), "archive: a file shorter than a block is not an archive")
        check(!isValidProjectArchive(tar + [0]), "archive: a size that is not whole 512-byte blocks is refused")
        check(isValidProjectArchive([UInt8](repeating: 0, count: 1024)),
              "archive: an empty archive, just the two zero end blocks, is valid")
        check(!isValidProjectArchive([UInt8](repeating: 0, count: 512)), "archive: a single zero block is not a whole archive")
        check(isValidProjectArchive(deviceStyleArchive(checksumField: { "\(String($0, radix: 8))\0   " })),
              "archive: a device-style header (no ustar magic, unpadded checksum) is valid")
        check(isValidProjectArchive(deviceStyleArchive(checksumField: { "  " + String($0, radix: 8) + "\0" })),
              "archive: a checksum with leading spaces, as older tar tools write it, is valid")
        check(!isValidProjectArchive(deviceStyleArchive(checksumField: { "\(String($0 + 1, radix: 8))\0   " })),
              "archive: a device-style header with a wrong checksum is refused")
        var damaged = tar
        damaged[10] ^= 0xFF
        check(!isValidProjectArchive(damaged), "archive: a header byte that changed fails the checksum")
        var otherData = tar
        otherData[600] ^= 0xFF
        check(isValidProjectArchive(otherData), "archive: only the first header is checked, not the contents")
    }

    static func archiveNameChecks() {
        let backupNames: [(String, String?)] = [
            ("P01.tar", "01"), ("P123.tar", "123"), ("P1.tar", "1"),
            ("x-P01.tar", nil), ("._P01.tar", nil), ("X01.tar", nil), ("P0x.tar", nil), ("P.tar", nil),
            ("P\u{0661}\u{0662}.tar", nil), ("P01.TAR", nil), ("p01.tar", nil),
        ]
        for (name, slot) in backupNames {
            eq(projectSlot(backupArchiveName: name), slot, "archive name: backup file \(name)")
        }
        let droppedNames: [(String, String?)] = [
            ("P01.tar", "01"), ("my song P07.tar", "07"), ("backup-P09.tar", "09"),
            ("._P01.tar", nil), ("._backup-P01.tar", nil), ("P1.tar", nil), ("P123.tar", nil),
            ("P\u{0661}\u{0662}.tar", nil), ("P01.tar.zip", nil), ("notes.tar", nil),
        ]
        for (name, slot) in droppedNames {
            eq(projectSlot(droppedArchiveName: name), slot, "archive name: dropped file \(name)")
        }
    }

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
            guard let tar = systemTar() else {
                check(false, "backup archives: the system tar tool made an archive")
                return
            }
            try Data(tar).write(to: projects.appendingPathComponent("P01.tar"))
            try Data([1, 2]).write(to: projects.appendingPathComponent("P05.tar"))
            // P02 is listed but missing; P03 and the unlisted P04 are present but cannot be
            // read; P05 reads but is not an archive.
            try fm.createDirectory(at: projects.appendingPathComponent("P03.tar"), withIntermediateDirectories: true)
            try fm.createDirectory(at: projects.appendingPathComponent("P04.tar"), withIntermediateDirectories: true)
            let backup = try BackupStore.read(from: dir)
            eq(backup.projectArchives.keys.sorted(), ["01"], "backup archives: only the readable archive is loaded")
            eq(backup.unreadArchives, ["02", "03", "04", "05"],
               "backup archives: a missing, unreadable or damaged archive is reported, not dropped")
            check(RestoreSummary(backup).message.hasSuffix("P02, P03, P04 and P05 are missing or damaged in the backup; neither their archives nor their settings are restored."),
                  "backup archives: the confirmation built from a read backup names its unread archives")

            for stray in ["._P01.tar", "X01.tar", "X05.tar", "P0x.tar", "P.tar", "notes.tar", "P\u{0661}\u{0662}.tar"] {
                try Data([9]).write(to: projects.appendingPathComponent(stray))
            }
            let withStrays = try BackupStore.read(from: dir)
            eq(withStrays.projectArchives.keys.sorted(), ["01"],
               "backup archives: only P<digits>.tar files are read as project archives")
            eq(withStrays.unreadArchives, ["02", "03", "04", "05"], "backup archives: stray files are not reported as unread")

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
           "P02, P03 not restored: archive missing or damaged in the backup",
           "backup archives: the restore report names the unread archives")
        eq(RestoreSummary(soundCount: 0, projects: ["01"], hasProjectSettings: false, unreadArchives: ["02"]).message,
           "P01 is replaced with the backup's archive where that slot exists on the device. "
               + "P02 is missing or damaged in the backup; neither its archive nor its settings are restored.",
           "backup archives: the confirmation names an archive it cannot read")
    }
}
