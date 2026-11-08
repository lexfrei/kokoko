#if os(macOS) && DEBUG
import AppKit
import SwiftUI
import KokokoLibrary
@testable import KokokoMIDI

@MainActor
final class SoundRangeTabProbe {
    var frames: [String: CGRect] = [:]
    var actions: [SoundFocus: @MainActor () -> Void] = [:]
}

struct SoundRangeTabFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static let coordinateSpace = "sound-range-tabs"

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

@MainActor
enum SoundRangeTabChecks {
    private static var failures = 0
    private static let slots: [UInt16] = [0, 1, 100, 199, 900, 65000]
    private static let items = zip(slots, ["zero", "kick", "snare", "snare high", "effect", "other"]).map {
        SoundItem(node: FSNode(id: $0.0, parentID: 10, name: String($0.0), flags: 0xff, size: 4), displayName: $0.1)
    }
    private static let identifiers = ["sound-range-all"] + SoundRange.all.map { "sound-range-" + $0.name.lowercased() }

    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        stateChecks()
        scrollChecks()
        for width: CGFloat in [420, 840] {
            for size: DynamicTypeSize in [.large, .accessibility2] { layout(width: width, size: size) }
        }
        print(failures == 0 ? "range tabs: all checks passed" : "range tabs: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    private static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "ok  " : "FAIL") \(message)")
        if !condition { failures += 1 }
    }

    private static func makeState() -> AppState {
        let state = AppState(listedSounds: items)
        state.connection = .connected(deviceName: "fixture", serial: "fixture", osVersion: "test")
        return state
    }

    private static func stateChecks() {
        let state = makeState()
        check(state.soundRange == nil && state.visibleSounds.count == items.count, "range state: ALL is the default including outliers")
        state.selection = [1, 100, 900]
        check(state.setSoundRange(SoundRange.all[1]), "range state: a range switch is accepted without I/O")
        check(state.visibleSounds.map(\.id) == [100, 199] && state.selection == [100], "range state: scope is shared with visible selection")
        check(state.setFilterText("snare") && state.filterText == "snare", "range state: existing search is retained")
        check(state.setSoundRange(SoundRange.all[0]) && state.filterText == "snare", "range state: switching range never rewrites the query")
        check(state.visibleSounds.isEmpty && state.selection.isEmpty, "range state: search and range intersect without hidden selection")
        check(state.setSoundRange(nil) && state.selection.isEmpty, "range state: returning to ALL does not restore hidden selection")
        check(state.visibleSounds.map(\.id) == [100, 199], "range state: ALL still respects the query")

        let rename = makeState()
        rename.selection = [1]
        rename.inlineRename = InlineRename(id: 1, generation: 0, name: "kick")
        rename.inlineRename?.draft = "unsaved"
        check(rename.soundFilterChangeBlocked, "range guard: dirty rename blocks range and search")
        check(rename.setSoundRange(nil) && rename.setFilterText("") && rename.inlineRename?.draft == "unsaved",
              "range guard: idempotent filter requests leave an open draft untouched")
        check(!rename.setSoundRange(SoundRange.all[1]) && !rename.setFilterText("snare"), "range guard: blocked changes are refused at the state boundary")
        check(rename.soundRange == nil && rename.filterText.isEmpty && rename.inlineRename?.draft == "unsaved", "range guard: refused navigation preserves draft and scope")
        rename.inlineRename?.draft = " kick "
        check(rename.setSoundRange(SoundRange.all[1]) && rename.inlineRename == nil && !rename.deviceBusy,
              "range guard: an equivalent rename closes without saving or claiming the device")

        let slot = makeState()
        slot.selection = [1]
        slot.inlineSlotEdit = InlineSlotEdit(id: 1, generation: 0)
        slot.inlineSlotEdit?.draft = "44"
        check(!slot.setSoundRange(SoundRange.all[1]) && slot.inlineSlotEdit?.draft == "44", "range guard: unsaved slot text survives a refused range switch")
        slot.inlineSlotEdit?.draft = "0001"
        check(slot.setFilterText("kick") && slot.inlineSlotEdit == nil && !slot.deviceBusy, "range guard: an unchanged padded slot closes without MOVE")

        let metadata = makeState()
        metadata.selection = [1]
        var edit = InlineMetadataEdit(id: 1, name: "kick", generation: 0)
        metadata.metadataEditing = edit
        check(!metadata.setFilterText("snare"), "range guard: in-flight inline metadata read cannot be hidden")
        _ = edit.loaded(request: edit.request!, metadata: ["sound.bpm": .int(120)], error: nil)
        edit.form?.text["sound.bpm"] = "133"
        metadata.metadataEditing = edit
        check(!metadata.setSoundRange(SoundRange.all[1]) && metadata.metadataEditing?.form?.text["sound.bpm"] == "133",
              "range guard: unsaved metadata survives range refusal")
        metadata.metadataEditing?.form?.text["sound.bpm"] = "120"
        check(metadata.setSoundRange(SoundRange.all[1]) && metadata.metadataEditing == nil && !metadata.deviceBusy,
              "range guard: unchanged metadata closes without SET")

        let busy = makeState()
        busy.waveformShown = WaveformShown(item: items[1], record: nil, loopStart: nil, loopEnd: nil, metadataConfirmed: false)
        check(busy.enterDevice(), "range guard: actual device admission can be occupied without I/O")
        check(!busy.soundFilterChangeBlocked && busy.setSoundRange(SoundRange.all[0]) && busy.setFilterText("kick"),
              "range guard: busy state and read-only waveform do not block navigation")
        check(busy.deviceBusy && busy.waveformShown?.id == 1, "range guard: navigation does not finish the operation or dismiss a still-visible waveform")
    }

    private static func layout(width: CGFloat, size: DynamicTypeSize) {
        let model = Model(state: makeState())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1000),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Root(model: model, size: size, dark: width == 840))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        settle(host)
        check(model.probe.actions.count == 11, "range UI: production ALL and named actions are installed")
        let frames = identifiers.compactMap { model.probe.frames[$0] }
        check(frames.count == 11, "range UI: actual ALL and every named tab have layout frames")
        check(frames.allSatisfy { $0.width > 0 && $0.height >= minHitHeight && $0.minX >= -1 && $0.maxX <= width + 1 },
              "range UI: production tab hit regions fit the viewport at \(size)")
        check(frames.enumerated().allSatisfy { index, frame in frames.dropFirst(index + 1).allSatisfy { !frame.intersects($0) } },
              "range UI: wrapped production tab regions do not overlap")
        if width == 420 { check(Set(frames.map { Int($0.minY.rounded()) }).count > 1, "range UI: compact tabs wrap instead of scrolling out of view") }
        let scopes: [SoundRange?] = [nil] + SoundRange.all.map(Optional.some)
        let expected: [Int: Set<UInt16>] = [0: [1], 1: [100, 199], 9: [900]]
        for (index, range) in scopes.enumerated() {
            let target: SoundFocus = range.map { SoundFocus.rangeJump($0.id) } ?? .allRanges
            guard let action = model.probe.actions[target] else {
                check(false, "range UI: requested production action exists")
                continue
            }
            action()
            settle(host)
            let visible = range.map { expected[$0.id] ?? [] } ?? Set(items.map(\.id))
            check(model.state.soundRange == range && Set(model.state.visibleSounds.map(\.id)) == visible,
                  "range UI: production action selects its exact scope")
            let rendered = descendants(host).compactMap { $0 as? RowDragHandle.Handle }
                .filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0.item?.id }
            check(Set(rendered).isSubset(of: visible), "range UI: no rendered row belongs to another scope")
            if range != nil {
                check(Set(rendered) == visible, "range UI: a selected small range renders its exact contents")
            } else if let table = descendants(host).compactMap({ $0 as? NSTableView }).first, table.numberOfRows > 0 {
                table.scrollRowToVisible(table.numberOfRows - 1)
                settle(host)
                let tail = descendants(host).compactMap { $0 as? RowDragHandle.Handle }
                    .filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0.item?.id }
                check(Set([UInt16(0), 65000]).isSubset(of: Set(tail)), "range UI: ALL makes outliers reachable through the actual Other section")
            }
            let underlines = model.probe.frames.filter { $0.key.hasPrefix("sound-range-underline-") }
            let active = "sound-range-underline-" + (range?.name.lowercased() ?? "all")
            check(underlines.count == 1 && underlines[active]?.height == 2,
                  "range UI: exactly the active range has a visible production underline")
            if let line = underlines[active], let tab = model.probe.frames[identifiers[index]] {
                check(abs(line.minX - tab.minX) < 1 && abs(line.width - tab.width) < 1 && abs(line.maxY - tab.maxY) < 1,
                      "range UI: active underline belongs to the selected tab frame")
            }
            check(model.focus == nil || model.focus == target,
                  "range UI: hidden native focus never targets another scope or a sound command")
        }
        _ = model.state.setSoundRange(nil)
        model.state.selection = [1]
        model.state.inlineRename = InlineRename(id: 1, generation: 0, name: "kick")
        model.state.inlineRename?.draft = "unsaved"
        settle(host)
        check((model.probe.frames["sound-filter-editor-hint"]?.height ?? 0) > 0,
              "range UI: the real adjacent editor-protection hint is laid out")
        let filter = descendants(host).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "filter: name or slot" }
        check(filter?.isEnabled == false, "range UI: dirty draft protects the actual native search field")
        model.probe.actions[.rangeJump(1)]?()
        settle(host)
        check(model.state.soundRange == nil && model.state.inlineRename?.draft == "unsaved",
              "range UI: production tab action cannot discard a dirty draft")
        model.state.inlineRename?.draft = "kick"
        settle(host)
        check(model.probe.frames["sound-filter-editor-hint"] == nil && filter?.isEnabled == true,
              "range UI: an unchanged editor does not trap navigation")
        model.probe.actions[.rangeJump(1)]?()
        settle(host)
        check(model.state.soundRange == SoundRange.all[1] && model.state.inlineRename == nil && !model.state.deviceBusy,
              "range UI: production action closes unchanged editor without a write")
        _ = model.state.enterDevice()
        model.probe.actions[.rangeJump(9)]?()
        settle(host)
        check(model.state.soundRange == SoundRange.all[9] && filter?.isEnabled == true,
              "range UI: an occupied device does not block range or search navigation")
        check(!window.isVisible && !window.isKeyWindow && !window.isMainWindow, "range UI: own window remains hidden and inactive")
        model.probe.actions.removeAll()
        window.contentView = nil
        window.close()
        settle(host)
    }

    private static func scrollChecks() {
        let slots = Array(UInt16(100)...119) + Array(UInt16(900)...919)
        let listed = slots.map { slot in
            SoundItem(node: FSNode(id: slot, parentID: 10, name: String(slot), flags: 0xff, size: 4), displayName: "sound \(slot)")
        }
        let state = AppState(listedSounds: listed)
        state.connection = .connected(deviceName: "fixture", serial: "fixture", osVersion: "test")
        let model = Model(state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Root(model: model, size: .large, dark: false))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        settle(host)
        for range in [SoundRange.all[1], SoundRange.all[9], SoundRange.all[1]] {
            model.probe.actions[.rangeJump(range.id)]?()
            settle(host)
            guard let table = descendants(host).compactMap({ $0 as? NSTableView }).first, table.numberOfRows > 0 else {
                check(false, "range scroll: actual List has a native viewport")
                continue
            }
            check(rowVisible(range.lower, in: table, host: host), "range scroll: switching a long range starts at its first sound")
            table.scrollRowToVisible(table.numberOfRows - 1)
            settle(host)
            check(!rowVisible(range.lower, in: table, host: host), "range scroll: fixture actually moves away from the first row")
        }
        check(!window.isVisible && !window.isKeyWindow && !window.isMainWindow, "range scroll: viewport check stays hidden and inactive")
        model.probe.actions.removeAll()
        window.contentView = nil
        window.close()
        settle(host)
    }

    private static func rowVisible(_ slot: UInt16, in table: NSTableView, host: NSView) -> Bool {
        guard let handle = descendants(host).compactMap({ $0 as? RowDragHandle.Handle }).first(where: { $0.item?.id == slot }) else { return false }
        let row = table.row(for: handle)
        return row >= 0 && table.rect(ofRow: row).intersects(table.visibleRect)
    }

    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private static func settle(_ host: NSView) {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    @MainActor private final class Model: ObservableObject {
        let state: AppState
        let probe = SoundRangeTabProbe()
        @Published var focus: SoundFocus?
        init(state: AppState) { self.state = state }
    }

    private struct Root: View {
        @ObservedObject var model: Model
        let size: DynamicTypeSize
        let dark: Bool
        var body: some View {
            ContentView(state: model.state, rowDropCheckFocus: $model.focus, suppressDeviceObservationForCheck: true, rangeTabProbeForCheck: model.probe)
                .environment(\.dynamicTypeSize, size)
                .environment(\.colorScheme, dark ? .dark : .light)
        }
    }
}
#endif
