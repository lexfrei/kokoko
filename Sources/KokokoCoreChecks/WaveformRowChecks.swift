import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func waveformStoreChecks() async {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kokoko-store-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WaveformCacheStore(root: root)
        let session = await store.configure(model: "EP", serial: "one")
        let record = WaveformPeakRecord(pcm: [0, 0, 0, 128], channels: 1, sampleRate: 46875)!
        let token = await store.token(session: session)!
        let cancelled = WaveformCacheLease()
        cancelled.cancel()
        let refused = await store.store(record, slot: 1, token: token, lease: cancelled)
        check(!refused, "waveform store: a cancelled request cannot store")
        let empty = await store.load(session: session, slot: 1, size: 4)
        eq(empty, nil, "waveform store: a cancelled request leaves no record")
        let accepted = await store.store(record, slot: 1, token: token, lease: WaveformCacheLease())
        check(accepted, "waveform store: current request can store")
        let loaded = await store.load(session: session, slot: 1, size: 4)
        eq(loaded, record, "waveform store: serialized load sees the write")
        await store.invalidate(slots: [1], session: session)
        let stale = await store.store(record, slot: 1, token: token, lease: WaveformCacheLease())
        check(!stale, "waveform store: content epoch rejects a late write")
        let refreshed = await store.token(session: session)!
        _ = await store.configure(model: "EP", serial: "two")
        let wrongDevice = await store.store(record, slot: 2, token: refreshed, lease: WaveformCacheLease())
        check(!wrongDevice, "waveform store: session change rejects a late write")
        let wrongRead = await store.load(session: session, slot: 1, size: 4)
        eq(wrongRead, nil, "waveform store: old session cannot read another namespace")
    }

    static func waveformRowChecks() {
        let record = WaveformPeakRecord(pcm: [0, 0, 0, 128], channels: 1, sampleRate: 46875)!
        var rows = WaveformRows()
        check(rows.needsLookup(slot: 1, size: 4), "waveform rows: new row needs a local lookup")
        rows.remember(slot: 1, size: 4, record: nil)
        check(!rows.needsLookup(slot: 1, size: 4), "waveform rows: misses are deduplicated")
        eq(rows.snapshot(slot: 1, size: 4), nil, "waveform rows: a miss remains a stable placeholder")
        rows.remember(slot: 1, size: 4, record: record)
        eq(rows.snapshot(slot: 1, size: 4)?.record, record, "waveform rows: cached peaks are available without PCM")
        eq(rows.snapshot(slot: 1, size: 4)?.description, "cached audio, unverified", "waveform rows: cache hit does not assert freshness")
        check(rows.needsLookup(slot: 1, size: 8), "waveform rows: changed size requires another lookup")
        eq(rows.snapshot(slot: 1, size: 8), nil, "waveform rows: wrong-size peaks are not drawn")
        rows.remember(slot: 1, size: 8, record: record)
        eq(rows.snapshot(slot: 1, size: 8), nil, "waveform rows: a wrong-size record is rejected")
        rows.remember(slot: 1, size: 4, record: record, cached: false)
        eq(rows.snapshot(slot: 1, size: 4)?.description, "audio read from device", "waveform rows: explicit read provenance is distinct")
        rows.remember(slot: 2, size: 4, record: record)
        let epoch = rows.epoch
        rows.invalidate(slots: [1])
        check(rows.epoch != epoch && rows.needsLookup(slot: 1, size: 4), "waveform rows: invalidation renews local lookup intent")
        check(!rows.needsLookup(slot: 2, size: 4), "waveform rows: unrelated snapshots survive content invalidation")
        for slot in UInt16(3)...100 { rows.remember(slot: slot, size: 4, record: record) }
        check(rows.needsLookup(slot: 2, size: 4), "waveform rows: peak snapshots are bounded")
        check(!rows.needsLookup(slot: 100, size: 4), "waveform rows: recent snapshot survives eviction")
        for slot in UInt16(101)...200 { rows.remember(slot: slot, size: 4, record: nil) }
        check(rows.needsLookup(slot: 100, size: 4), "waveform rows: remembered misses share the same bound")
        check(!rows.needsLookup(slot: 200, size: 4), "waveform rows: recent miss remains deduplicated")
        rows.invalidate(slots: nil)
        check(rows.needsLookup(slot: 200, size: 4), "waveform rows: reset forgets the previous device's rows")
        let pending = rows.beginLookup(slot: 1, size: 4)!
        check(rows.beginLookup(slot: 1, size: 4) == nil, "waveform rows: in-flight disk lookup is deduplicated")
        rows.remember(slot: 1, size: 4, record: record, cached: false)
        check(!rows.finishLookup(pending, record: record), "waveform rows: late disk hit cannot replace an explicit read")
        eq(rows.snapshot(slot: 1, size: 4)?.cached, false, "waveform rows: explicit read provenance survives late local result")
        let invalidated = rows.beginLookup(slot: 2, size: 4)!
        rows.invalidate(slots: [99])
        check(!rows.isCurrent(invalidated), "waveform rows: content epoch rejects old local work")
        check(rows.needsLookup(slot: 2, size: 4), "waveform rows: invalidation releases obsolete pending lookups")
        let completed = rows.beginLookup(slot: 2, size: 4)!
        check(rows.finishLookup(completed, record: record), "waveform rows: current local lookup publishes peaks")
        check(!rows.finishLookup(completed, record: nil), "waveform rows: duplicate completion cannot erase peaks")
        let unmounted = rows.beginLookup(slot: 3, size: 4)!
        rows.forget(slot: 3, size: 4, epoch: rows.epoch)
        check(!rows.finishLookup(unmounted, record: record), "waveform rows: unmounted lifecycle rejects late local completion")
        let obsoleteEpoch = rows.epoch
        rows.invalidate(slots: nil)
        let replacement = rows.beginLookup(slot: 3, size: 4)!
        rows.forget(slot: 3, size: 4, epoch: obsoleteEpoch)
        check(rows.isCurrent(replacement), "waveform rows: old lifecycle cannot release a new incarnation")
        rows.cancelLookup(replacement)
        check(rows.needsLookup(slot: 3, size: 4), "waveform rows: skipped work releases its pending entry")
        eq(WaveformMiniature.width(compact: false), 96, "waveform miniature: regular footprint is fixed")
        eq(WaveformMiniature.width(compact: true), 32, "waveform miniature: compact fallback footprint is fixed")
        eq(WaveformMiniature.placeholder, "[~]", "waveform miniature: misses remain explicit open controls")
        let drawing = Waveform(record: record, columns: WaveformMiniature.columns, loopStart: nil, loopEnd: nil)
        eq(drawing.peaks.count, WaveformMiniature.columns, "waveform miniature: bounded peak-only drawing")
        var keyboard = SoundKeyboard()
        keyboard.connected = true
        keyboard.selection = [1]
        keyboard.visible = [1]
        for focus in [SoundFocus.waveformPlay(1), .waveformRefresh(1), .waveformClose(1)] {
            keyboard.focus = focus
            eq(keyboard.target(phase: .down, modified: false), nil, "waveform controls: Space does not trigger list preview")
        }
        keyboard.focus = .soundList
        eq(keyboard.target(phase: .down, modified: false), 1, "waveform expansion: list Space remains available")
    }
}
