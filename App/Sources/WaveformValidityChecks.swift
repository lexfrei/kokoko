#if os(macOS) && DEBUG
import AppKit
import Foundation
import KokokoCore
import KokokoLibrary
@testable import KokokoMIDI

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
        await invalidation()
        print(failures == 0 ? "waveform validity: all checks passed" : "waveform validity: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    private static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "ok  " : "FAIL") \(message)")
        if !condition { failures += 1 }
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kokoko-waveform-check-" + UUID().uuidString)
        let wire = WaveformWire()
        let session: SysExSession
        let files: DeviceFileService
        let cache: WaveformCacheStore
        let state: AppState
        let cacheSession: UUID

        init(listingMetadata: [String: JSONValue]? = nil) async {
            session = SysExSession(wire: wire, identityCode: 0x10)
            files = DeviceFileService(session: session)
            cache = WaveformCacheStore(root: root)
            cacheSession = await cache.configure(model: "fixture", serial: "fixture")
            state = AppState(listedSounds: [item], waveformCache: cache,
                             files: files, cacheSession: cacheSession,
                             listingMetadata: listingMetadata.map { [item.id: $0] } ?? [:], soundRootID: 10)
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
        private enum Hold { case metadata, pcm }
        private let lock = NSLock()
        private var handler: (@Sendable ([UInt8]) -> Void)?
        private var metadata: [String: JSONValue] = [:]
        private var failed = false
        private var hold: Hold?
        private var holdFileID: UInt16?
        private var pending: [UInt8]?
        private var count = 0
        private var commands: [[UInt8]] = []
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
                    appendU16(page, to: &payload)
                    if page == 0, parent == 0 || parent == 10 {
                        appendU16(parent == 0 ? 10 : 1, to: &payload)
                        payload.append(parent == 0 ? FileTypeFlag.directory : 0xff)
                        appendU32(parent == 0 ? 0 : UInt32(pcm.count), to: &payload)
                        payload += Array((parent == 0 ? "sounds" : "1").utf8) + [0]
                    }
                case (FileSub.get, 0):
                    count += 1
                    appendU16(1, to: &payload)
                    payload.append(FileTypeFlag.file | FileCapability.read)
                    appendU32(UInt32(pcm.count), to: &payload)
                    payload += Array("sound".utf8) + [0]
                case (FileSub.get, 1):
                    kind = .pcm
                    appendU16(0, to: &payload)
                    payload += pcm
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
