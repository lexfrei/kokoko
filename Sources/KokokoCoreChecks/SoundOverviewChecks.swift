import Foundation
import KokokoCore
import KokokoLibrary
import KokokoMIDI
import VirtualEP

extension KokokoCoreChecks {
    static func soundOverviewChecks() async {
        soundRangeChecks()
        soundScopeChecks()
        soundStorageChecks()
        await soundDirectoryReadChecks()
        await soundOverviewVirtualChecks()
    }

    private static func soundRangeChecks() {
        eq(SoundRange.all.map(\.name), ["KICK", "SNARE", "CYMB", "PERC", "BASS", "MELOD", "LOOP", "USER1", "USER2", "SFX"],
           "overview: named ranges retain their reference order")
        eq(
            SoundRange.all.map(\.label),
            [
                "001-099", "100-199", "200-299", "300-399", "400-499",
                "500-599", "600-699", "700-799", "800-899", "900-999"
            ],
            "overview: every numeric range is present, not just example groups")
        check(
            (1...999).allSatisfy { slot in SoundRange.all.filter { $0.contains(UInt16(slot)) }.count == 1 },
            "overview: ranges cover each displayed numbered slot exactly once")
        check(SoundRange.all.allSatisfy { !$0.contains(0) && !$0.contains(1000) }, "overview: navigation is not a firmware slot limit")
        let slots: [UInt16] = [65000, 99, 1, 1000, 999, 199, 100, 900, 0]
        let sections = soundSections(all: slots, visible: Set(slots))
        eq(sections.count, 11, "overview: out-of-range sounds remain in another section")
        eq(sections.first?.slots, [1, 99], "overview: sparse range contents use numeric order")
        eq(sections.last?.slots, [0, 1000, 65000], "overview: no zero, high slot or temporary sound is silently dropped")
        eq(sections.flatMap(\.slots).sorted(), slots.sorted(), "overview: grouping preserves every listed sound")
        let empty = soundSections(all: [], visible: [])
        eq(empty.count, 10, "overview: an empty device still exposes every range")
        check(empty.allSatisfy { $0.slots.isEmpty && $0.total == 0 }, "overview: empty range counts stay zero")
        let filtered = soundSections(all: slots, visible: [99, 900, 65000])
        eq(filtered.flatMap(\.slots), [99, 900, 65000], "overview: filtering does not turn bookmarks into pagination")
        eq(filtered.first?.total, 2, "overview: no matches is distinct from an empty range")
        eq(filtered.last?.total, 3, "overview: outlier totals are not limited by the filter")
        eq(empty.first?.emptyText(hasSnapshot: false, fresh: false), "not loaded", "overview: unknown ranges are not labelled empty")
        eq(empty.first?.emptyText(hasSnapshot: true, fresh: false), "not refreshed", "overview: stale ranges are not labelled current")
        eq(empty.first?.emptyText(hasSnapshot: true, fresh: true), "empty", "overview: confirmed empty range is explicit")
        eq(filtered[1].emptyText(hasSnapshot: true, fresh: true), "no matches", "overview: filter hides contents without calling the range empty")
        eq(soundCountsText(total: nil, shown: 0, fresh: false), "sounds ? / shown ?", "overview: unknown listing is not an empty device")
        eq(soundCountsText(total: 0, shown: 0, fresh: true), "sounds 0 / shown 0", "overview: a known empty listing is explicit")
        eq(soundCountsText(total: 9, shown: 3, fresh: false), "sounds 9 / shown 3 (stale)", "overview: old counts are never presented as fresh")
    }

    private static func soundScopeChecks() {
        let kick = SoundRange.all[0], snare = SoundRange.all[1]
        let slots: [UInt16] = [0, 1, 99, 100, 199, 999, 65000]
        let scoped = soundSections(all: slots, visible: Set(slots), range: snare)
        eq(scoped.count, 1, "sound scope: a range tab shows only its own section")
        eq(scoped.first?.id, .range(1), "sound scope: section identity follows the chosen range")
        eq(scoped.first?.title, "SNARE 100-199", "sound scope: heading names the positional range")
        eq(scoped.first?.slots, [100, 199], "sound scope: a range never includes another range or outliers")
        let empty = soundSections(all: slots, visible: [], range: SoundRange.all[4])
        eq(empty.count, 1, "sound scope: an empty selected range remains reachable")
        eq(empty.first?.emptyText(hasSnapshot: true, fresh: true), "empty", "sound scope: a confirmed empty range is explicit")
        let noMatch = soundSections(all: slots, visible: [], range: snare)
        eq(noMatch.first?.emptyText(hasSnapshot: true, fresh: true), "no matches", "sound scope: search does not mislabel a populated range empty")
        check(soundMatches(name: "snare", slot: 1, query: "SNARE", range: kick), "sound scope: range names do not classify audio")
        check(!soundMatches(name: "snare", slot: 1, query: "snare", range: snare), "sound scope: text search intersects the selected range")
        check(soundMatches(name: "kick", slot: 100, query: "1", range: snare), "sound scope: numeric search keeps its existing slot matching")
        check(soundMatches(name: "other", slot: 65000, query: "", range: nil), "sound scope: all has no firmware-cap assumption")
        let items = slots.map { (slot: $0, name: "sample") }
        let selected = visibleSelection(Set(slots), items: items, query: "", range: snare)
        eq(selected, [100, 199], "sound scope: hidden rows cannot remain selected for bulk actions")
        eq(visibleSelection(selected, items: items, query: "", range: nil), selected, "sound scope: all does not resurrect hidden selections")
        eq(visibleSelection(selected, items: items, query: "missing", range: snare), [], "sound scope: search also prunes range selection")
    }

    private static func soundStorageChecks() {
        let known = SoundStorage(metadata: ["max_capacity": .int(1000), "free_space_in_bytes": .int(250)])
        eq(known.totalBytes, 1000, "storage: total comes from the device")
        eq(known.freeBytes, 250, "storage: free comes from the device")
        eq(known.usedBytes, 750, "storage: used is total minus free, not a PCM sum")
        check(!known.invalid, "storage: a consistent snapshot is valid")
        let exact = SoundStorage(metadata: ["max_capacity": .double(1000.0), "free_space_in_bytes": .double(250.0)])
        eq(exact, known, "storage: exact integral JSON doubles are accepted")
        let invalid: [JSONValue] = [
            .bool(true), .string("1000"), .double(1.5), .int(-1), .null,
            .double(.infinity), .double(.nan), .double(.greatestFiniteMagnitude)
        ]
        for value in invalid {
            let bad = SoundStorage(metadata: ["max_capacity": value, "free_space_in_bytes": .int(0)])
            check(
                bad.totalBytes == nil && bad.usedBytes == nil && bad.invalid,
                "storage: non-numeric, negative, fractional and unrepresentable capacities are unknown")
        }
        let bool = JSONValue(any: NSNumber(value: true))
        check(
            SoundStorage(metadata: ["max_capacity": bool ?? .null]).totalBytes == nil,
            "storage: Foundation booleans are not accepted as one byte")
        let partial = SoundStorage(metadata: ["max_capacity": .int(1000)])
        check(
            partial.totalBytes == 1000 && partial.freeBytes == nil && partial.usedBytes == nil,
            "storage: a missing free field does not invent usage")
        let freeOnly = SoundStorage(metadata: ["free_space_in_bytes": .int(250)])
        check(
            freeOnly.freeBytes == 250 && freeOnly.totalBytes == nil && freeOnly.usedBytes == nil,
            "storage: partial values are not filled from a hardcoded device capacity")
        let inconsistent = SoundStorage(metadata: ["max_capacity": .int(1000), "free_space_in_bytes": .int(1001)])
        check(
            inconsistent.invalid && inconsistent.usedBytes == nil && inconsistent.totalBytes == nil && inconsistent.freeBytes == nil,
            "storage: inconsistent values are not clamped into a plausible-looking result")
        eq(
            SoundStorage(metadata: ["max_capacity": .int(0), "free_space_in_bytes": .int(0)]).usedBytes, 0,
            "storage: zero capacity does not divide by zero")
        eq(
            SoundStorage(metadata: ["max_capacity": .int(Int.max), "free_space_in_bytes": .int(0)]).usedBytes, Int64(Int.max),
            "storage: byte arithmetic does not narrow to file-size UInt32")
        eq(storageByteText(nil), "?", "storage: absent values stay unknown")
        eq(storageByteText(-1), "?", "storage: formatter never displays a negative capacity")
        eq(storageByteText(0), "0 B", "storage: zero has explicit byte units")
        eq(storageByteText(1024), "1.0 KiB", "storage: scaled units are explicitly binary")
        eq(storageByteText(1_048_576), "1.0 MiB", "storage: capacity formatting has no SKU lookup")

        var state = SoundStorageState()
        let first = state.begin(generation: 1)
        check(state.finish(request: first, generation: 1, result: .success(known)), "storage: matching read installs a snapshot")
        state.invalidate()
        check(state.stale && state.value == known, "storage: own writes mark a previous value stale")
        let old = state.begin(generation: 1)
        let current = state.begin(generation: 1)
        check(!state.finish(request: old, generation: 1, result: .success(known)), "storage: late read cannot replace a newer request")
        check(state.finish(request: current, generation: 1, result: .success(partial)), "storage: current partial snapshot is accepted")
        check(
            state.value?.freeBytes == nil && state.value?.usedBytes == nil,
            "storage: new partial metadata is never mixed with old fields")
        let reconnect = state.begin(generation: 2)
        check(state.value == nil, "storage: a new device never displays the old device capacity")
        check(!state.finish(request: current, generation: 1, result: .success(known)), "storage: old generation cannot repopulate new state")
        check(
            state.finish(request: reconnect, generation: 2, result: .failure(OverviewReadError.storage)),
            "storage: a failed current read is recorded")
        check(state.value == nil && state.message != nil, "storage: failure is unknown, not zero or old success")
    }

    private static func soundOverviewVirtualChecks() async {
        let vep = VirtualEPDevice(name: "kokoko-vep-overview-\(getpid())")
        do {
            try vep.start()
            defer { vep.stop() }
            try await Task.sleep(for: .milliseconds(300))
            guard let pair = enumerateMIDIPairs().first(where: { $0.name == vep.name }) else {
                check(false, "overview vep: own device enumerated")
                return
            }
            let wire = try CoreMIDIWire(pair: pair)
            let identity = try await identifyDevice(on: wire)
            let files = DeviceFileService(session: SysExSession(wire: wire, identityCode: identity.deviceID))
            try await files.initialize()
            let root = try await DeviceLibrary(files: files).resolve("/sounds")
            let unknown = await readSoundDirectory(files: files, root: root)
            if case .success(let storage) = unknown.storage {
                check(storage.totalBytes == nil && storage.freeBytes == nil, "overview vep: missing metadata never falls back to a SKU capacity")
            } else {
                check(false, "overview vep: root metadata read succeeds")
            }
            try await files.setMetadata(fileID: root, ["max_capacity": .int(1000), "free_space_in_bytes": .int(250)])
            let read = await readSoundDirectory(files: files, root: root)
            if case .success(let nodes) = read.nodes {
                eq(nodes.filter(\.isFile).count, 2, "overview vep: actual listed file count is independent of storage")
            } else {
                check(false, "overview vep: directory listing succeeds")
            }
            if case .success(let storage) = read.storage {
                eq(storage.usedBytes, 750, "overview vep: reported root values, not PCM lengths, determine usage")
            } else {
                check(false, "overview vep: reported storage reads back")
            }
        } catch { check(false, "overview vep: \(error.localizedDescription)") }
    }

    private static func soundDirectoryReadChecks() async {
        for listFails in [false, true] {
            for storageFails in [false, true] {
                let reads = OverviewReadFixture(listFails: listFails, storageFails: storageFails)
                let result = await readSoundDirectorySteps(
                    list: { try await reads.list() },
                    storage: { await readSoundStorageSteps(get: { try await reads.storageMetadata() }) })
                eq(await reads.events, ["list", "storage"], "overview read: exactly one sequential storage query even if listing fails")
                switch result.nodes {
                case .success(let nodes): check(!listFails && nodes.isEmpty, "overview read: list success survives an independent storage error")
                case .failure(let error):
                    check(listFails && error as? OverviewReadError == .list, "overview read: storage cannot replace the main listing error")
                }
                switch result.storage {
                case .success(let value): check(!storageFails && value.usedBytes == 20, "overview read: capacity can succeed after list failure")
                case .failure(let error): check(storageFails && error as? OverviewReadError == .storage, "overview read: capacity failure remains separate")
                }
            }
        }
    }
}

private enum OverviewReadError: Error { case list, storage }

private actor OverviewReadFixture {
    let listFails: Bool
    let storageFails: Bool
    var events: [String] = []

    init(listFails: Bool, storageFails: Bool) {
        self.listFails = listFails
        self.storageFails = storageFails
    }

    func list() throws -> [FSNode] {
        events.append("list")
        if listFails { throw OverviewReadError.list }
        return []
    }

    func storageMetadata() throws -> [String: JSONValue] {
        events.append("storage")
        if storageFails { throw OverviewReadError.storage }
        return ["max_capacity": .int(100), "free_space_in_bytes": .int(80)]
    }
}
