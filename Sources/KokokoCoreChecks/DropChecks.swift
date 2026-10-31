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

        staging.discard()
        check(!fm.fileExists(atPath: staging.directory.path), "drop discard removes staging dir")
    }
}
