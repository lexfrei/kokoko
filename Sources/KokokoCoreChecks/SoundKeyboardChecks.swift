import KokokoLibrary

extension KokokoCoreChecks {
    static func soundKeyboardChecks() {
        var input = SoundKeyboard()
        input.focus = .soundList
        input.connected = true
        input.selection = [12]
        input.visible = [12, 13]
        eq(input.target(phase: .down, modified: false), 12, "sound keys: a plain key-down targets the selected visible row")
        for focus: SoundFocus? in [nil, .filter, .bulkMove, .moveSlot, .rename(12), .rowAction(12, .play), .rowMenu(12)] {
            var other = input
            other.focus = focus
            eq(other.target(phase: .down, modified: false), nil, "sound keys: fields and native controls keep their keys")
        }
        for phase in [SoundKeyPhase.repeating, .up] {
            eq(input.target(phase: phase, modified: false), nil, "sound keys: no repeat or release action")
        }
        eq(input.target(phase: .down, modified: true), nil, "sound keys: modified keys remain native")
        for selection: Set<UInt16> in [[], [12, 13], [99]] {
            var other = input
            other.selection = selection
            eq(other.target(phase: .down, modified: false), nil, "sound keys: require exactly one visible selection")
        }
        var blocked = input
        blocked.blocked = true
        eq(blocked.target(phase: .down, modified: false), nil, "sound keys: presentation or inline edit blocks the list")
        blocked = input
        blocked.busy = true
        eq(blocked.target(phase: .down, modified: false), nil, "sound keys: busy device is not targeted")
        blocked = input
        blocked.connected = false
        eq(blocked.target(phase: .down, modified: false), nil, "sound keys: disconnected device is not targeted")
        blocked = input
        blocked.tab = .projects
        eq(blocked.target(phase: .down, modified: false), nil, "sound keys: another tab is not targeted")

        let initial = InlineRename(id: 12, generation: 4, name: "kick")
        let reopened = InlineRename(id: 12, generation: 4, name: "kick")
        check(initial.session != reopened.session, "inline rename: reopening the same row cannot receive an old completion")
        var draftOnly = initial
        draftOnly.draft = "kick two"
        check(!draftOnly.submitting && draftOnly.canCancel, "inline rename: changing a draft does not submit it")
        check(initial.isCurrent(selection: [12], visible: [12], tab: .sounds, generation: 4), "inline rename: current row context")
        check(!initial.isCurrent(selection: [13], visible: [12, 13], tab: .sounds, generation: 4), "inline rename: selection change invalidates")
        check(!initial.isCurrent(selection: [12], visible: [], tab: .sounds, generation: 4), "inline rename: filtered or removed row invalidates")
        check(!initial.isCurrent(selection: [12], visible: [12], tab: .projects, generation: 4), "inline rename: tab change invalidates")
        check(!initial.isCurrent(selection: [12], visible: [12], tab: .sounds, generation: 5), "inline rename: reconnect invalidates the slot")
        var spaced = InlineRename(id: 12, generation: 4, name: " kick ")
        eq(spaced.prepare(), .unchanged, "inline rename: an untouched existing name is not normalized by Return")
        var edit = initial
        eq(edit.prepare(), .unchanged, "inline rename: unchanged name needs no write")
        edit.draft = " \t\n "
        eq(edit.prepare(), .invalid, "inline rename: whitespace-only name needs no write")
        check(edit.error != nil && !edit.submitting, "inline rename: invalid name stays editable with an error")
        edit.draft = " snare "
        eq(edit.prepare(), .write("snare"), "inline rename: Return submits a trimmed name")
        check(!edit.canCancel, "inline rename: Escape cannot cancel an in-flight device write")
        eq(edit.prepare(), .waiting, "inline rename: duplicate Return does not write twice")
        check(!edit.finish(error: "device refused name"), "inline rename: failed request does not close the editor")
        eq(edit.draft, " snare ", "inline rename: failure preserves the exact draft")
        eq(edit.error, "device refused name", "inline rename: failure remains readable")
        check(edit.canCancel, "inline rename: failed request can be cancelled without a write")
        eq(edit.prepare(), .write("snare"), "inline rename: retry is explicit")
        check(edit.finish(error: nil), "inline rename: success closes the editor")
        check(initial.canCancel && !initial.submitting, "inline rename: unsent draft can be cancelled without a write")
    }
}
