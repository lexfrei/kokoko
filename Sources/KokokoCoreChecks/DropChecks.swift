import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func dropChecks() {
        let fm = FileManager.default
        let src = fm.temporaryDirectory.appendingPathComponent("kokoko-drop-src-\(UUID().uuidString)")
        try? fm.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: src) }

        let count = 64
        var sources: [URL] = []
        for index in 0..<count {
            // Same file name in different folders must not collide in staging.
            let dir = src.appendingPathComponent("\(index)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(index % 2 == 0 ? "kick.wav" : "snare \(index).wav")
            try? Data([UInt8(index)]).write(to: url)
            sources.append(url)
        }

        guard let staging = try? DropStaging(count: count + 1) else {
            check(false, "drop staging init")
            return
        }
        let srcList = sources
        DispatchQueue.concurrentPerform(iterations: count) { index in
            staging.stage(srcList[index], at: index)
        }
        staging.stage(src.appendingPathComponent("missing.wav"), at: count)

        // The provider deletes its in-place copy once the callback returns.
        try? fm.removeItem(at: src)

        let staged = staging.urls
        eq(staged.count, count, "drop keeps every concurrently staged file")
        check(staged.map(\.lastPathComponent) == srcList.map(\.lastPathComponent),
              "drop keeps drop order and file names")
        let bytes = staged.compactMap { try? Data(contentsOf: $0).first }
        check(bytes == (0..<count).map { UInt8($0) }, "drop copies survive source removal")
        eq(staging.failures.count, 1, "drop reports a file that could not be copied")
        let noSuchFile = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)).localizedFailureReason ?? ""
        eq(staging.failures.first, "missing.wav: \(noSuchFile)",
           "drop names the file it could not copy once, with the system reason")
        staging.fail(name: "hat.wav", reason: "unreadable item")
        eq(staging.failures.last, "hat.wav: unreadable item", "drop names an item the provider could not load")

        staging.discard()
        check(!fm.fileExists(atPath: staging.directory.path), "drop discard removes staging dir")

        eq(dropMarker(.soundList, targeted: true, deviceBusy: false), "> drop to add sounds <",
           "drop marker: the sound list says what a drop does")
        eq(dropMarker(.projectList, targeted: true, deviceBusy: false), "> drop to upload project archives <",
           "drop marker: the project list says what a drop does")
        eq(dropMarker(.soundRow, targeted: true, deviceBusy: false), "> drop here <", "drop marker: a sound row marks itself")
        eq(rowDropMarker(row: 4, targeted: 4, dragged: 3, deviceBusy: false), "> drop here <",
           "drop marker: a row marks itself while another row is dragged onto it")
        eq(rowDropMarker(row: 3, targeted: 3, dragged: 3, deviceBusy: false), nil,
           "drop marker: a row dragged over itself marks nothing, since that drop does nothing")
        eq(rowDropMarker(row: 4, targeted: 4, dragged: nil, deviceBusy: false), nil,
           "drop marker: text that is not a dragged row marks nothing")
        eq(rowDropMarker(row: 4, targeted: 5, dragged: 3, deviceBusy: false), nil,
           "drop marker: only the row under the drag marks itself")
        eq(rowDropMarker(row: 4, targeted: 4, dragged: 3, deviceBusy: true), nil,
           "drop marker: a row marks nothing while the device is busy")
        for target: DropTarget in [.soundList, .projectList, .soundRow] {
            eq(dropMarker(target, targeted: false, deviceBusy: false), nil, "drop marker: nothing shows with nothing dragged over (\(target))")
            eq(dropMarker(target, targeted: true, deviceBusy: true), nil,
               "drop marker: nothing shows while the device is busy, since the drop is refused (\(target))")
        }
    }
}
