#if os(macOS) && DEBUG
import AppKit
import Combine
import Foundation
import SwiftUI
import KokokoCore
import KokokoLibrary
@testable import KokokoMIDI

private actor WaveformReductionBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    private(set) var waiting = false
    func pause() async {
        waiting = true
        guard !open else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class SwapConfirmationProbe {
    var frames: [String: CGRect] = [:]
}

struct SwapConfirmationFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor
enum WaveformValidityChecks {
    private static var failures = 0
    private static let item = SoundItem(node: FSNode(id: 1, parentID: 10, name: "1", flags: 0xff, size: 4), displayName: "sound")
    private static let metadata: [String: JSONValue] = [
        "channels": .int(1), "samplerate": .int(46875), "sound.loopstart": .int(0), "sound.loopend": .int(1)
    ]
    private nonisolated static let pcm: [UInt8] = [0, 0, 0, 128]

    static func run() async -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        await soundMoveSafety()
        await reopen()
        await rowProof()
        await validation()
        await metadataObservations()
        await observationLifetimes()
        await listingLifetimes()
        await readbackLifetimes()
        await foregroundAdmission()
        await fileAdmissionOwnership()
        await processedDropOwnership()
        await folderAdmissionOwnership()
        await changedForegroundTarget()
        await automaticWaveforms()
        await invalidation()
        print(failures == 0 ? "waveform validity: all checks passed" : "waveform validity: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    static func runSoundMoves() async -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        await inlineSwap()
        await rollbackRecovery()
        await soundMoveSafety()
        print(failures == 0 ? "sound moves: all checks passed" : "sound moves: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    private static func inlineSwap() async {
        func sound(_ id: UInt16, size: UInt32 = 4) -> SoundItem {
            SoundItem(node: FSNode(id: id, parentID: 10, name: String(id), flags: 29, size: size), displayName: "sound")
        }
        let f = await Fixture(listed: [sound(1), sound(2)])
        f.wire.setMetadata(metadata.merging(["name": .string("sound")], uniquingKeysWith: { _, new in new }))
        f.wire.setListedSlots([1, 2])
        f.state.selection = [1]
        f.state.requestSwap(id: 1, onto: sound(2))
        guard let pending = f.state.pendingSwap else { check(false, "swap inline: valid drop opens confirmation"); await f.close(); return }
        check(f.wire.requests.allSatisfy { $0.first != FileSub.move }, "swap inline: opening confirmation sends no MOVE")
        check(f.state.cancelSwap(session: pending.session), "swap inline: unsent confirmation cancels")
        await f.state.confirmSwap(session: pending.session)
        check(f.wire.requests.allSatisfy { $0.first != FileSub.move }, "swap inline: old submit after cancel sends no MOVE")
        f.state.requestSwap(id: 1, onto: sound(2))
        let stale = f.state.pendingSwap!
        f.state.sounds = [sound(1, size: 8), sound(2)]
        await f.state.confirmSwap(session: stale.session)
        check(f.state.pendingSwap == nil && f.wire.requests.allSatisfy { $0.first != FileSub.move }, "swap inline: replaced source invalidates snapshot")
        f.state.sounds = [sound(1), sound(2)]
        f.state.requestSwap(id: 1, onto: sound(2))
        let first = f.state.pendingSwap!
        f.state.requestSwap(id: 2, onto: sound(1))
        check(f.state.pendingSwap?.session == first.session, "swap inline: second drop cannot replace pending intent")
        _ = f.state.cancelSwap(session: first.session)
        f.state.requestSwap(id: 1, onto: sound(2))
        let accepted = f.state.pendingSwap!
        await f.state.confirmSwap(session: accepted.session)
        await f.state.confirmSwap(session: accepted.session)
        check(f.state.pendingSwap == nil && f.state.selection == [2], "swap inline: confirmed swap follows selected sound")
        check(f.wire.requests.filter { $0.first == FileSub.move }.count == 3, "swap inline: duplicate submit cannot repeat the swap")
        f.state.requestSwap(id: 1, onto: sound(2))
        check(f.state.enterDevice(), "swap inline: unrelated operation occupies admission")
        await f.state.confirmSwap(session: f.state.pendingSwap!.session)
        check(f.state.pendingSwap?.session == f.state.pendingSwap!.session && f.wire.requests.filter { $0.first == FileSub.move }.count == 3, "swap inline: busy submit preserves unsent confirmation")
        check(f.state.cancelSwap(session: f.state.pendingSwap!.session), "swap inline: busy device still allows unsent cancel")
        await f.close()

        let changed = await Fixture(listed: [sound(1), sound(2)])
        changed.wire.setListedSlots([1, 2])
        changed.state.requestSwap(id: 1, onto: sound(2))
        let old = changed.state.pendingSwap!
        changed.wire.setListedSlots([1, 3])
        await changed.state.confirmSwap(session: old.session)
        check(changed.wire.requests.allSatisfy { $0.first != FileSub.move } && changed.state.lastError != nil, "swap inline: fresh listing rejects missing target instead of moving into it")
        changed.state.sounds = [sound(1), sound(2)]
        changed.state.requestSwap(id: 1, onto: sound(2))
        let disconnected = changed.state.pendingSwap!
        changed.state.forgetDevice()
        changed.state.sounds = [sound(1), sound(2)]
        await changed.state.confirmSwap(session: disconnected.session)
        check(changed.wire.requests.allSatisfy { $0.first != FileSub.move }, "swap inline: disconnected snapshot never dispatches")
        await changed.close()

        let connection = await Fixture(listed: [sound(1), sound(2)])
        connection.wire.setListedSlots([1, 2])
        connection.wire.setMetadata(metadata.merging(["name": .string("sound")], uniquingKeysWith: { _, new in new }))
        connection.state.requestSwap(id: 1, onto: sound(2))
        let previous = connection.state.pendingSwap!
        connection.state.connection = .connected(deviceName: "other fixture", serial: "other fixture", osVersion: "test")
        await connection.state.confirmSwap(session: previous.session)
        check(connection.state.pendingSwap == nil && connection.wire.requests.allSatisfy { $0.first != FileSub.move },
              "swap inline: changed connection rejects a pending snapshot even with identical rows")
        await connection.close()

        let waiting = await Fixture(listed: [sound(1), sound(2)])
        waiting.wire.setListedSlots([1, 2])
        waiting.wire.setMetadata(metadata.merging(["name": .string("sound")], uniquingKeysWith: { _, new in new }))
        waiting.state.requestSwap(id: 1, onto: sound(2))
        let inflight = waiting.state.pendingSwap!
        waiting.wire.holdMetadata()
        let task = Task { await waiting.state.confirmSwap(session: inflight.session) }
        check(await held(waiting.wire), "swap inline: preflight reaches real metadata await")
        check(waiting.state.pendingSwap?.submitting == true && !waiting.state.canConfirmSwap,
              "swap inline: preflight prevents duplicate submit")
        check(!waiting.state.cancelSwap(session: inflight.session), "swap inline: dispatched operation cannot be cancelled by closing confirmation")
        await waiting.state.confirmSwap(session: inflight.session)
        waiting.state.forgetDevice()
        waiting.state.sounds = [sound(1), sound(2)]
        waiting.wire.resume()
        await task.value
        check(waiting.wire.requests.allSatisfy { $0.first != FileSub.move } && waiting.state.selection.isEmpty,
              "swap inline: disconnect during preflight cannot write or carry selection")
        await waiting.close()

        for width: CGFloat in [420, 840] {
            let ui = await Fixture(listed: [sound(1), sound(2)])
            ui.state.requestSwap(id: 1, onto: sound(2))
            let probe = SwapConfirmationProbe()
            let host = NSHostingView(rootView: ContentView(state: ui.state, suppressDeviceObservationForCheck: true,
                                                           swapProbeForCheck: probe).environment(\.dynamicTypeSize, .accessibility2))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            for _ in 0..<12 {
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(10))
            }
            check(probe.frames.count == 3, "swap UI: production inline summary and actions have layout frames")
            check(probe.frames.values.allSatisfy { $0.width > 0 && $0.minX >= -1 && $0.maxX <= width + 1 },
                  "swap UI: confirmation fits compact and regular widths with larger type")
            if let swap = probe.frames["swap"], let cancel = probe.frames["cancel"] {
                check(swap.height >= minHitHeight && cancel.height >= minHitHeight && !swap.intersects(cancel),
                      "swap UI: distinct production actions keep their minimum hit regions")
            }
            check(!window.isVisible && !window.isMainWindow && !window.isKeyWindow && ui.wire.requests.allSatisfy { $0.first != FileSub.move },
                  "swap UI: layout host stays hidden and performs no MOVE")
            window.contentView = nil
            window.close()
            await ui.close()
        }
    }

    private static func rollbackRecovery() async {
        func sound(_ id: UInt16) -> SoundItem {
            SoundItem(node: FSNode(id: id, parentID: 10, name: String(id), flags: 29, size: 4), displayName: "sound")
        }
        for (forward, undo, expected): (Int, WaveformWire.MoveFault, Set<UInt16>) in [
            (2, .landedTimeout, [1, 2]), (2, .timeout, [2, 999]), (2, .refused, [2, 999]),
            (3, .landedTimeout, [2, 999])
        ] {
            let f = await Fixture(listed: [sound(1), sound(2)])
            f.wire.setListedSlots([1, 2])
            f.wire.moveFaults([forward: .refused, forward + 1: undo])
            f.state.selection = [1, 2]
            await f.state.moveOrSwap(id: 1, toSlot: 2)
            check(Set(f.state.sounds.map(\.id)) == expected && f.state.selection == expected,
                  "rollback app: selection follows confirmed placement after \(forward)/\(undo)")
            check(f.wire.moveOrder.count == forward + 1 && f.wire.safeMoves,
                  "rollback app: failed undo stops without retry or occupied-target writes")
            check(f.state.lastError != nil, "rollback app: original failure remains visible")
            await f.close()
        }
        let lost = await Fixture(listed: [sound(1), sound(2)])
        lost.wire.setListedSlots([1, 2])
        lost.wire.moveFaults([2: .landedTimeout, 3: .landedTimeout])
        lost.state.selection = [1, 2]
        await lost.state.moveOrSwap(id: 1, toSlot: 2)
        check(lost.state.selection == [2, 999] && Set(lost.state.sounds.map(\.id)) == [2, 999],
              "rollback app: lost forward and reverse replies each remap exactly once")
        check(lost.wire.moveOrder.count == 3 && lost.wire.safeMoves, "rollback app: landed lost reply is never retried")
        await lost.close()

        let bulk = await Fixture(listed: [sound(1), sound(2)])
        bulk.wire.setListedSlots([1, 2])
        bulk.wire.moveFaults([4: .refused, 5: .landedTimeout])
        bulk.state.selection = [1, 2]
        await bulk.state.moveSelection(startingAt: 10)
        check(bulk.state.selection == [998, 999] && Set(bulk.state.sounds.map(\.id)) == [998, 999],
              "rollback app: a longer plan carries the selection back to scratch after a lost undo reply")
        check(bulk.wire.moveOrder.count == 5 && bulk.wire.safeMoves, "rollback app: longer plan stops at failed reverse reply")
        await bulk.close()

        for failedList in [2, 3] {
            let f = await Fixture(listed: [sound(1), sound(2)])
            f.wire.setListedSlots([1, 2])
            f.wire.moveFaults([2: .refused, 3: .landedTimeout])
            f.wire.failLists([failedList])
            f.state.selection = [1]
            await f.state.moveOrSwap(id: 1, toSlot: 2)
            check(f.wire.moveOrder.count == (failedList == 2 ? 2 : 3) && f.wire.safeMoves,
                  "rollback app: failed recovery listing schedules no further MOVE")
            check(f.state.lastError?.contains("placement unknown") == true,
                  "rollback app: unreadable recovery listing reports unknown placement")
            await f.close()
        }

        for lostReply in [false, true] {
            let stale = await Fixture(listed: [sound(1), sound(2)])
            stale.wire.setListedSlots([1, 2])
            stale.wire.moveFaults(lostReply ? [2: .refused, 3: .landedTimeout] : [2: .refused])
            stale.wire.holdMove(at: 3)
            stale.state.selection = [1]
            let task = Task { await stale.state.moveOrSwap(id: 1, toSlot: 2) }
            check(await held(stale.wire), "rollback app: reverse MOVE reaches the wire barrier")
            stale.state.forgetDevice()
            stale.state.sounds = [sound(999)]
            stale.state.selection = [999]
            stale.wire.resume()
            await task.value
            check(stale.state.selection == [999] && stale.wire.moveOrder.count == 3,
                  "rollback app: old reverse completion cannot remap a new device selection")
            await stale.close()
        }
        let reread = await Fixture(listed: [sound(1), sound(2)])
        reread.wire.setListedSlots([1, 2])
        reread.wire.moveFaults([2: .refused])
        reread.wire.holdList(at: 2)
        reread.state.selection = [1]
        let recovery = Task { await reread.state.moveOrSwap(id: 1, toSlot: 2) }
        check(await held(reread.wire), "rollback app: forward failure reaches recovery LIST barrier")
        reread.state.forgetDevice()
        reread.state.sounds = [sound(999)]
        reread.state.selection = [999]
        reread.wire.resume()
        await recovery.value
        check(reread.state.selection == [999] && reread.wire.moveOrder.count == 2,
              "rollback app: stale recovery listing cannot schedule undo or remap new selection")
        await reread.close()

    }

    private static func soundMoveSafety() async {
        func sound(_ id: UInt16) -> SoundItem {
            SoundItem(node: FSNode(id: id, parentID: 10, name: String(id), flags: 29, size: 4), displayName: "sound")
        }
        let valid = await Fixture(listed: [sound(32), sound(33)])
        valid.wire.setListedSlots([32, 33])
        valid.state.selection = [32]
        await valid.state.moveOrSwap(id: 32, toSlot: 999)
        check(valid.state.selection == [999] && Set(valid.state.sounds.map(\.id)) == [33, 999] && valid.state.lastError == nil,
              "move app: a sound without the MOVE flag can move to valid free slot 999")
        await valid.state.moveOrSwap(id: 999, toSlot: 33)
        check(valid.state.selection == [33] && Set(valid.state.sounds.map(\.id)) == [33, 999] && valid.state.lastError == nil,
              "move app: actual swap carries selection through valid scratch")
        valid.state.selection = [33, 999]
        await valid.state.moveSelection(startingAt: 100)
        check(valid.state.selection == [100, 101] && Set(valid.state.sounds.map(\.id)) == [100, 101] && valid.state.lastError == nil,
              "move app: actual bulk move returns all sounds from valid scratch")
        await valid.close()
        for invalid: UInt16 in [0, 1000, 1001, 65000] {
            let f = await Fixture(listed: [sound(1), sound(invalid)])
            f.wire.setListedSlots([1, invalid])
            f.state.selection = [1]
            await f.state.moveOrSwap(id: 1, toSlot: invalid)
            check(f.state.lastError != nil, "move app: invalid destination has a visible refusal")
            await f.state.moveOrSwap(id: invalid, toSlot: 2)
            f.state.selection = [invalid]
            await f.state.moveSelection(startingAt: 2)
            f.state.selection = [1]
            await f.state.moveSelection(startingAt: invalid)
            f.state.beginInlineSlot(sound(1))
            if let edit = f.state.inlineSlotEdit {
                f.state.inlineSlotEdit?.draft = String(invalid)
                check(!(await f.state.commitInlineSlot(session: edit.session)), "move app: invalid inline target stays unsaved")
            } else { check(false, "move app: inline safety fixture opens its editor") }
            check(!f.wire.requests.contains { $0.first == FileSub.move },
                  "move app: invalid single, bulk and inline endpoints send zero MOVE requests")
            check(f.state.sounds.contains { $0.id == invalid }, "move app: out-of-domain nodes remain visible")
            await f.close()
        }
        for text in ["65536", "-1", "+2", " 2", "2x", "", "１２"] {
            let f = await Fixture()
            f.state.selection = [1]
            f.state.bulkMoveStart = text
            await f.state.moveSelectionFromDraft()
            check(f.state.lastError?.contains("1 to 999") == true,
                  "move app: invalid bulk text gives a range error")
            check(!f.wire.requests.contains { $0.first == FileSub.move },
                  "move app: invalid bulk text sends zero MOVE requests")
            await f.close()
        }
        let missing = await Fixture()
        missing.wire.setListedSlots([2])
        missing.state.selection = [1]
        await missing.state.moveOrSwap(id: 1, toSlot: 3)
        check(Set(missing.state.sounds.map(\.id)) == [2] && missing.state.selection.isEmpty,
              "move app: a missing source refreshes stale rows and selection")
        check(!missing.wire.requests.contains { $0.first == FileSub.move } && missing.state.lastError != nil,
              "move app: missing source refuses MOVE and reports why")
        await missing.close()
        for free: Set<UInt16> in [[], [999]] {
            let ids = Set(UInt16(1)...UInt16(999)).subtracting(free)
            let f = await Fixture(listed: ids.sorted().map(sound))
            f.wire.setListedSlots(ids.sorted())
            f.state.selection = [1, 2]
            await f.state.moveSelection(startingAt: 1)
            check(f.state.lastError != nil, "move app: insufficient bulk scratch has a visible refusal")
            if free.isEmpty {
                await f.state.moveOrSwap(id: 1, toSlot: 2)
                check(f.state.lastError != nil, "move app: a full-library swap has a visible refusal")
            }
            check(!f.wire.requests.contains { $0.first == FileSub.move },
                  "move app: insufficient scratch sends zero MOVE requests")
            check(f.state.selection == [1, 2] && Set(f.state.sounds.map(\.id)) == ids,
                  "move app: refused plan preserves selection and the complete listing")
            await f.close()
        }
    }

    private static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "ok  " : "FAIL") \(message)")
        if !condition { failures += 1 }
    }

    @MainActor private final class Fixture {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/waveform-check-" + UUID().uuidString)
        let wire = WaveformWire()
        let session: SysExSession
        let files: DeviceFileService
        let cache: WaveformCacheStore
        let state: AppState
        let cacheSession: UUID

        init(listingMetadata: [String: JSONValue]? = nil, listed: [SoundItem]? = nil) async {
            let listed = listed ?? [item]
            session = SysExSession(wire: wire, identityCode: 0x10)
            files = DeviceFileService(session: session)
            cache = WaveformCacheStore(root: root)
            cacheSession = await cache.configure(model: "fixture", serial: "fixture")
            let formats = Dictionary(uniqueKeysWithValues: listed.compactMap { item in listingMetadata.map { (item.id, $0) } })
            state = AppState(listedSounds: listed, waveformCache: cache,
                             files: files, cacheSession: cacheSession,
                             listingMetadata: formats, soundRootID: 10)
            state.connection = .connected(deviceName: "fixture", serial: "fixture", osVersion: "test")
            wire.setMetadata(metadata)
            do { try await files.initialize(subscribe: false) }
            catch { check(false, "waveform fixture: in-memory file service initializes") }
        }

        func seed() async {
            let token = await cache.token(session: cacheSession)!
            _ = await cache.store(WaveformPeakRecord(pcm: pcm, channels: 1, sampleRate: 46875)!,
                                  slot: 1, token: token, lease: WaveformCacheLease())
        }

        func close() async {
            await session.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func reopen() async {
        let f = await Fixture()
        f.state.prepareWaveformRow(item, epoch: f.state.waveformRows.epoch)
        check(f.wire.reads == 0, "waveform app: row appearance issues no PCM request in stage A")
        await f.state.showWaveform(item)
        check(f.state.waveformShown?.record != nil, "waveform app: actual file-service read supplies peaks")
        let first = f.state.waveformShown?.description
        check(first == "Waveform", "waveform app: confirmed audio has a neutral presentation")
        f.state.waveformShown = nil
        f.wire.holdMetadata()
        let reopened = Task { @MainActor in await f.state.showWaveform(item) }
        check(await held(f.wire), "waveform app: same-session reopen reaches metadata barrier")
        check(f.state.waveformShown?.record != nil && f.state.waveformShown?.description == first,
              "waveform app: retained proof stays usable while same-session validation is pending")
        f.wire.resume()
        await reopened.value
        check(f.state.waveformShown?.description == first, "waveform app: actual close/reopen does not downgrade the same sound")
        check(f.wire.reads == 1, "waveform app: same-session reopen does not reread PCM")
        f.state.releaseWaveformRow(item, epoch: f.state.waveformRows.epoch)
        await f.state.showWaveform(item)
        check(f.state.waveformShown?.description == first && f.wire.reads == 1,
              "waveform app: retained confirmation survives row eviction without a PCM reread")
        var edit = InlineMetadataEdit(id: 1, name: "sound", generation: 0)
        _ = edit.loaded(request: edit.request!, metadata: metadata, error: nil)
        edit.form?.text["sound.loopstart"] = "999"
        f.state.metadataEditing = edit
        check(f.state.waveformShown?.loopStart == 0, "waveform app: unsaved loop draft never changes a confirmed overlay")
        f.state.metadataEditing = nil
        guard let editing = await f.state.editMetadata(item) else {
            check(false, "waveform app: actual metadata editor opens")
            await f.close()
            return
        }
        f.state.metadataEditing?.form?.text["sound.loopstart"] = " 0001 "
        check(await f.state.saveMetadata(session: editing), "waveform app: actual SET and readback confirm the loop edit")
        f.wire.holdMetadata()
        let reopening = Task { @MainActor in await f.state.showWaveform(item) }
        check(await held(f.wire), "waveform app: reopened details wait at metadata barrier")
        check(f.state.waveformShown?.loopStart == 1, "waveform app: retained overlay uses confirmed readback, not old metadata or raw draft")
        f.wire.resume()
        await reopening.value
        check(f.state.waveformShown?.loopStart == 1 && f.wire.reads == 1, "waveform app: loop metadata update does not require new PCM")
        await f.close()
    }

    private static func rowProof() async {
        let f = await Fixture(listingMetadata: metadata)
        await f.seed()
        f.state.prepareWaveformRow(item, epoch: f.state.waveformRows.epoch)
        check(await previewReady(f.state), "waveform app: confirmed listing descriptor permits local peaks without opening details")
        check(f.wire.reads == 0, "waveform app: descriptor validation adds no row PCM reads")
        f.state.releaseWaveformRow(item, epoch: f.state.waveformRows.epoch)
        f.state.prepareWaveformRow(item, epoch: f.state.waveformRows.epoch)
        check(await previewReady(f.state), "waveform app: retained listing confirmation survives row eviction")
        f.state.forgetDevice()
        check(f.state.waveformSnapshot(for: item) == nil, "waveform app: device reset removes the old preview proof")
        let nextSession = await f.cache.configure(model: "fixture", serial: "fixture")
        let next = AppState(listedSounds: [item], waveformCache: f.cache, files: f.files, cacheSession: nextSession)
        next.connection = .connected(deviceName: "fixture", serial: "fixture", osVersion: "test")
        next.prepareWaveformRow(item, epoch: next.waveformRows.epoch)
        check(next.waveformRows.needsLookup(slot: 1, size: 4) && next.waveformSnapshot(for: item) == nil,
              "waveform app: a new session cannot reuse old confirmation without current metadata")
        check(await f.cache.load(session: nextSession, slot: 1, size: 4) != nil,
              "waveform app: session proof reset does not erase a persistent candidate")
        await f.close()
    }

    private static func previewReady(_ state: AppState) async -> Bool {
        for _ in 0..<2000 {
            if state.waveformSnapshot(for: item) != nil { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private static func validation() async {
        let waiting = await Fixture()
        await waiting.seed()
        waiting.wire.holdMetadata()
        let pending = Task { @MainActor in await waiting.state.showWaveform(item) }
        check(await held(waiting.wire), "waveform app: actual metadata request reaches validation barrier")
        check(waiting.state.waveformShown?.record == nil, "waveform app: unvalidated cross-session candidate stays hidden")
        waiting.wire.resume()
        await pending.value
        check(waiting.state.waveformShown?.record != nil && waiting.wire.reads == 0,
              "waveform app: descriptor-matched persistent peaks need no PCM reread")
        await waiting.close()
        var missing = metadata
        missing["channels"] = nil
        var wrong = metadata
        wrong["samplerate"] = .bool(true)
        for value in [missing, wrong] {
            let f = await Fixture()
            await f.seed()
            f.wire.setMetadata(value)
            await f.state.showWaveform(item)
            check(f.state.waveformShown?.record == nil, "waveform app: missing or invalid metadata hides old peaks")
            check(f.wire.reads == 0, "waveform app: invalid metadata never causes a guessed-format PCM read")
            check(f.state.lastError != nil, "waveform app: format validation preserves a real error")
            await f.close()
        }
        let failed = await Fixture()
        await failed.seed()
        failed.wire.failMetadata()
        await failed.state.showWaveform(item)
        check(failed.state.waveformShown?.record == nil && failed.state.lastError != nil,
              "waveform app: failed metadata validation cannot leave a candidate visible")
        await failed.close()
        let changed = await Fixture()
        await changed.state.showWaveform(item)
        var stereo = metadata
        stereo["channels"] = .int(2)
        changed.wire.setMetadata(stereo)
        changed.wire.holdPCM()
        changed.state.waveformShown = nil
        let replacing = Task { @MainActor in await changed.state.showWaveform(item) }
        check(await held(changed.wire), "waveform app: same-size format replacement reaches PCM barrier")
        check(changed.state.waveformShown?.record == nil && changed.state.waveformSnapshot(for: item) == nil,
              "waveform app: known mismatched peaks disappear before replacement PCM arrives")
        changed.wire.resume()
        await replacing.value
        check(changed.state.waveformShown?.record?.channels == 2 && changed.wire.reads == 2,
              "waveform app: only descriptor-matched replacement peaks become usable")
        await changed.close()
    }

    private static func metadataObservations() async {
        for editor in [true, false] {
            for failed in [true, false] {
                let f = await Fixture()
                await f.state.showWaveform(item)
                check(f.state.waveformSnapshot(for: item) != nil, "waveform app: a confirmed preview exists before another metadata observation")
                if failed { f.wire.failMetadata() }
                else {
                    var missing = metadata
                    missing["samplerate"] = nil
                    f.wire.setMetadata(missing)
                }
                if editor { _ = await f.state.editMetadata(item) }
                else { _ = await f.state.download(item) }
                check(f.state.waveformSnapshot(for: item) == nil,
                      "waveform app: editor/export metadata failure or invalid format cannot leave old peaks usable")
                check(f.state.waveformShown?.record == nil, "waveform app: another metadata observation immediately hides any expanded invalid peaks")
                await f.close()
            }
        }
    }

    private enum MetadataResponse: CaseIterable { case valid, missing, changedFormat, failure }
    private enum ObservationContext: CaseIterable { case same, mutation, disconnect }
    private enum MetadataOwner: CaseIterable { case editor, detail, export }

    private static func observationLifetimes() async {
        for owner in MetadataOwner.allCases {
            for response in MetadataResponse.allCases {
                for context in ObservationContext.allCases {
                    let f = await Fixture()
                    await f.state.showWaveform(item)
                    var observed = metadata
                    if response == .missing { observed["channels"] = nil }
                    if response == .changedFormat { observed["channels"] = .int(2) }
                    f.wire.setMetadata(observed)
                    if response == .failure { f.wire.failMetadata() }
                    if owner == .detail { f.state.waveformShown = nil }
                    f.wire.holdMetadata()
                    let reading = Task { @MainActor in
                        switch owner {
                        case .editor: _ = await f.state.editMetadata(item)
                        case .detail: await f.state.showWaveform(item)
                        case .export: _ = await f.state.download(item)
                        }
                    }
                    check(await held(f.wire), "waveform observation: actual request reaches lifetime barrier")
                    if owner == .editor {
                        if let editing = f.state.metadataEditing?.session {
                            check(f.state.cancelMetadata(session: editing), "waveform observation: loading editor closes without aborting device observation")
                        } else {
                            check(false, "waveform observation: editor exists at cancellation barrier")
                        }
                    }
                    f.state.waveformShown = nil
                    if context == .mutation { await f.state.invalidateWaveformContent(slots: [1]) }
                    if context == .disconnect { f.state.forgetDevice() }
                    f.wire.resume()
                    _ = await reading.value
                    print("waveform observation case:", owner, response, context)
                    check(f.state.metadataEditing == nil && f.state.waveformShown == nil,
                          "waveform observation: callback never reopens a closed presentation")
                    if context == .same && response == .valid {
                        check(f.state.waveformSnapshot(for: item) != nil,
                              "waveform observation: closing alone preserves matching confirmation")
                    } else {
                        check(f.state.waveformSnapshot(for: item) == nil,
                              "waveform observation: negative current or stale response cannot retain old acceptance")
                    }
                    if context == .same && response == .failure {
                        check(f.state.lastError != nil, "waveform observation: closing UI never suppresses a current metadata error")
                    }
                    if context == .mutation {
                        f.state.prepareWaveformRow(item, epoch: f.state.waveformRows.epoch)
                        check(f.state.waveformRows.needsLookup(slot: 1, size: 4),
                              "waveform observation: old response cannot restore confirmation after mutation")
                    }
                    if context != .same {
                        check(f.wire.reads == 1, "waveform observation: stale metadata cannot enqueue a later PCM command")
                    }
                    await f.close()
                }
            }
        }
    }

    private static func listingLifetimes() async {
        for context in ObservationContext.allCases {
            let f = await Fixture()
            await f.state.showWaveform(item)
            f.wire.holdMetadata(fileID: 1)
            let listing = Task { @MainActor in await f.state.reload() }
            check(await held(f.wire), "waveform listing: actual sound metadata reaches snapshot barrier")
            if context == .mutation { await f.state.invalidateWaveformContent(slots: [1]) }
            if context == .disconnect { f.state.forgetDevice() }
            f.wire.resume()
            let accepted = await listing.value
            check(accepted == (context == .same), "waveform listing: only current device/content snapshot may commit confirmation")
            if context == .same {
                f.state.prepareWaveformRow(item, epoch: f.state.waveformRows.epoch)
                check(await previewReady(f.state), "waveform listing: actual listing metadata is reused for local preview")
            } else {
                check(f.state.waveformSnapshot(for: item) == nil, "waveform listing: obsolete listing cannot restore old preview")
            }
            check(f.wire.reads == 1, "waveform listing: validation never adds offscreen PCM reads")
            await f.close()
        }
    }

    private static func readbackLifetimes() async {
        for close in [false, true] {
            for context in ObservationContext.allCases {
                for response in MetadataResponse.allCases {
                    await readbackLifetime(close: close, context: context, response: response)
                }
            }
        }
    }

    private static func readbackLifetime(close: Bool, context: ObservationContext, response: MetadataResponse) async {
        let f = await Fixture()
        await f.state.showWaveform(item)
        guard let editing = await f.state.editMetadata(item) else {
            check(false, "waveform readback: actual editor opens")
            await f.close()
            return
        }
        f.state.metadataEditing?.form?.text["sound.loopstart"] = "1"
        var observed = metadata
        if response == .missing { observed["channels"] = nil }
        if response == .changedFormat { observed["channels"] = .int(2) }
        f.wire.setMetadata(observed)
        if response == .failure { f.wire.failMetadata() }
        f.wire.holdMetadata(fileID: 1)
        let saving = Task { @MainActor in await f.state.saveMetadata(session: editing) }
        check(await held(f.wire), "waveform readback: actual SET has reached readback barrier")
        if close { f.state.view = .projects }
        if context == .mutation { await f.state.invalidateWaveformContent(slots: [1]) }
        if context == .disconnect { f.state.forgetDevice() }
        f.wire.resume()
        _ = await saving.value
        if close {
            check(f.state.metadataEditing == nil && f.state.waveformShown == nil,
                  "waveform readback: confirmation never reopens a closed presentation")
        }
        if context != .same || response != .valid {
            check(f.state.waveformSnapshot(for: item) == nil, "waveform readback: stale content or invalid readback never restores old peaks")
            if context == .mutation {
                f.state.view = .sounds
                f.state.prepareWaveformRow(item, epoch: f.state.waveformRows.epoch)
                check(f.state.waveformRows.needsLookup(slot: 1, size: 4), "waveform readback: obsolete response leaves confirmation absent")
            }
            if context == .same && response == .failure {
                check(f.state.lastError != nil, "waveform readback: closing UI never suppresses a current readback error")
            }
        } else {
            f.state.view = .sounds
            f.state.prepareWaveformRow(item, epoch: f.state.waveformRows.epoch)
            check(await previewReady(f.state), "waveform readback: current confirmed baseline restores usable peaks after editor closure or completion")
            f.wire.holdMetadata(fileID: 1)
            let opening = Task { @MainActor in await f.state.showWaveform(item) }
            check(await held(f.wire), "waveform readback: reopening reaches a new validation barrier")
            check(f.state.waveformShown?.loopStart == 1, "waveform readback: restored peaks use the actual confirmed loop baseline before another validation")
            f.wire.resume()
            await opening.value
        }
        check(f.wire.reads == 1, "waveform readback: no additional PCM is queued")
        await f.close()
    }

    private static func automaticWaveforms() async {
        for cached in [false, true] {
            let f = await Fixture(listingMetadata: metadata)
            if cached { await f.seed() }
            let owner = UUID()
            let context = policyViewport(f.state, item: item, owner: owner)
            check(await previewReady(f.state), "automatic policy: current eligible row receives accepted peaks without a button")
            check(await automaticIdle(f.state), "automatic policy: one drain finishes")
            check(f.wire.reads == (cached ? 0 : 1), "automatic policy: disk hit avoids PCM, miss performs one GET")
            let record = await f.cache.load(session: f.cacheSession, slot: 1, size: 4)
            check(record != nil, "automatic policy: accepted peaks integrate with persistent cache")
            for _ in 0..<10 { _ = policyViewport(f.state, item: item, owner: owner) }
            check(await automaticIdle(f.state) && f.wire.reads == (cached ? 0 : 1), "automatic policy: duplicate viewport delivery never repeats a completed read")
            withdrawPolicyViewport(f.state, context: context, owner: owner)
            await f.close()
        }
        await automaticCoalescing()
        await automaticObstructionGate()
        await automaticQueueCancellation()
        await automaticContextReset()
        await automaticFailureMemo()
        await automaticAnnouncedBudget()
        await automaticReductionHandoff()
        await automaticLargeViewport()
        await automaticHiddenViewport()
    }

    private static func policyViewport(_ state: AppState, item: SoundItem, owner: UUID) -> SoundViewportContext {
        state.allowAutomaticPolicyFactsForCheck = true
        let context = state.waveformViewportContext(for: item)
        let rect = CGRect(x: 100, y: 10_000 - CGFloat(item.id) * 30, width: 96, height: 28)
        state.registerWaveformViewport(context, owner: owner)
        state.observeWaveformViewport(context, sample: SoundViewportSample(rect: rect, clipped: rect, attached: true,
                                      active: true, shown: true, hidden: false, blocked: false, clipCount: 2,
                                      tracksScroll: true, owner: owner))
        return context
    }

    private static func withdrawPolicyViewport(_ state: AppState, context: SoundViewportContext, owner: UUID) {
        state.observeWaveformViewport(context, sample: SoundViewportSample(rect: .zero, clipped: .zero, attached: false,
                                      active: false, shown: false, hidden: true, blocked: false, clipCount: 0,
                                      tracksScroll: false, owner: owner, retired: true))
    }

    private static func automaticIdle(_ state: AppState) async -> Bool {
        for _ in 0..<5000 {
            if !state.automaticWaveformInFlightForCheck && state.automaticWaveformPendingCountForCheck == 0 { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private static func automaticObstructionGate() async {
        let f = await Fixture(listingMetadata: metadata)
        f.state.showImporter = true
        _ = policyViewport(f.state, item: item, owner: UUID())
        check(await automaticIdle(f.state) && f.wire.reads == 0 && f.state.automaticViewportPinCountForCheck == 0,
              "automatic policy: known app presentation blocks even an old positive viewport report")
        f.state.showImporter = false
        check(await previewReady(f.state) && f.wire.reads == 1, "automatic policy: closing app presentation resumes current eligible work")
        await f.close()
    }

    private static func automaticCoalescing() async {
        let second = SoundItem(node: FSNode(id: 2, parentID: 10, name: "2", flags: 0xff, size: 4), displayName: "second")
        let f = await Fixture(listingMetadata: metadata, listed: [item, second])
        await f.state.showWaveform(item)
        check(await automaticIdle(f.state), "automatic policy: prior foreground cache preparation finishes")
        var publications = 0
        var delivered = false
        let owner = UUID()
        let subscription = f.state.objectWillChange.sink {
            publications += 1
            if !delivered {
                delivered = true
                _ = policyViewport(f.state, item: second, owner: owner)
            }
        }
        _ = policyViewport(f.state, item: item, owner: UUID())
        check(publications == 0, "automatic policy: native-style callback delivery performs no inline ObservableObject publication")
        let idle = await automaticIdle(f.state)
        check(idle && delivered && f.state.waveformSnapshot(for: second) != nil,
              "automatic policy: viewport receipt delivered during publication is not dropped")
        subscription.cancel()
        await f.close()
    }

    private static func automaticContextReset() async {
        let f = await Fixture(listingMetadata: metadata)
        f.wire.holdPCM()
        let owner = UUID()
        let context = policyViewport(f.state, item: item, owner: owner)
        check(await held(f.wire), "automatic policy: content reset fixture holds an actual GET")
        await f.state.invalidateWaveformContent(slots: [1])
        f.state.registerWaveformViewport(context, owner: UUID())
        let rect = CGRect(x: 0, y: 0, width: 96, height: 28)
        f.state.observeWaveformViewport(context, sample: SoundViewportSample(rect: rect, clipped: rect, attached: true,
                                       active: true, shown: true, hidden: false, blocked: false, clipCount: 2,
                                       tracksScroll: true, owner: owner))
        f.wire.resume()
        check(await automaticIdle(f.state) && f.wire.reads == 1, "automatic policy: old listing/content receipt cannot queue another read")
        check(f.state.automaticViewportPinCountForCheck == 0 && f.state.waveformSnapshot(for: item) == nil,
              "automatic policy: changed context clears pins and rejects late peaks")
        check(await f.cache.load(session: f.cacheSession, slot: 1, size: 4) == nil,
              "automatic policy: changed context rejects late cache publication")
        await f.close()
    }

    private static func automaticAnnouncedBudget() async {
        let f = await Fixture(listingMetadata: metadata)
        f.wire.announceSize(UInt32(16 * 1024 * 1024 + 1))
        _ = policyViewport(f.state, item: item, owner: UUID())
        check(await automaticIdle(f.state) && f.wire.reads == 1, "automatic policy: unexpected oversized GET init is attempted once")
        check(!f.wire.requests.contains([FileSub.get, 1]), "automatic policy: reader budget refuses data request after oversized init")
        check(f.state.waveformAvailability(for: item) == "waveform unavailable", "automatic policy: announced over-budget result stays neutral")
        await f.state.showWaveform(item, forceRefresh: true)
        check(f.state.lastError?.contains("16 MiB") == true && !f.wire.requests.contains([FileSub.get, 1]),
              "automatic policy: explicit refresh uses same reader budget and explains its refusal")
        await f.close()
    }

    private static func automaticQueueCancellation() async {
        let items = (100...139).map { slot in
            SoundItem(node: FSNode(id: UInt16(slot), parentID: 10, name: "\(slot)", flags: 0xff, size: 4), displayName: "sound")
        }
        let f = await Fixture(listingMetadata: metadata, listed: items)
        f.wire.holdPCM()
        var receipts: [(SoundViewportContext, UUID)] = []
        for item in items {
            let owner = UUID()
            receipts.append((policyViewport(f.state, item: item, owner: owner), owner))
        }
        check(await held(f.wire), "automatic policy: actual first GET reaches a held page")
        check(f.wire.reads == 1 && f.state.automaticWaveformPendingCountForCheck <= 32,
              "automatic policy: queue is bounded and one GET owns the device")
        for (context, owner) in receipts { withdrawPolicyViewport(f.state, context: context, owner: owner) }
        f.wire.resume()
        check(await automaticIdle(f.state), "automatic policy: in-flight GET drains after visibility cancellation")
        check(f.wire.reads == 1 && f.state.automaticViewportPinCountForCheck == 0,
              "automatic policy: offscreen rows start no next GET and retain no viewport pins")
        check(items.allSatisfy { f.state.waveformSnapshot(for: $0) == nil }, "automatic policy: cancelled old row cannot publish peaks")
        check(await f.cache.load(session: f.cacheSession, slot: 100, size: 4) == nil,
              "automatic policy: cancelled old row cannot store peaks")
        if let first = receipts.first {
            let rect = CGRect(x: 0, y: 0, width: 96, height: 28)
            f.state.observeWaveformViewport(first.0, sample: SoundViewportSample(rect: rect, clipped: rect, attached: true,
                                           active: true, shown: true, hidden: false, blocked: false, clipCount: 2,
                                           tracksScroll: true, owner: first.1))
            check(await automaticIdle(f.state) && f.wire.reads == 1, "automatic policy: retired owner cannot revive an old eligible row")
        }
        await f.close()
    }

    private static func automaticFailureMemo() async {
        let f = await Fixture(listingMetadata: metadata)
        f.state.noteError("unrelated user error")
        f.wire.failPCM()
        _ = policyViewport(f.state, item: item, owner: UUID())
        check(await automaticIdle(f.state) && f.wire.reads == 1, "automatic policy: failing read is attempted once")
        check(f.state.lastError == "unrelated user error" && f.state.waveformAvailability(for: item) == "waveform unavailable",
              "automatic policy: failure is neutral and preserves foreground error lifecycle")
        for _ in 0..<12 {
            let owner = UUID()
            let context = policyViewport(f.state, item: item, owner: owner)
            withdrawPolicyViewport(f.state, context: context, owner: owner)
        }
        _ = policyViewport(f.state, item: item, owner: UUID())
        check(await automaticIdle(f.state) && f.wire.reads == 1, "automatic policy: scroll churn does not retry a failed content context")
        check(f.state.automaticWaveformFailureCountForCheck == 1, "automatic policy: repeated receipts retain only one per-slot failure context")
        f.wire.failPCM(false)
        f.state.retryAutomaticWaveform(for: item)
        check(await previewReady(f.state) && f.wire.reads == 2, "automatic policy: explicit retry permits a new bounded attempt")
        f.state.forgetDevice()
        check(f.state.automaticWaveformFailureCountForCheck == 0 && f.state.automaticViewportPinCountForCheck == 0,
              "automatic policy: device reset clears memo and pins rather than accumulating contexts")
        await f.close()

        let oversized = SoundItem(node: FSNode(id: 1, parentID: 10, name: "large", flags: 0xff,
                                              size: UInt32(16 * 1024 * 1024 + 1)), displayName: "large")
        let large = await Fixture(listingMetadata: metadata, listed: [oversized])
        _ = policyViewport(large.state, item: oversized, owner: UUID())
        check(await automaticIdle(large.state) && large.wire.reads == 0, "automatic policy: over-budget listed row starts no GET")
        check(large.state.waveformAvailability(for: oversized) == "waveform unavailable", "automatic policy: over-budget miniature is neutrally unavailable")
        await large.state.showWaveform(oversized, forceRefresh: true)
        check(large.state.lastError?.contains("16 MiB") == true && large.wire.reads == 0,
              "automatic policy: explicit over-budget opening reports the app preview restriction")
        await large.close()
    }

    private static func automaticReductionHandoff() async {
        let second = SoundItem(node: FSNode(id: 2, parentID: 10, name: "2", flags: 0xff, size: 4), displayName: "second")
        let f = await Fixture(listingMetadata: metadata, listed: [item, second])
        let barrier = WaveformReductionBarrier()
        f.state.automaticReductionForCheck = { await barrier.pause() }
        _ = policyViewport(f.state, item: item, owner: UUID())
        _ = policyViewport(f.state, item: second, owner: UUID())
        for _ in 0..<2000 {
            if await barrier.waiting { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        check(await barrier.waiting && f.wire.reads == 1 && f.state.automaticPCMBufferCountForCheck == 1,
              "automatic policy: off-main reduction retains exactly one PCM buffer and blocks next GET")
        let download = Task { @MainActor in await f.state.download(item) }
        check(await waiting(f.state), "automatic policy: explicit foreground waits for current reduction/read ownership")
        await barrier.resume()
        if case .failure = await download.value { check(false, "automatic policy: foreground handoff succeeds") }
        check(await automaticIdle(f.state), "automatic policy: remaining visible work finishes after foreground")
        check(f.wire.getOrder == [1, 1, 2], "automatic policy: foreground GET precedes the next background GET")
        check(f.state.automaticPCMBufferCountForCheck == 0 && f.state.automaticMaximumPCMBufferCountForCheck == 1,
              "automatic policy: next read begins only after prior background buffer is freed")
        await f.close()
    }

    private static func automaticLargeViewport() async {
        let items = (100...179).map { slot in
            SoundItem(node: FSNode(id: UInt16(slot), parentID: 10, name: "\(slot)", flags: 0xff, size: 4), displayName: "sound")
        }
        let f = await Fixture(listingMetadata: metadata, listed: items)
        let record = WaveformPeakRecord(pcm: pcm, channels: 1, sampleRate: 46875)!
        let token = await f.cache.token(session: f.cacheSession)!
        for item in items { _ = await f.cache.store(record, slot: item.id, token: token, lease: WaveformCacheLease()) }
        var receipts: [(SoundViewportContext, UUID)] = []
        for item in items {
            let owner = UUID()
            receipts.append((policyViewport(f.state, item: item, owner: owner), owner))
        }
        let finished = await automaticIdle(f.state)
        check(finished && items.allSatisfy { f.state.waveformSnapshot(for: $0) != nil },
              "automatic policy: more than 64 eligible rows keep all accepted viewport records")
        let loads = f.state.waveformDiskLoadsForCheck
        for (index, item) in items.enumerated() { _ = policyViewport(f.state, item: item, owner: receipts[index].1) }
        check(await automaticIdle(f.state) && f.state.waveformDiskLoadsForCheck == loads && f.wire.reads == 0,
              "automatic policy: large viewport does not churn disk reads or PCM")
        for (context, owner) in receipts { withdrawPolicyViewport(f.state, context: context, owner: owner) }
        check(await automaticIdle(f.state) && f.state.automaticViewportPinCountForCheck == 0,
              "automatic policy: withdrawing actual receipts removes all viewport pins")
        await f.close()
    }

    private static func automaticHiddenViewport() async {
        let items = (100...179).map { slot in
            SoundItem(node: FSNode(id: UInt16(slot), parentID: 10, name: "\(slot)", flags: 0xff, size: 4), displayName: "sound")
        }
        let f = await Fixture(listingMetadata: metadata, listed: items)
        f.state.setSoundRange(SoundRange.all[1])
        let probe = SoundColumnProbe()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 3600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(state: f.state, suppressDeviceObservationForCheck: true,
                                                       columnProbeForCheck: probe))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 840, height: 3600)
        for _ in 0..<30 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(1)) }
        let intersections = probe.viewports.values.filter { $0.attached && !$0.clipped.isEmpty }
        check(intersections.count > 64, "automatic geometry: actual tall hidden production viewport contains more than 64 waveform intersections")
        for _ in 0..<2000 {
            if !f.state.waveformDiskLookupInFlightForCheck { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        check(!f.state.waveformDiskLookupInFlightForCheck, "automatic geometry: actual hidden viewport disk lookups settle")
        let loads = f.state.waveformDiskLoadsForCheck
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(1)) }
        check(f.state.waveformDiskLoadsForCheck == loads, "automatic geometry: tall hidden viewport does not churn disk lookups")
        check(!window.isVisible && !window.isKeyWindow && f.wire.reads == 0 && f.state.automaticViewportPinCountForCheck == 0,
              "automatic geometry: real hidden window with complete device/cache metadata starts zero GET and pins")
        window.close()
        await f.close()
    }

    private static func foregroundAdmission() async {
        for failure in [false, true] { await foregroundAdmission(metadataFails: failure) }
    }

    private static func foregroundAdmission(metadataFails: Bool) async {
        let f = await Fixture()
        f.state.noteError("earlier operation error")
        guard let background = f.state.beginWaveformRead() else {
            check(false, "foreground admission: idle accepts background reservation")
            await f.close()
            return
        }
        f.wire.holdPCM()
        let reading = Task { @MainActor in
            defer { f.state.endWaveformRead(background) }
            _ = try? await f.files.getWhole(fileID: 1, maximumBytes: 4)
        }
        check(await held(f.wire), "foreground admission: real bounded GET reaches held PCM")
        check(!f.state.deviceBusy && f.state.isEnabled(.downloadSelected) == false,
              "foreground admission: background reservation alone does not impersonate user work")
        f.state.selection = [1]
        check(f.state.isEnabled(.downloadSelected), "foreground admission: menu remains usable during background-only occupancy")
        f.state.requestAudition(item)
        f.state.beginInlineSlot(item)
        if let edit = f.state.inlineSlotEdit {
            f.state.inlineSlotEdit?.draft = "2"
            check(!(await f.state.commitInlineSlot(session: edit.session)) && f.state.inlineSlotEdit?.draft == "2",
                  "foreground admission: refused slot action retains draft without replay")
        } else { check(false, "foreground admission: slot draft opens without consuming background ownership") }
        f.state.inlineSlotEdit = nil
        f.state.beginInlineRename(item)
        if let edit = f.state.inlineRename {
            f.state.inlineRename?.draft = "renamed"
            check(!(await f.state.commitInlineRename(session: edit.session)) && f.state.inlineRename?.draft == "renamed",
                  "foreground admission: refused rename retains draft without replay")
        } else { check(false, "foreground admission: rename draft opens without consuming background ownership") }
        f.state.inlineRename = nil
        let pendingError = f.state.lastError
        let download = Task { @MainActor in await f.state.download(item) }
        check(await waiting(f.state), "foreground admission: explicit file action waits with a truthful status")
        check(f.state.lastError == pendingError, "foreground admission: background and pending ownership do not clear earlier errors")
        let refused = await f.state.download(item)
        if case .failure(let failure) = refused {
            check(failure.errorDescription?.contains("not queued") == true, "foreground admission: second action is explicitly refused, not queued")
        } else { check(false, "foreground admission: second action cannot execute") }
        check(f.wire.reads == 1, "foreground admission: no second GET starts during held background read")
        if metadataFails { f.wire.failMetadata() }
        f.wire.holdMetadata(fileID: 1)
        f.wire.resume()
        await reading.value
        check(await held(f.wire), "foreground admission: promoted foreground reaches its real metadata barrier")
        f.state.endWaveformRead(background)
        check(f.state.beginWaveformRead() == nil, "foreground admission: foreground owns device despite stale callback and before next background admission")
        f.wire.resume()
        switch await download.value {
        case .success(let result):
            check(!metadataFails && result.wav.count > pcm.count, "foreground admission: waiting file action retains its captured sound and returns WAV bytes")
        case .failure:
            check(metadataFails && f.state.lastError?.contains("earlier operation error") == false,
                  "foreground admission: stale background callback cannot finish foreground first-error lifecycle")
        }
        check(f.wire.reads == (metadataFails ? 1 : 2), "foreground admission: only successful foreground validation adds a second GET")
        check(!f.wire.requests.contains(where: { $0.first == FileSub.playback || $0.first == FileSub.move || $0 == [FileSub.metadata, 1] }),
              "foreground admission: refused preview, slot and rename never execute after read release")
        if let next = f.state.beginWaveformRead() {
            f.state.noteError("preserved after read")
            let error = f.state.lastError
            f.state.endWaveformRead(background)
            check(f.state.beginWaveformRead() == nil, "foreground admission: stale background completion cannot steal current reservation")
            f.state.endWaveformRead(next)
            check(f.state.lastError == error, "foreground admission: background release never finishes user error lifecycle")
        } else { check(false, "foreground admission: later background read may begin after foreground completion") }
        await f.close()
    }

    private static func fileAdmissionOwnership() async {
        for reset in [false, true] {
            let f = await Fixture()
            try? FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
            let source = f.root.appendingPathComponent("sound.wav")
            try? Data([1, 2, 3]).write(to: source)
            var opened = 0
            var closed = 0
            f.state.beginFileScopeForCheck = { _ in opened += 1; return true }
            f.state.endFileScopeForCheck = { _ in closed += 1 }
            guard let background = f.state.beginWaveformRead() else { await f.close(); continue }
            f.wire.holdPCM()
            let reading = Task { @MainActor in
                defer { f.state.endWaveformRead(background) }
                _ = try? await f.files.getWhole(fileID: 1, maximumBytes: 4)
            }
            check(await held(f.wire), "file ownership: real GET is held before file action")
            let upload = Task { @MainActor in await f.state.upload(urls: [source]) }
            check(await waiting(f.state), "file ownership: upload owns its source scope while waiting")
            check(opened == 1 && closed == 0 && FileManager.default.fileExists(atPath: source.path),
                  "file ownership: waiting source and acquired scope remain retained")
            var staged: [URL] = []
            let view = ContentView(state: f.state, suppressDeviceObservationForCheck: true)
            let provider = NSItemProvider()
            check(view.receiveDrop([provider], load: { _, done in done(source, nil) }, then: { urls in
                staged = urls
                return await f.state.upload(urls: urls)
            }), "file ownership: real drop receiver stages conflicting file action")
            for _ in 0..<1000 {
                if f.state.lastError?.contains("files kept at") == true { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            check(staged.count == 1 && staged.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                  "file ownership: refused drop keeps actual staged bytes")
            if let recovery = staged.first?.deletingLastPathComponent().deletingLastPathComponent() {
                check(f.state.lastError?.contains(recovery.path) == true, "file ownership: refusal names an existing recovery directory")
                try? FileManager.default.removeItem(at: recovery)
            }
            if reset { f.state.forgetDevice() } else { upload.cancel() }
            check(await upload.value == .notStarted, "file ownership: cancel/reset before admission never processes source")
            check(opened == closed && FileManager.default.fileExists(atPath: source.path),
                  "file ownership: cancellation balances scope callbacks and preserves picker original")
            f.wire.resume()
            await reading.value
            check(f.wire.reads == 1 && !f.state.deviceBusy, "file ownership: cancelled owner never replays after background release")
            await f.close()
        }
    }

    private static func processedDropOwnership() async {
        for connected in [true, false] {
            let f = await Fixture()
            try? FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
            let source = f.root.appendingPathComponent("invalid.wav")
            try? Data([1, 2, 3]).write(to: source)
            if !connected { f.state.forgetDevice() }
            var staged: [URL] = []
            var outcome: FileProcessing?
            let view = ContentView(state: f.state, suppressDeviceObservationForCheck: true)
            _ = view.receiveDrop([NSItemProvider()], load: { _, done in done(source, nil) }, then: { urls in
                staged = urls
                let result = await f.state.upload(urls: urls)
                outcome = result
                return result
            })
            for _ in 0..<1000 {
                if outcome != nil { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            check(outcome == (connected ? .processed : .notStarted), "file ownership: processed outcome includes reported per-file failure, not success")
            check(staged.count == 1 && staged.allSatisfy { FileManager.default.fileExists(atPath: $0.path) != connected },
                  "file ownership: staging is discarded only after actual processing, never for no device")
            check(FileManager.default.fileExists(atPath: source.path), "file ownership: original source is never consumed")
            if !connected, let recovery = staged.first?.deletingLastPathComponent().deletingLastPathComponent() {
                check(f.state.lastError?.contains(recovery.path) == true, "file ownership: no-device refusal retains a real recovery directory")
                try? FileManager.default.removeItem(at: recovery)
            }
            await f.close()
        }
    }

    private static func folderAdmissionOwnership() async {
        let f = await Fixture()
        let folder = f.root.appendingPathComponent("output")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var opened = 0
        var closed = 0
        f.state.beginFileScopeForCheck = { _ in opened += 1; return true }
        f.state.endFileScopeForCheck = { _ in closed += 1 }
        guard let background = f.state.beginWaveformRead() else { await f.close(); return }
        f.wire.holdPCM()
        let reading = Task { @MainActor in
            defer { f.state.endWaveformRead(background) }
            _ = try? await f.files.getWhole(fileID: 1, maximumBytes: 4)
        }
        check(await held(f.wire), "folder ownership: real GET is held")
        let requests = f.wire.requests
        let backup = Task { @MainActor in await f.state.backupToFolder(folder) }
        check(await waiting(f.state) && opened == 1 && closed == 0, "folder ownership: selected folder scope spans admission wait")
        backup.cancel()
        await backup.value
        check(opened == closed && FileManager.default.fileExists(atPath: folder.path), "folder ownership: cancellation balances scope and leaves chosen folder intact")
        f.wire.resume()
        await reading.value
        check(f.wire.requests == requests, "folder ownership: cancelled backup does not replay protocol work")
        check((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true,
              "folder ownership: cancelled action writes no backup")
        await f.close()
    }

    private static func changedForegroundTarget() async {
        for reset in [false, true] { await changedForegroundTarget(resetAfterPromotion: reset) }
        await changedForegroundTarget(resetAfterPromotion: false, cancelAfterPromotion: true)
    }

    private static func changedForegroundTarget(resetAfterPromotion: Bool, cancelAfterPromotion: Bool = false) async {
        let f = await Fixture()
        guard let background = f.state.beginWaveformRead() else { await f.close(); return }
        f.wire.holdPCM()
        let download = Task { @MainActor in await f.state.download(item) }
        let reading = Task { @MainActor in
            defer {
                f.state.endWaveformRead(background)
                if resetAfterPromotion { f.state.forgetDevice() }
                if cancelAfterPromotion { download.cancel() }
            }
            _ = try? await f.files.getWhole(fileID: 1, maximumBytes: 4)
        }
        check(await held(f.wire), "foreground target: real GET is held")
        let requests = f.wire.requests
        check(await waiting(f.state), "foreground target: captured node waits")
        if !resetAfterPromotion && !cancelAfterPromotion {
            f.state.sounds = [SoundItem(node: FSNode(id: 1, parentID: 10, name: "replacement", flags: 0xff, size: 8), displayName: "replacement")]
        }
        f.wire.resume()
        await reading.value
        if case .failure(let failure) = await download.value {
            if cancelAfterPromotion {
                check(failure.errorDescription == "file action not started: cancelled or device changed",
                      "foreground target: post-promotion cancellation is refused by the admission guard")
            } else {
                check(failure.errorDescription?.contains("changed") == true, "foreground target: changed node refuses before any foreground read")
            }
        } else { check(false, "foreground target: changed or cancelled target cannot execute") }
        check(f.wire.requests == requests && f.wire.reads == 1 && !f.state.deviceBusy,
              "foreground target: stale or cancelled action releases promoted admission without foreground MIDI")
        if let next = f.state.beginWaveformRead() {
            check(true, "foreground target: another owner can reserve device after the refused handoff")
            f.state.endWaveformRead(next)
        } else { check(false, "foreground target: refused handoff does not leak admission") }
        await f.close()
    }

    private static func waiting(_ state: AppState) async -> Bool {
        for _ in 0..<1000 {
            if state.progressText?.contains("waiting for current audio read") == true { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private static func invalidation() async {
        for (disconnect, metadataHeld) in [(false, false), (false, true), (true, false), (true, true)] {
            let f = await Fixture()
            if metadataHeld { f.wire.holdMetadata() } else { f.wire.holdPCM() }
            let pending = Task { @MainActor in await f.state.showWaveform(item, forceRefresh: true) }
            check(await held(f.wire), "waveform app: actual metadata or PCM request reaches late-result barrier")
            if disconnect { f.state.forgetDevice() }
            else { await f.state.invalidateWaveformContent(slots: [1]) }
            f.wire.resume()
            await pending.value
            check(f.state.waveformShown?.record == nil && f.state.waveformRows.snapshot(slot: 1, size: 4) == nil,
                  "waveform app: mutation or device reset prevents late preview resurrection")
            let stored = await f.cache.load(session: f.cacheSession, slot: 1, size: 4)
            check(stored == nil && f.state.waveformSnapshot(for: item) == nil,
                  "waveform app: cancelled old result cannot restore persistent peaks or confirmation")
            if metadataHeld { check(f.wire.reads == 0, "waveform app: stale metadata callback cannot start a later PCM command") }
            await f.close()
        }
    }

    private static func held(_ wire: WaveformWire) async -> Bool {
        for _ in 0..<2000 {
            if wire.hasHeldResponse { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private final class WaveformWire: MIDIWire, @unchecked Sendable {
        enum MoveFault { case refused, timeout, landedTimeout }
        private enum Hold { case metadata, pcm, move, list }
        private var heldList: Int?
        func holdList(at attempt: Int) { lock.withLock { heldList = attempt } }
        private var faults: [Int: MoveFault] = [:]
        private var moves: [(UInt16, UInt16)] = []
        private var unsafe = false
        private var listCount = 0
        private var failedLists: Set<Int> = []
        private var heldMove: Int?
        func moveFaults(_ faults: [Int: MoveFault]) { lock.withLock { self.faults = faults } }
        func failLists(_ attempts: Set<Int>) { lock.withLock { failedLists = attempts } }
        func holdMove(at attempt: Int) { lock.withLock { heldMove = attempt } }
        var moveOrder: [(UInt16, UInt16)] { lock.withLock { moves } }
        var safeMoves: Bool { lock.withLock { !unsafe } }
        private let lock = NSLock()
        private var handler: (@Sendable ([UInt8]) -> Void)?
        private var metadata: [String: JSONValue] = [:]
        private var failed = false
        private var hold: Hold?
        private var holdFileID: UInt16?
        private var pending: [UInt8]?
        private var count = 0
        private var commands: [[UInt8]] = []
        private var getIDs: [UInt16] = []
        private var pcmFailed = false
        private var listedSlots: [UInt16]?
        func setListedSlots(_ slots: [UInt16]) { lock.withLock { listedSlots = slots } }
        private var announcedSize: UInt32?
        func announceSize(_ size: UInt32?) { lock.withLock { announcedSize = size } }
        var getOrder: [UInt16] { lock.withLock { getIDs } }
        func failPCM(_ value: Bool = true) { lock.withLock { pcmFailed = value } }
        var requests: [[UInt8]] { lock.withLock { commands } }
        var reads: Int { lock.withLock { count } }
        var hasHeldResponse: Bool { lock.withLock { pending != nil } }

        func setMetadata(_ value: [String: JSONValue]) { lock.withLock { metadata = value; failed = false } }
        func failMetadata() { lock.withLock { failed = true } }
        func holdMetadata(fileID: UInt16? = nil) { lock.withLock { hold = .metadata; holdFileID = fileID } }
        func holdPCM() { lock.withLock { hold = .pcm; holdFileID = nil } }
        func setMessageHandler(_ handler: (@Sendable ([UInt8]) -> Void)?) { lock.withLock { self.handler = handler } }

        func resume() {
            let delivery = lock.withLock { () -> ([UInt8]?, (@Sendable ([UInt8]) -> Void)?) in
                let value = pending
                pending = nil
                return (value, handler)
            }
            if let value = delivery.0 { delivery.1?(value) }
        }

        func send(_ bytes: [UInt8]) async throws {
            guard let request = TEFrame.parse(bytes), request.payload.count >= 2 else { throw WireError.noDevice }
            let response = try lock.withLock { () throws -> ([UInt8]?, (@Sendable ([UInt8]) -> Void)?) in
                commands.append(Array(request.payload.prefix(2)))
                var payload: [UInt8] = []
                var status: UInt8 = 0
                var kind: Hold?
                var metadataID: UInt16?
                switch (request.payload[0], request.payload[1]) {
                case (FileSub.initialize, _):
                    payload.append(0)
                    appendU32(1024, to: &payload)
                case (FileSub.metadata, 1):
                    let json = readZString(request.payload, from: 4)
                    guard let values = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                        throw FileServiceError.unserializableMetadata
                    }
                    metadata.merge(values.compactMapValues { JSONValue(any: $0) }, uniquingKeysWith: { _, new in new })
                case (FileSub.metadata, 2):
                    kind = .metadata
                    let fileID = readU16(request.payload, 2)
                    metadataID = fileID
                    if failed && fileID == 1 { status = 3 }
                    else {
                        let values = fileID == 10 ? ["max_capacity": JSONValue.int(1000), "free_space_in_bytes": .int(500)] : metadata
                        appendU16(0, to: &payload)
                        payload += try JSONSerialization.data(withJSONObject: values.mapValues(\.anyValue)).map { $0 }
                        payload.append(0)
                    }
                case (FileSub.list, _):
                    let page = readU16(request.payload, 1)
                    let parent = readU16(request.payload, 3)
                    if parent == 10, page == 0 {
                        listCount += 1
                        if heldList == listCount { kind = .list; hold = .list }
                        if failedLists.contains(listCount) { status = 3; break }
                    }
                    appendU16(page, to: &payload)
                    if page == 0, parent == 0 || parent == 10 {
                        for id in parent == 0 ? [UInt16(10)] : (listedSlots ?? [1]) {
                            appendU16(id, to: &payload)
                            payload.append(parent == 0 ? FileTypeFlag.directory : (listedSlots == nil ? 0xff : 29))
                            appendU32(parent == 0 ? 0 : UInt32(pcm.count), to: &payload)
                            payload += Array((parent == 0 ? "sounds" : String(id)).utf8) + [0]
                        }
                    }
                case (FileSub.move, _):
                    let from = readU16(request.payload, 1), to = readU16(request.payload, 5)
                    moves.append((from, to))
                    if heldMove == moves.count { kind = .move; hold = .move }
                    let fault = faults[moves.count]
                    guard var slots = listedSlots, slots.contains(from), !slots.contains(to),
                          readU16(request.payload, 3) == 10, (1...999).contains(from), (1...999).contains(to) else {
                        unsafe = true
                        status = 3
                        break
                    }
                    if fault == .refused { status = 3; break }
                    if fault == .timeout { throw SessionError.timeout(command: request.command, requestID: request.requestID) }
                    slots.removeAll { $0 == from }
                    slots.append(to)
                    listedSlots = slots
                    if fault == .landedTimeout {
                        if kind == .move { status = 3 }
                        else { throw SessionError.timeout(command: request.command, requestID: request.requestID) }
                    }
                    payload = Array(request.payload.dropFirst())
                case (FileSub.get, 0):
                    count += 1
                    let id = readU16(request.payload, 2)
                    getIDs.append(id)
                    appendU16(id, to: &payload)
                    payload.append(FileTypeFlag.file | FileCapability.read)
                    appendU32(announcedSize ?? UInt32(pcm.count), to: &payload)
                    payload += Array("sound".utf8) + [0]
                case (FileSub.get, 1):
                    kind = .pcm
                    if pcmFailed { status = 3 }
                    else {
                        appendU16(0, to: &payload)
                        payload += pcm
                    }
                default: throw WireError.noDevice
                }
                let id = request.requestID
                var reply: [UInt8] = [0xf0, 0x00, 0x20, 0x76, bytes[4], 0x40,
                                      0x20 | UInt8((id >> 7) & 31), UInt8(id & 127), request.command, status]
                reply += SevenBitCoding.pack(payload) + [0xf7]
                if let kind, hold == kind, holdFileID == nil || holdFileID == metadataID {
                    hold = nil
                    pending = reply
                    return (nil, handler)
                }
                return (reply, handler)
            }
            if let value = response.0 { response.1?(value) }
        }
    }
}
#endif
