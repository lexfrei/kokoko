import Foundation
import KokokoCore
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
        let descriptor = WaveformDescriptor(size: 4, metadata: ["channels": .int(1), "samplerate": .int(46875)])!
        eq(await store.load(session: session, slot: 1, descriptor: nil), nil, "waveform store: absent confirmation hides the candidate")
        eq(await store.load(session: session, slot: 1, descriptor: descriptor), record, "waveform store: descriptor-matched peaks are usable")
        eq(await store.load(session: session, slot: 1, size: 4), record, "waveform store: missing metadata does not erase a reusable candidate")
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

    private static func waveformDescriptorChecks() {
        let metadata: [String: JSONValue] = ["channels": .int(1), "samplerate": .int(46875)]
        let record = WaveformPeakRecord(pcm: [0, 0, 0, 128], channels: 1, sampleRate: 46875)!
        let descriptor = WaveformDescriptor(size: 4, metadata: metadata)
        check(descriptor?.matches(record) == true, "waveform descriptor: current size and confirmed format accept peaks")
        check(WaveformDescriptor(size: 4, metadata: ["channels": .double(1), "samplerate": .double(46875)]) == descriptor,
              "waveform descriptor: exact JSON doubles remain valid numeric metadata")
        for key in ["channels", "samplerate"] {
            var missing = metadata
            missing[key] = nil
            eq(WaveformDescriptor(size: 4, metadata: missing), nil, "waveform descriptor: missing format cannot be guessed from cache")
            for invalid: JSONValue in [.null, .bool(true), .string("1"), .double(1.5), .int(0), .int(-1), .int(65536)] {
                var wrong = metadata
                wrong[key] = invalid
                eq(WaveformDescriptor(size: 4, metadata: wrong), nil, "waveform descriptor: invalid confirmed numeric format is rejected")
            }
        }
        for size in [-1, 3, Int(UInt32.max) + 1] {
            eq(WaveformDescriptor(size: size, metadata: metadata), nil, "waveform descriptor: invalid size cannot validate a preview")
        }
        check(WaveformDescriptor(size: 8, metadata: metadata)?.matches(record) == false, "waveform descriptor: wrong size hides old peaks")
        check(WaveformDescriptor(size: 4, metadata: ["channels": .int(2), "samplerate": .int(46875)])?.matches(record) == false,
              "waveform descriptor: same-size channel mismatch hides old peaks")
        check(WaveformDescriptor(size: 4, metadata: ["channels": .int(1), "samplerate": .int(44100)])?.matches(record) == false,
              "waveform descriptor: rate mismatch hides old peaks")
        var draft = MetadataEditForm(metadata: metadata.merging(["sound.loopstart": .int(0)], uniquingKeysWith: { _, new in new }))
        draft.text["sound.loopstart"] = " 999 "
        eq(draft.confirmedMetadata["sound.loopstart"], .int(0), "waveform overlay: raw metadata draft never becomes a confirmed loop point")
        draft.rebase(on: metadata.merging(["sound.loopstart": .int(2)], uniquingKeysWith: { _, new in new }))
        eq(draft.confirmedMetadata["sound.loopstart"], .int(2), "waveform overlay: only confirmed readback updates the baseline")
        eq(draft.text["sound.loopstart"], " 999 ", "waveform overlay: confirming metadata does not rewrite the user's draft")
    }

    static func waveformRowChecks() {
        waveformDescriptorChecks()
        let record = WaveformPeakRecord(pcm: [0, 0, 0, 128], channels: 1, sampleRate: 46875)!
        var pinned = WaveformRows()
        let visible = Set(UInt16(1)...80)
        pinned.setViewportPins(visible)
        for slot in UInt16(1)...80 { pinned.remember(slot: slot, size: 4, record: record) }
        check(visible.allSatisfy { pinned.snapshot(slot: $0, size: 4) != nil }, "waveform rows: actual viewport pins can retain more than 64 records")
        pinned.invalidate(slots: [1])
        pinned.remember(slot: 1, size: 4, record: record)
        check(visible.allSatisfy { pinned.snapshot(slot: $0, size: 4) != nil }, "waveform rows: entry invalidation does not withdraw a current viewport pin")
        for slot in UInt16(81)...96 { pinned.remember(slot: slot, size: 4, record: record) }
        check(visible.allSatisfy { pinned.snapshot(slot: $0, size: 4) != nil }, "waveform rows: unpinned work cannot evict viewport records")
        check((UInt16(81)...96).allSatisfy { pinned.needsLookup(slot: $0, size: 4) }, "waveform rows: pins expand capacity only to their own count")
        check(pinned.beginLookup(slot: 200, size: 4) == nil, "waveform rows: an unpinned lookup beyond the active bound is not admitted")
        pinned.setViewportPins([80])
        check((UInt16(1)...96).filter { pinned.snapshot(slot: $0, size: 4) != nil }.count == 64,
              "waveform rows: shrinking pins trims back to the legacy bound")
        check(pinned.snapshot(slot: 80, size: 4) != nil, "waveform rows: remaining viewport pin survives trimming")
        pinned.setViewportPins([])
        pinned.invalidate(slots: nil)
        for slot in UInt16(1)...80 { pinned.remember(slot: slot, size: 4, record: record) }
        check((UInt16(1)...80).filter { pinned.snapshot(slot: $0, size: 4) != nil }.count == 64,
              "waveform rows: reset removes old pins and restores strict legacy capacity")
        var reopened = WaveformRows()
        reopened.remember(slot: 1, size: 4, record: record)
        let beforeReopen = reopened.snapshot(slot: 1, size: 4)?.description
        reopened.forget(slot: 1, size: 4, epoch: reopened.epoch)
        let reopening = reopened.beginLookup(slot: 1, size: 4)!
        _ = reopened.finishLookup(reopening, record: record)
        eq(reopened.snapshot(slot: 1, size: 4)?.description, beforeReopen,
           "waveform rows: retaining the same sound through local reuse does not downgrade its presentation")
        eq(beforeReopen, "Waveform", "waveform rows: an accepted preview uses a neutral description")
        var rows = WaveformRows()
        check(rows.needsLookup(slot: 1, size: 4), "waveform rows: new row needs a local lookup")
        rows.remember(slot: 1, size: 4, record: nil)
        check(!rows.needsLookup(slot: 1, size: 4), "waveform rows: misses are deduplicated")
        eq(rows.snapshot(slot: 1, size: 4), nil, "waveform rows: a miss remains a stable placeholder")
        rows.remember(slot: 1, size: 4, record: record)
        eq(rows.snapshot(slot: 1, size: 4)?.record, record, "waveform rows: cached peaks are available without PCM")
        eq(rows.snapshot(slot: 1, size: 4)?.description, "Waveform", "waveform rows: accepted local peaks use a neutral description")
        check(rows.needsLookup(slot: 1, size: 8), "waveform rows: changed size requires another lookup")
        eq(rows.snapshot(slot: 1, size: 8), nil, "waveform rows: wrong-size peaks are not drawn")
        rows.remember(slot: 1, size: 8, record: record)
        eq(rows.snapshot(slot: 1, size: 8), nil, "waveform rows: a wrong-size record is rejected")
        rows.remember(slot: 1, size: 4, record: record)
        eq(rows.snapshot(slot: 1, size: 4)?.description, "Waveform", "waveform rows: a current device result uses the same neutral description")
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
        rows.remember(slot: 1, size: 4, record: record)
        check(!rows.finishLookup(pending, record: record), "waveform rows: late disk hit cannot replace an explicit read")
        eq(rows.snapshot(slot: 1, size: 4)?.record, record, "waveform rows: a late local result cannot replace accepted peaks")
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
        rows.remember(slot: 4, size: 4, record: record)
        rows.reconcileCache(slot: 4, size: 4, record: record)
        eq(rows.snapshot(slot: 4, size: 4)?.record, record, "waveform rows: unchanged validation preserves accepted peaks")
        rows.reconcileCache(slot: 4, size: 4, record: nil)
        eq(rows.snapshot(slot: 4, size: 4), nil, "waveform rows: rejected cache record removes an explicit-read miniature")
        let rejected = rows.beginLookup(slot: 4, size: 4)!
        rows.reconcileCache(slot: 4, size: 4, record: nil)
        check(!rows.finishLookup(rejected, record: record), "waveform rows: cache rejection prevents a late miniature resurrection")
        let stereo = WaveformPeakRecord(pcm: [0, 0, 0, 128], channels: 2, sampleRate: 46875)!
        rows.remember(slot: 4, size: 4, record: record)
        rows.reconcileCache(slot: 4, size: 4, record: stereo)
        eq(rows.snapshot(slot: 4, size: 4)?.record, stereo, "waveform rows: validated replacement updates the miniature")
        eq(rows.snapshot(slot: 4, size: 4)?.description, "Waveform", "waveform rows: an accepted replacement keeps the neutral presentation")
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
