import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func inlineSlotChecks() {
        let initial = InlineSlotEdit(id: 12, generation: 4)
        check(
            initial.session != InlineSlotEdit(id: 12, generation: 4).session,
            "inline slot: reopening cannot receive an old completion")
        eq(initial.draft, "12", "inline slot: starts at the current slot")
        check(initial.canCancel, "inline slot: an unsent draft can be cancelled")
        check(!initial.blocksFilterChange, "inline slot: unchanged source can close for range or search navigation")
        check(initial.isCurrent(selection: [12], visible: [12], tab: .sounds, generation: 4), "inline slot: current row context")
        let contexts: [(Set<UInt16>, Set<UInt16>, HeaderTab, Int)] = [
            ([13], [12, 13], .sounds, 4), ([12], [], .sounds, 4), ([12], [12], .projects, 4), ([12], [12], .sounds, 5)
        ]
        for (selection, visible, tab, generation) in contexts {
            check(
                !initial.isCurrent(selection: selection, visible: visible, tab: tab, generation: generation),
                "inline slot: changed selection, visibility, tab or device invalidates the edit")
        }
        for text in ["", " ", "0", "-1", "+12", "1.5", "12x", "1000", "1001", "65000", "65535", "65536", "１２", " 20", "20\n"] {
            var edit = initial
            edit.draft = text
            eq(edit.prepare(), .invalid, "inline slot: only ASCII digits in sound slots 1 through 999 are accepted")
            check(edit.error != nil && !edit.submitting && edit.canCancel, "inline slot: invalid draft stays editable")
            check(edit.blocksFilterChange, "inline slot: invalid target text protects range and search changes")
        }
        for source: UInt16 in [0, 1000, 1001, 65000] {
            var edit = InlineSlotEdit(id: source, generation: 4)
            edit.draft = "20"
            eq(edit.prepare(), .invalid, "inline slot: an out-of-domain source cannot prepare MOVE")
            check(edit.error != nil && !edit.submitting, "inline slot: invalid source has a visible refusal")
        }
        var unchanged = initial
        eq(unchanged.prepare(), .unchanged, "inline slot: same slot sends no MOVE")
        unchanged.draft = "0012"
        eq(unchanged.prepare(), .unchanged, "inline slot: leading zeros do not force a move")
        check(!unchanged.blocksFilterChange, "inline slot: equivalent padded input can close without a write")
        var upper = initial
        upper.draft = "999"
        eq(upper.prepare(), .write(from: 12, to: 999), "inline slot: last sound slot is accepted")
        var edit = initial
        edit.draft = "0020"
        eq(edit.prepare(), .write(from: 12, to: 20), "inline slot: Return prepares a free-slot request")
        check(edit.submitting && !edit.canCancel, "inline slot: Escape cannot undo an in-flight MOVE")
        var inFlight = edit
        inFlight.draft = initial.draft
        check(inFlight.blocksFilterChange, "inline slot: an in-flight move protects navigation even with original input")
        eq(edit.prepare(), .waiting, "inline slot: duplicate Return is suppressed")
        check(!edit.finish(at: 12, error: "slot 20 is occupied", listed: [12, 20]), "inline slot: refusal keeps the editor open")
        eq(edit.draft, "0020", "inline slot: refusal preserves the exact draft")
        eq(edit.error, "slot 20 is occupied", "inline slot: refusal remains readable")
        eq(edit.prepare(), .write(from: 12, to: 20), "inline slot: retry is explicit")
        check(!edit.finish(at: 20, error: "reply was lost", listed: [20]), "inline slot: lost reply remains visible")
        eq(edit.rowID, 20, "inline slot: landed move follows the sound to its new row")
        eq(edit.slot, 20, "inline slot: landed move changes the retry source identity")
        eq(edit.draft, "0020", "inline slot: landed move keeps the original draft")
        eq(edit.prepare(), .unchanged, "inline slot: retrying the landed target never moves the old occupant")
        edit.draft = "30"
        eq(edit.prepare(), .write(from: 20, to: 30), "inline slot: later edit uses the reconciled source")
        check(edit.finish(at: 30, error: nil, listed: [30]), "inline slot: confirmed refreshed move closes the editor")

        var unknown = initial
        unknown.draft = "20"
        _ = unknown.prepare()
        check(!unknown.finish(at: nil, error: "reply and listing failed", listed: nil), "inline slot: unreadable placement is not success")
        check(unknown.needsRefresh && unknown.canCancel, "inline slot: unknown placement can be refreshed or cancelled")
        eq(unknown.prepare(), .invalid, "inline slot: unknown source cannot be retried")
        eq(unknown.draft, "20", "inline slot: unknown placement retains draft")
        check(
            unknown.reconcile(occupied: [12, 20]).isEmpty && unknown.slot == nil,
            "inline slot: ambiguous occupancy does not guess identity")
        let carried = unknown.reconcile(occupied: [20])
        eq(carried.map { [$0.from, $0.to] }, [[12, 20]], "inline slot: late refresh carries selection only for a newly proven landed step")
        eq(unknown.slot, 20, "inline slot: refresh resolves the destination")
        check(unknown.reconcile(occupied: [20]).isEmpty, "inline slot: refresh does not remap selection twice")
        eq(unknown.prepare(), .unchanged, "inline slot: late confirmation does not send a duplicate MOVE")

        var refreshing = initial
        refreshing.draft = "20"
        _ = refreshing.prepare()
        refreshing.recordLocation(at: nil)
        eq(refreshing.slot, nil, "inline slot: uncertain in-flight placement is not the old slot")
        eq(
            refreshing.reconcile(occupied: [20]).map { [$0.from, $0.to] }, [[12, 20]],
            "inline slot: readback resolves selection before the new listing prunes it")
        check(!refreshing.finish(at: 20, error: "reply was lost", listed: [20]), "inline slot: lost reply remains explicit after readback")
        check(refreshing.reconcile(occupied: [20]).isEmpty, "inline slot: confirmed placement is not remapped again")
        check(!refreshing.needsRefresh, "inline slot: successful readback resolves the row")

        var refreshFailed = initial
        refreshFailed.draft = "20"
        _ = refreshFailed.prepare()
        check(!refreshFailed.finish(at: 20, error: "moved, but refresh failed", listed: nil), "inline slot: failed refresh is explicit")
        eq(refreshFailed.rowID, 12, "inline slot: stale displayed row still shows the failed draft")
        eq(refreshFailed.slot, 20, "inline slot: known move never reuses the old source")
        check(refreshFailed.blocksFilterChange, "inline slot: unresolved listing protects navigation despite matching landed input")
        check(refreshFailed.beginRefresh(), "inline slot: explicit refresh claims the editor without sending MOVE")
        check(!refreshFailed.beginRefresh(), "inline slot: duplicate refresh is suppressed")
        check(refreshFailed.reconcile(occupied: [20]).isEmpty, "inline slot: known placement does not remap selection twice")
        eq(refreshFailed.rowID, 20, "inline slot: successful refresh relocates the stale row")
        _ = refreshFailed.finish(at: 20, error: "moved, but refresh failed", listed: [20])
        check(!refreshFailed.needsRefresh, "inline slot: resolved row no longer requires refresh")
        refreshFailed.draft = "30"
        eq(refreshFailed.prepare(), .write(from: 20, to: 30), "inline slot: failed refresh does not move an old occupant")
    }

    static func slotMoveChecks() async {
        for mode in [SlotMoveFixture.Mode.success, .refuse, .lostReply, .unreadable, .ambiguous] {
            let fixture = SlotMoveFixture(mode: mode)
            let result = await moveToFreeSlotSteps(
                from: 12, to: 20,
                list: { try await fixture.list() },
                move: { try await fixture.move() },
                isCurrent: { await fixture.current })
            switch (mode, result) {
            case (.success, .moved): break
            case (.refuse, .failed(_, at: 12)): break
            case (.lostReply, .failed(_, at: 20)): break
            case (.unreadable, .failed(_, at: nil)): break
            case (.ambiguous, .failed(_, at: nil)): break
            default: check(false, "slot move: unexpected result \(result) for \(mode)")
            }
            eq(await fixture.moves, 1, "slot move: a failed reply never triggers an automatic retry")
        }
        for target: UInt16 in [0, 12, 21, 1000, 1001, 65000] {
            let fixture = SlotMoveFixture(mode: .success)
            _ = await moveToFreeSlotSteps(
                from: 12, to: target,
                list: { try await fixture.list() },
                move: { try await fixture.move() },
                isCurrent: { await fixture.current })
            eq(await fixture.moves, 0, "slot move: invalid, unchanged and occupied targets do not write")
        }
        for source: UInt16 in [0, 1000, 1001, 65000] {
            let fixture = SlotMoveFixture(mode: .success, occupied: [source])
            let result = await moveToFreeSlotSteps(
                from: source, to: 20, list: { try await fixture.list() },
                move: { try await fixture.move() }, isCurrent: { await fixture.current })
            if case .refused = result {} else { check(false, "slot move: invalid source is refused") }
            eq(await fixture.moves, 0, "slot move: invalid source sends no MOVE")
        }
        let stale = SlotMoveFixture(mode: .success, invalidateAfterList: true)
        eq(
            await moveToFreeSlotSteps(
                from: 12, to: 20,
                list: { try await stale.list() }, move: { try await stale.move() },
                isCurrent: { await stale.current }), .stale,
            "slot move: generation change after preflight prevents MOVE")
        eq(await stale.moves, 0, "slot move: stale operation sends no request")
        let missing = SlotMoveFixture(mode: .success, occupied: [21])
        eq(
            await moveToFreeSlotSteps(
                from: 12, to: 20,
                list: { try await missing.list() }, move: { try await missing.move() },
                isCurrent: { await missing.current }), .missing,
            "slot move: missing source is never replaced by a different row")
        eq(await missing.moves, 0, "slot move: missing source sends no request")
        let unreadable = SlotMoveFixture(mode: .preflightFailure)
        let refused = await moveToFreeSlotSteps(
            from: 12, to: 20,
            list: { try await unreadable.list() }, move: { try await unreadable.move() },
            isCurrent: { await unreadable.current })
        if case .refused = refused {} else { check(false, "slot move: unreadable preflight must refuse the write") }
        eq(await unreadable.moves, 0, "slot move: failed preflight sends no request")
        let departed = SlotMoveFixture(mode: .success, invalidateAfterMove: true)
        eq(
            await moveToFreeSlotSteps(
                from: 12, to: 20,
                list: { try await departed.list() }, move: { try await departed.move() },
                isCurrent: { await departed.current }), .stale,
            "slot move: old-generation acknowledgement cannot update a new device")
        eq(await departed.moves, 1, "slot move: departure does not replay an already sent MOVE")
    }
}

private actor SlotMoveFixture {
    enum Mode { case success, refuse, lostReply, unreadable, ambiguous, preflightFailure }
    let mode: Mode
    let invalidateAfterList: Bool
    let invalidateAfterMove: Bool
    var current = true
    var moves = 0
    var occupied: Set<UInt16>

    init(
        mode: Mode, invalidateAfterList: Bool = false, invalidateAfterMove: Bool = false,
        occupied: Set<UInt16> = [12, 21]
    ) {
        self.mode = mode
        self.invalidateAfterList = invalidateAfterList
        self.invalidateAfterMove = invalidateAfterMove
        self.occupied = occupied
    }

    func list() throws -> Set<UInt16> {
        if mode == .preflightFailure || (mode == .unreadable && moves > 0) { throw CocoaError(.fileReadUnknown) }
        if invalidateAfterList { current = false }
        return occupied
    }

    func move() throws {
        moves += 1
        if invalidateAfterMove { current = false }
        if mode != .refuse {
            occupied.remove(12)
            occupied.insert(20)
        }
        if mode == .ambiguous { occupied.insert(12) }
        if mode != .success { throw CocoaError(.fileWriteUnknown) }
    }
}
