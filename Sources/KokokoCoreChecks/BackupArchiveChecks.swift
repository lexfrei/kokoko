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
            try Data(#"{"deviceSKU":"","osVersion":""}"#.utf8).write(to: dir.appendingPathComponent("manifest.json"))
            try Data([1, 2]).write(to: projects.appendingPathComponent("P01.tar"))
            // Files the app never writes: system metadata copies and other names.
            for stray in ["._P01.tar", "X01.tar", "X05.tar", "P0x.tar", "P.tar", "notes.tar", "P\u{0661}\u{0662}.tar"] {
                try Data([9]).write(to: projects.appendingPathComponent(stray))
            }
            eq(try BackupStore.read(from: dir).projectArchives.keys.sorted(), ["01"],
               "backup archives: only P<digits>.tar files are read as project archives")
        } catch {
            check(false, "backup archive checks threw \(error)")
        }
    }
}
