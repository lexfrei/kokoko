import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func progressChecks() {
        var line = ProgressLine()
        let kick = line.begin("send kick")
        line.update(kick, "send kick 50%")
        eq(line.text, "send kick 50%", "progress: a report from the running operation shows")

        line.end(kick)
        line.update(kick, "send kick 100%")
        eq(line.text, nil, "progress: a report arriving after the operation ended is dropped")

        let snare = line.begin("send snare")
        line.update(kick, "send kick 100%")
        eq(line.text, "send snare", "progress: a late report from an earlier operation is dropped")

        // A long operation keeps reporting while a short one starts and ends.
        let backup = line.begin("backup...")
        let settings = line.begin("settings...")
        eq(line.text, "settings...", "progress: the newest live operation shows")
        line.end(settings)
        line.update(backup, "backup kick")
        eq(line.text, "backup kick", "progress: a short operation ending does not silence a long one")
        line.update(backup, nil)
        eq(line.text, "send snare", "progress: an operation with no text falls back to an older live one")
        line.end(backup)
        line.end(snare)
        eq(line.text, nil, "progress: no live operation shows nothing")
    }
}
