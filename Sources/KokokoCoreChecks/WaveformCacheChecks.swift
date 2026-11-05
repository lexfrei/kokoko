import CryptoKit
import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func waveformCacheChecks() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kokoko-peak-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pcm: [UInt8] = [0, 0, 0, 128, 0, 64, 0, 0]
        let peaks = WaveformPeakRecord(pcm: pcm, channels: 1, sampleRate: 46875)!
        eq(peaks.peaks, [0, 1, 0.5, 0], "peak cache: max-abs includes negative full scale")
        eq(peaks.frameCount, 4, "peak cache: frame count")
        check(WaveformPeakRecord(pcm: [0], channels: 1, sampleRate: 46875) == nil,
              "peak cache: rejects incomplete PCM frame")
        check(WaveformPeakRecord(pcm: pcm, channels: 3, sampleRate: 46875) == nil,
              "peak cache: rejects unsupported channels")
        let large = WaveformPeakRecord(pcm: [UInt8](repeating: 0, count: 4096), channels: 1, sampleRate: 46875)!
        eq(large.peaks.count, 512, "peak cache: at most 512 peaks")
        let drawing = Waveform(record: peaks, columns: 2, loopStart: 1, loopEnd: 2)
        eq(drawing.peaks, [1, 0.5], "peak drawing: reduces stored peaks without PCM")
        eq(drawing.frameCount, 4, "peak drawing: retains original frame count")
        eq(drawing.loopColumns, 0...1, "peak drawing: loop overlays use current metadata")
        var cache = WaveformCache(root: root, model: "EP/133", serial: "private-serial")
        cache.store(peaks, slot: 1)
        eq(cache.load(slot: 1, size: 8), peaks, "peak cache: session hit")
        var reopened = WaveformCache(root: root, model: "EP/133", serial: "private-serial")
        eq(reopened.load(slot: 1, size: 8), peaks, "peak cache: persistent hit")
        eq(reopened.load(slot: 1, size: 10), nil, "peak cache: exact size mismatch misses")
        cache.store(peaks, slot: 1)
        var other = WaveformCache(root: root, model: "EP/1320", serial: "private-serial")
        eq(other.load(slot: 1, size: 8), nil, "peak cache: model namespaces are separate")
        other = WaveformCache(root: root, model: "EP/133", serial: "another-serial")
        eq(other.load(slot: 1, size: 8), nil, "peak cache: serial namespaces are separate")
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        check(files.allSatisfy { !$0.contains("private-serial") && !$0.contains("EP") },
              "peak cache: paths contain neither serial nor model")
        var anonymous = WaveformCache(root: root, model: "EP/133", serial: "")
        anonymous.store(peaks, slot: 2)
        eq(anonymous.load(slot: 2, size: 8), peaks, "peak cache: unidentified device has session cache")
        anonymous = WaveformCache(root: root, model: "EP/133", serial: "")
        eq(anonymous.load(slot: 2, size: 8), nil, "peak cache: unidentified device never persists")
        var formatCheck = WaveformCache(root: root, model: "EP/133", serial: "private-serial")
        eq(formatCheck.load(slot: 1, size: 8, channels: 2), nil, "peak cache: channel change invalidates")
        cache.store(peaks, slot: 1)
        formatCheck = WaveformCache(root: root, model: "EP/133", serial: "private-serial")
        eq(formatCheck.load(slot: 1, size: 8, sampleRate: 44100), nil, "peak cache: sample rate change invalidates")
        cache.invalidate(slots: [1])
        reopened = WaveformCache(root: root, model: "EP/133", serial: "private-serial")
        eq(reopened.load(slot: 1, size: 8), nil, "peak cache: content invalidation survives reopening")

        cache.store(peaks, slot: 1)
        let namespace = root.appendingPathComponent(try FileManager.default.contentsOfDirectory(atPath: root.path).first!)
        let owned = try FileManager.default.contentsOfDirectory(at: namespace, includingPropertiesForKeys: nil).first!
        try Data("unknown data".utf8).write(to: owned)
        reopened = WaveformCache(root: root, model: "EP/133", serial: "private-serial")
        eq(reopened.load(slot: 1, size: 8), nil, "peak cache: corruption misses")
        reopened.invalidate(slots: nil)
        eq(try Data(contentsOf: owned), Data("unknown data".utf8), "peak cache: invalid files are never deleted")
        reopened.store(peaks, slot: 1)
        eq(try Data(contentsOf: owned), Data("unknown data".utf8), "peak cache: unknown target is never overwritten")

        let linkedRoot = root.appendingPathComponent("linked")
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: external)
        var linked = WaveformCache(root: linkedRoot, model: "EP/133", serial: "private-serial")
        linked.store(peaks, slot: 3)
        check(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty,
              "peak cache: symlink root does not receive writes")

        let budgetRoot = root.appendingPathComponent("budget")
        var bounded = WaveformCache(root: budgetRoot, model: "EP", serial: "serial", maximumBytes: 1200)
        for slot in UInt16(1)...12 { bounded.store(peaks, slot: slot) }
        var cold = WaveformCache(root: budgetRoot, model: "EP", serial: "serial", maximumBytes: 1200)
        eq(cold.load(slot: 1, size: 8), nil, "peak cache: least recently used entry evicted")
        eq(cold.load(slot: 12, size: 8), peaks, "peak cache: latest entry survives eviction")
        let budgetFiles = try FileManager.default.subpathsOfDirectory(atPath: budgetRoot.path)
        let bytes = try budgetFiles.filter { $0.hasSuffix(".wfp") }.reduce(0) {
            $0 + (try Data(contentsOf: budgetRoot.appendingPathComponent($1))).count
        }
        check(bytes <= 1200, "peak cache: owned disk bytes stay within budget")

        let sharedRoot = root.appendingPathComponent("shared-budget")
        var firstDevice = WaveformCache(root: sharedRoot, model: "EP", serial: "one", maximumBytes: 1200)
        firstDevice.store(peaks, slot: 1)
        var secondDevice = WaveformCache(root: sharedRoot, model: "EP", serial: "two", maximumBytes: 1200)
        let unknown = sharedRoot.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unknown)
        let target = root.appendingPathComponent("symlink-target")
        try Data("target".utf8).write(to: target)
        let link = sharedRoot.appendingPathComponent(String(repeating: "a", count: 64))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let firstPath = try FileManager.default.subpathsOfDirectory(atPath: sharedRoot.path).first { $0.hasSuffix(".wfp") }!
        let firstDirectory = sharedRoot.appendingPathComponent(firstPath).deletingLastPathComponent()
        let fileLink = firstDirectory.appendingPathComponent(String(repeating: "b", count: 64) + ".wfp")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: target)
        for slot in UInt16(2)...12 { secondDevice.store(peaks, slot: slot) }
        eq(try Data(contentsOf: unknown), Data("keep".utf8), "peak cache: global eviction preserves unknown files")
        eq(try Data(contentsOf: target), Data("target".utf8), "peak cache: global eviction preserves symlink targets")
        check((try? FileManager.default.destinationOfSymbolicLink(atPath: fileLink.path)) != nil,
              "peak cache: global eviction does not delete unowned symlinks")
        let sharedPaths = try FileManager.default.subpathsOfDirectory(atPath: sharedRoot.path)
        let sharedBytes = try sharedPaths.filter { $0.hasSuffix(".wfp") && !$0.hasSuffix(String(repeating: "b", count: 64) + ".wfp") }.reduce(0) {
            $0 + (try Data(contentsOf: sharedRoot.appendingPathComponent($1))).count
        }
        check(sharedBytes <= 1200, "peak cache: disk budget is shared by device namespaces")

        let touchRoot = root.appendingPathComponent("touch-budget")
        var initial = WaveformCache(root: touchRoot, model: "EP", serial: "one")
        initial.store(peaks, slot: 1)
        let touchPath = try FileManager.default.subpathsOfDirectory(atPath: touchRoot.path).first { $0.hasSuffix(".wfp") }!
        let entryBytes = try Data(contentsOf: touchRoot.appendingPathComponent(touchPath)).count
        var touched = WaveformCache(root: touchRoot, model: "EP", serial: "one", maximumBytes: entryBytes * 2)
        touched.store(peaks, slot: 2)
        let touchPaths = try FileManager.default.subpathsOfDirectory(atPath: touchRoot.path).filter { $0.hasSuffix(".wfp") }
        for path in touchPaths {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)],
                                                  ofItemAtPath: touchRoot.appendingPathComponent(path).path)
        }
        _ = touched.load(slot: 1, size: 8)
        touched.store(peaks, slot: 3)
        var afterTouch = WaveformCache(root: touchRoot, model: "EP", serial: "one")
        eq(afterTouch.load(slot: 1, size: 8), peaks, "peak cache: hit updates disk LRU")
        eq(afterTouch.load(slot: 2, size: 8), nil, "peak cache: older untouched entry evicted")
        var isolated = WaveformCache(root: sharedRoot, model: "EP", serial: "one")
        isolated.invalidate(slots: nil)
        var remaining = WaveformCache(root: sharedRoot, model: "EP", serial: "two")
        eq(remaining.load(slot: 12, size: 8), peaks, "peak cache: invalidation stays in the selected namespace")

        let integrityRoot = root.appendingPathComponent("integrity")
        var integrity = WaveformCache(root: integrityRoot, model: "EP", serial: "serial")
        integrity.store(peaks, slot: 1)
        let integrityPath = try FileManager.default.subpathsOfDirectory(atPath: integrityRoot.path).first { $0.hasSuffix(".wfp") }!
        let integrityURL = integrityRoot.appendingPathComponent(integrityPath)
        let original = try Data(contentsOf: integrityURL)
        func tamper(_ change: (inout [String: Any]) -> Void, checksum: Bool = true) throws {
            var envelope = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            var payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!) as! [String: Any]
            change(&payload)
            let bytes = try JSONSerialization.data(withJSONObject: payload)
            envelope["payload"] = bytes.base64EncodedString()
            if checksum { envelope["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
            try JSONSerialization.data(withJSONObject: envelope).write(to: integrityURL)
            var cold = WaveformCache(root: integrityRoot, model: "EP", serial: "serial")
            eq(cold.load(slot: 1, size: 8), nil, "peak cache: rejects altered record")
        }
        try tamper({ $0["schema"] = 2 })
        try tamper({ $0["algorithm"] = 2 })
        try tamper({ $0["namespace"] = "another-device" })
        try tamper({ $0["slot"] = 2 })
        for (key, value) in [("frameCount", -1 as Any), ("size", 9 as Any), ("channels", 0 as Any),
                             ("sampleRate", 0 as Any), ("encoding", "float32" as Any),
                             ("peaks", [0, 0, 0, 1.1] as Any), ("peaks", [0] as Any)] {
            try tamper({ payload in
                var record = payload["record"] as! [String: Any]
                record[key] = value
                payload["record"] = record
            })
        }
        try tamper({ payload in
            var record = payload["record"] as! [String: Any]
            record["sampleRate"] = 44100
            payload["record"] = record
        }, checksum: false)
        try Data(repeating: 0, count: 32769).write(to: integrityURL)
        var oversized = WaveformCache(root: integrityRoot, model: "EP", serial: "serial")
        eq(oversized.load(slot: 1, size: 8), nil, "peak cache: oversized disk record misses")
        oversized.invalidate(slots: nil)
        eq(try Data(contentsOf: integrityURL).count, 32769, "peak cache: invalid oversized file preserved")

        var intent = WaveformIntent()
        let first = intent.begin(slot: 1, generation: 7)
        check(intent.isCurrent(first, generation: 7), "peak intent: current request accepted")
        check(!intent.isCurrent(first, generation: 8), "peak intent: different generation rejected")
        _ = intent.begin(slot: 2, generation: 7)
        check(!intent.isCurrent(first, generation: 7), "peak intent: superseded request rejected")
        let second = intent.begin(slot: 2, generation: 7)
        intent.invalidate()
        check(!intent.isCurrent(second, generation: 7), "peak intent: content mutation rejects publish and store")
    }
}
