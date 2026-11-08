import Foundation
import KokokoCore
import KokokoLibrary

extension KokokoCoreChecks {
    static func inlineMetadataChecks() async {
        inlineMetadataStateChecks()
        metadataRebaseChecks()
        await metadataDraftSaveChecks()
    }

    private static func metadataRebaseChecks() {
        var form = MetadataEditForm(metadata: ["sound.bpm": .int(120), "sound.pan": .int(0)])
        form.text["sound.bpm"] = " 0133 "
        form.text["sound.pan"] = "4"
        form.rebase(on: ["sound.bpm": .double(133.0), "sound.pan": .int(0), "sound.playmode": .string("loop")])
        eq(form.text["sound.bpm"], " 0133 ", "metadata draft: confirmed values keep exact user formatting")
        eq(form.text["sound.pan"], "4", "metadata draft: unconfirmed values keep their draft")
        eq(form.changes, ["sound.pan": .int(4)], "metadata draft: confirmed and untouched keys are not resent")
        eq(form.text["sound.playmode"], "loop", "metadata draft: untouched fields follow fresh metadata")
        form.rebase(on: ["sound.bpm": .int(133), "sound.pan": .int(4), "sound.playmode": .string("loop")])
        eq(form.changes, [:], "metadata draft: a later readback clears only confirmed intent")
        eq(form.text["sound.bpm"], " 0133 ", "metadata draft: repeated rebase keeps confirmed user formatting")
        var typed = MetadataEditForm(metadata: ["sound.bpm": .int(120)])
        typed.text["sound.bpm"] = "133"
        typed.rebase(on: ["sound.bpm": .string("133")])
        eq(typed.changes, ["sound.bpm": .int(133)], "metadata draft: matching text with a wrong JSON type is still unresolved")
    }

    private static func inlineMetadataStateChecks() {
        var edit = InlineMetadataEdit(id: 12, name: "kick", generation: 4)
        guard let loading = edit.request else {
            check(false, "metadata editor: load request exists")
            return
        }
        check(edit.canCancel && !edit.canSubmit, "metadata editor: an initial GET is cancellable, not saveable")
        check(edit.blocksFilterChange, "metadata editor: an in-flight inline load protects range and search changes")
        check(!edit.loaded(request: UUID(), metadata: [:], error: nil), "metadata editor: unrelated load cannot replace the editor")
        check(edit.loaded(request: loading, metadata: ["sound.bpm": .int(120)], error: nil), "metadata editor: current load installs a form")
        check(!edit.loaded(request: loading, metadata: [:], error: nil), "metadata editor: duplicate load completion is ignored")
        check(edit.isCurrent(selection: [12], visible: [12], tab: .sounds, generation: 4), "metadata editor: current selected visible sound")
        let contexts: [(Set<UInt16>, Set<UInt16>, HeaderTab, Int)] = [
            ([13], [12, 13], .sounds, 4), ([12], [], .sounds, 4), ([12], [12], .projects, 4), ([12], [12], .sounds, 5)
        ]
        for (selection, visible, tab, generation) in contexts {
            check(
                !edit.isCurrent(selection: selection, visible: visible, tab: tab, generation: generation),
                "metadata editor: selection, visibility, tab and device invalidate intent")
        }
        eq(edit.prepareSave(), .unchanged, "metadata editor: unchanged form needs no SET")
        check(!edit.blocksFilterChange, "metadata editor: unchanged ready fields can close without a write")
        edit.form?.text["sound.bpm"] = "invalid"
        check(!edit.canSubmit, "metadata editor: invalid fields cannot submit")
        check(edit.blocksFilterChange, "metadata editor: invalid dirty fields are not discarded by filtering")
        eq(edit.prepareSave(), .invalid, "metadata editor: invalid form remains editable")
        edit.form?.text["sound.bpm"] = "133"
        guard case .write(let request, let form, let refresh) = edit.prepareSave() else {
            check(false, "metadata editor: changed form prepares a write")
            return
        }
        check(!refresh && !edit.canCancel && !edit.canSubmit, "metadata editor: an issued save cannot be cancelled by hiding it")
        check(edit.blocksFilterChange, "metadata editor: saving fields protects range and search changes")
        eq(edit.prepareSave(), .waiting, "metadata editor: duplicate Save is suppressed")
        let failure = MetadataDraftSaveResult.failed(form: form, message: "readback failed", needsReadback: true)
        check(edit.finished(request: request, result: failure), "metadata editor: current failure is accepted once")
        eq(edit.form?.text["sound.bpm"], "133", "metadata editor: failure keeps the user draft")
        eq(edit.note, "readback failed", "metadata editor: failure remains readable")
        check(edit.needsReadback && edit.canCancel, "metadata editor: failed readback requires GET before retry")
        var unresolved = edit
        unresolved.form = MetadataEditForm(metadata: ["sound.bpm": .int(133)])
        check(unresolved.blocksFilterChange, "metadata editor: unresolved write protects navigation even when fields appear unchanged")
        guard case .write(let retry, _, let needsReadback) = edit.prepareSave() else {
            check(false, "metadata editor: retry prepares a fresh operation")
            return
        }
        check(needsReadback && retry != request, "metadata editor: retry has a distinct request token")
        check(!edit.finished(request: request, result: .saved(form)), "metadata editor: old completion cannot finish the newer request")
        check(edit.finished(request: retry, result: .saved(form)), "metadata editor: current save completion is accepted")
        edit.form?.text["sound.bpm"] = "140"
        check(!edit.finished(request: retry, result: .saved(form)), "metadata editor: duplicate completion cannot discard a later draft")
        eq(edit.form?.text["sound.bpm"], "140", "metadata editor: later draft survives a stale completion")
        check(
            edit.session != InlineMetadataEdit(id: 12, name: "kick", generation: 4).session,
            "metadata editor: reopening the same slot creates a different intent")
        var replacement = InlineMetadataEdit(id: 12, name: "new sound", generation: 4)
        check(
            !replacement.loaded(request: loading, metadata: ["sound.bpm": .int(120)], error: nil),
            "metadata editor: a replacement intent at the same slot rejects the old load")
        var loadFailure = InlineMetadataEdit(id: 12, name: "kick", generation: 4)
        guard let failedRequest = loadFailure.request else {
            check(false, "metadata editor: initial request exists")
            return
        }
        check(loadFailure.loaded(request: failedRequest, metadata: nil, error: "GET failed"), "metadata editor: load failure stays attached")
        check(!loadFailure.blocksFilterChange, "metadata editor: a failed read with no draft can close without writing")
        check(
            loadFailure.form == nil && loadFailure.note == "GET failed" && loadFailure.canCancel,
            "metadata editor: load failure is visible and cancellable without a write")
        guard let loadRetry = loadFailure.beginLoad() else {
            check(false, "metadata editor: failed load can retry")
            return
        }
        check(loadRetry != failedRequest && loadFailure.beginLoad() == nil, "metadata editor: duplicate load retry is suppressed")
        check(!loadFailure.loaded(request: failedRequest, metadata: [:], error: nil), "metadata editor: previous load cannot finish the retry")
        check(loadFailure.loaded(request: loadRetry, metadata: [:], error: nil), "metadata editor: current load retry installs its result")
    }

    private static func metadataDraftSaveChecks() async {
        let original: [String: JSONValue] = ["sound.bpm": .int(120), "sound.pan": .int(0), "name": .string("kick")]
        var form = MetadataEditForm(metadata: original)
        let unchanged = MetadataDraftFixture(metadata: original)
        _ = await saveMetadataDraftSteps(
            form: form, refreshBeforeWrite: false,
            set: { try await unchanged.set($0) }, get: { try await unchanged.get() },
            isCurrent: { await unchanged.current })
        eq(await unchanged.writes, [], "metadata save draft: unchanged form sends no SET")
        eq(await unchanged.reads, 0, "metadata save draft: unchanged known form needs no GET")
        form.text["sound.bpm"] = " 0133 "
        let unreadable = MetadataDraftFixture(metadata: original, failReads: true)
        let noWrite = await saveMetadataDraftSteps(
            form: form, refreshBeforeWrite: true,
            set: { try await unreadable.set($0) }, get: { try await unreadable.get() },
            isCurrent: { await unreadable.current })
        if case .failed(let kept, _, let needsReadback) = noWrite {
            eq(kept.text["sound.bpm"], " 0133 ", "metadata save draft: failed refresh retains exact draft")
            check(needsReadback, "metadata save draft: failed refresh remains unresolved")
        } else {
            check(false, "metadata save draft: failed refresh must fail")
        }
        eq(await unreadable.writes, [], "metadata save draft: failed refresh must not send SET")

        let alreadyThere = MetadataDraftFixture(metadata: ["sound.bpm": .int(133), "sound.pan": .int(0)])
        let confirmed = await saveMetadataDraftSteps(
            form: form, refreshBeforeWrite: true,
            set: { try await alreadyThere.set($0) }, get: { try await alreadyThere.get() },
            isCurrent: { await alreadyThere.current })
        if case .saved(let kept) = confirmed {
            eq(kept.text["sound.bpm"], " 0133 ", "metadata save draft: confirmed retry preserves formatting")
        } else {
            check(false, "metadata save draft: fresh readback can confirm an earlier write")
        }
        eq(await alreadyThere.writes, [], "metadata save draft: confirmed earlier write is not replayed")

        form.text["sound.pan"] = "4"
        let partial = MetadataDraftFixture(metadata: original, loseReply: true, applyOnly: ["sound.bpm"])
        let lost = await saveMetadataDraftSteps(
            form: form, refreshBeforeWrite: false,
            set: { try await partial.set($0) }, get: { try await partial.get() },
            isCurrent: { await partial.current })
        if case .failed(let kept, _, let needsReadback) = lost {
            check(!needsReadback, "metadata save draft: successful readback resolves the baseline")
            eq(kept.text["sound.bpm"], " 0133 ", "metadata save draft: lost reply does not discard confirmed raw draft")
            eq(kept.changes, ["sound.pan": .int(4)], "metadata save draft: partial write leaves only unresolved keys dirty")
            let retry = MetadataDraftFixture(metadata: ["sound.bpm": .int(133), "sound.pan": .int(0), "name": .string("kick")])
            _ = await saveMetadataDraftSteps(
                form: kept, refreshBeforeWrite: needsReadback,
                set: { try await retry.set($0) }, get: { try await retry.get() },
                isCurrent: { await retry.current })
            eq(await retry.writes, [["sound.pan": .int(4)]], "metadata save draft: retry writes neither confirmed nor untouched keys")
        } else {
            check(false, "metadata save draft: lost reply remains an explicit failure")
        }

        var reverting = MetadataEditForm(metadata: original)
        reverting.text["sound.bpm"] = "133"
        let unconfirmed = MetadataDraftFixture(metadata: original, failReads: true)
        let unknown = await saveMetadataDraftSteps(
            form: reverting, refreshBeforeWrite: false,
            set: { try await unconfirmed.set($0) }, get: { try await unconfirmed.get() },
            isCurrent: { await unconfirmed.current })
        if case .failed(var kept, _, let needsReadback) = unknown {
            check(needsReadback, "metadata save draft: missing readback keeps attempted keys uncertain")
            kept.text["sound.bpm"] = "120"
            let restoring = MetadataDraftFixture(metadata: ["sound.bpm": .int(133), "sound.pan": .int(0)])
            _ = await saveMetadataDraftSteps(
                form: kept, refreshBeforeWrite: true,
                set: { try await restoring.set($0) }, get: { try await restoring.get() },
                isCurrent: { await restoring.current })
            eq(
                await restoring.writes, [["sound.bpm": .int(120)]],
                "metadata save draft: returning to the old baseline after an unknown write preserves that new intent")
        } else {
            check(false, "metadata save draft: failed readback must preserve uncertain intent")
        }

        var missingKey = MetadataEditForm(metadata: [:])
        missingKey.text["sound.rootnote"] = "60"
        let created = MetadataDraftFixture(metadata: [:], failReads: true)
        let createdUnknown = await saveMetadataDraftSteps(
            form: missingKey, refreshBeforeWrite: false,
            set: { try await created.set($0) }, get: { try await created.get() },
            isCurrent: { await created.current })
        if case .failed(var kept, _, _) = createdUnknown {
            kept.text["sound.rootnote"] = ""
            let existingKey = MetadataDraftFixture(metadata: ["sound.rootnote": .int(60)])
            let cleared = await saveMetadataDraftSteps(
                form: kept, refreshBeforeWrite: true,
                set: { try await existingKey.set($0) }, get: { try await existingKey.get() },
                isCurrent: { await existingKey.current })
            if case .failed(let rebased, _, let needsReadback) = cleared {
                eq(rebased.text["sound.rootnote"], "", "metadata save draft: clearing a newly stored key keeps the exact draft")
                eq(rebased.error(for: "sound.rootnote"), "a value is required", "metadata save draft: missing-key intent is revalidated after readback")
                check(!needsReadback, "metadata save draft: fresh baseline is kept even when its draft is now invalid")
            } else {
                check(false, "metadata save draft: an empty draft cannot claim to undo an already stored key")
            }
            eq(await existingKey.writes, [], "metadata save draft: invalid rebased draft sends no SET")
        } else {
            check(false, "metadata save draft: creating a key with failed readback remains uncertain")
        }

        let stale = MetadataDraftFixture(metadata: original, invalidateOnRead: true)
        let staleResult = await saveMetadataDraftSteps(
            form: form, refreshBeforeWrite: true,
            set: { try await stale.set($0) }, get: { try await stale.get() },
            isCurrent: { await stale.current })
        eq(staleResult, .stale, "metadata save draft: changed context after preflight rejects stale intent")
        eq(await stale.writes, [], "metadata save draft: stale preflight cannot dispatch SET")
        let issued = MetadataDraftFixture(metadata: original, invalidateOnSet: true)
        let issuedResult = await saveMetadataDraftSteps(
            form: form, refreshBeforeWrite: false,
            set: { try await issued.set($0) }, get: { try await issued.get() },
            isCurrent: { await issued.current })
        if case .saved = issuedResult {} else { check(false, "metadata save draft: hiding after SET cannot cancel its readback outcome") }
        eq(await issued.writes.count, 1, "metadata save draft: issued SET runs once despite later context invalidation")
        eq(await issued.reads, 1, "metadata save draft: issued SET is read back even after the editor hides")
        form.text["sound.bpm"] = "invalid"
        let invalid = MetadataDraftFixture(metadata: original)
        eq(
            await saveMetadataDraftSteps(
                form: form, refreshBeforeWrite: true,
                set: { try await invalid.set($0) }, get: { try await invalid.get() },
                isCurrent: { await invalid.current }), .invalid,
            "metadata save draft: invalid form never enters a write")
        eq(await invalid.writes, [], "metadata save draft: invalid input sends no SET")
        eq(await invalid.reads, 0, "metadata save draft: invalid input does not trigger retry GET")
    }
}

private actor MetadataDraftFixture {
    var metadata: [String: JSONValue]
    let failReads: Bool
    let loseReply: Bool
    let applyOnly: Set<String>?
    let invalidateOnRead: Bool
    let invalidateOnSet: Bool
    var current = true
    var writes: [[String: JSONValue]] = []
    var reads = 0

    init(
        metadata: [String: JSONValue], failReads: Bool = false, loseReply: Bool = false,
        applyOnly: Set<String>? = nil, invalidateOnRead: Bool = false, invalidateOnSet: Bool = false
    ) {
        self.metadata = metadata
        self.failReads = failReads
        self.loseReply = loseReply
        self.applyOnly = applyOnly
        self.invalidateOnRead = invalidateOnRead
        self.invalidateOnSet = invalidateOnSet
    }

    func set(_ changes: [String: JSONValue]) throws {
        writes.append(changes)
        if invalidateOnSet { current = false }
        for (key, value) in changes where applyOnly?.contains(key) != false { metadata[key] = value }
        if loseReply { throw CocoaError(.fileWriteUnknown) }
    }

    func get() throws -> [String: JSONValue] {
        reads += 1
        if invalidateOnRead { current = false }
        if failReads { throw CocoaError(.fileReadUnknown) }
        return metadata
    }
}
