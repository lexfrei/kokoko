#if os(macOS) && DEBUG
import AppKit
import SwiftUI
import KokokoCore
import KokokoLibrary
@testable import KokokoMIDI
import UniformTypeIdentifiers

@MainActor
enum NativeRowDropChecks {
    private static var failures = 0
    private static var baselineFocus: [String: Bool] = [:]
    private static var baselineFonts: [String: String] = [:]

    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        transport()
        containment()
        print(failures == 0 ? "native row drop: all checks passed" : "native row drop: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    private static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "ok  " : "FAIL") \(message)")
        if !condition { failures += 1 }
    }

    private static let marker = NSPasteboard.PasteboardType(UTType.soundRowMove.identifier)
    private static let items = (1...3).map { value in
        SoundItem(node: FSNode(id: UInt16(value), parentID: 10, name: "\(value)", flags: 0xff, size: 4),
                  displayName: value == 2 ? "longer sound name" : "sound \(value)")
    }

    private static func makeState() -> AppState {
        let state = AppState()
        state.connection = .connected(deviceName: "fixture", serial: "fixture", osVersion: "test")
        state.sounds = items
        return state
    }

    private static func transport() {
        let state = makeState()
        let source = RowDragHandle.Handle()
        source.state = state
        source.item = items[0]
        let destination = NativeRowDropView()
        destination.state = state
        destination.item = items[1]
        let token = RowDragToken(id: 1)
        let delegate = RowDragProviderChecks.PromiseDelegate()
        let writer = RowPromise(fileType: UTType.wav.identifier, delegate: delegate)
        writer.token = token
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        check(board.writeObjects([writer]), "native drop: real RowPromise writes named board")
        check(board.pasteboardItems?.count == 1, "native drop: one writer produces one native item")
        check(destination.registeredDraggedTypes.contains(marker), "native drop: destination registers private marker")
        state.rowDrag.begin(token)
        let generation = state.rowDragGeneration
        var highlighted: UInt16?
        destination.targeted = Binding(get: { highlighted }, set: { highlighted = $0 })
        let info = DragInfo(pasteboard: board, source: source)
        check(destination.draggingEntered(info) == .move && highlighted == 2, "native drop: eligible native entry highlights target")
        check(state.rowDrag.active == token, "native drop: hover never claims context")
        let adjacent = NativeRowDropView()
        adjacent.state = state
        adjacent.item = items[2]
        adjacent.targeted = destination.targeted
        check(adjacent.draggingEntered(info) == .move && highlighted == 3, "native drop: adjacent destination takes feedback ownership")
        destination.draggingExited(info)
        check(highlighted == 3, "native drop: late exit does not clear another destination's feedback")
        adjacent.draggingExited(info)
        check(highlighted == nil, "native drop: feedback owner clears its own target")
        _ = destination.draggingEntered(info)
        let handlesEnd = destination.responds(to: #selector(NativeRowDropView.draggingEnded(_:)))
        check(handlesEnd, "native drop: destination handles optional end callback")
        if handlesEnd { destination.draggingEnded(info) }
        check(highlighted == nil, "native drop: ended operation clears feedback")
        check(!destination.performDragOperation(info), "native drop: ended operation cannot perform later")
        state.pendingSwap = nil
        state.rowDrag.begin(token)
        info.draggingSourceOperationMask = .copy
        check(destination.draggingEntered(info).isEmpty && highlighted == nil, "native drop: copy-only source is not offered a move")
        check(!destination.performDragOperation(info), "native drop: copy-only source cannot perform a move")
        state.pendingSwap = nil
        state.rowDrag.begin(token)
        info.draggingSourceOperationMask = [.copy, .move]
        _ = destination.draggingEntered(info)
        destination.draggingExited(info)
        check(!destination.prepareForDragOperation(info), "native drop: exited destination cannot prepare without reentry")
        check(destination.draggingEntered(info) == .move && destination.prepareForDragOperation(info),
              "native drop: native callback chain prepares eligible row")
        check(destination.performDragOperation(info), "native drop: actual writer reaches native callback receiver")
        destination.concludeDragOperation(info)
        check(highlighted == nil, "native drop: accepted operation leaves no feedback")
        check(state.pendingSwap?.id == 1 && state.pendingSwap?.target == 2, "native drop: requests existing confirmation only")
        state.rowDrag.end(token)
        check(state.pendingSwap?.id == 1, "native drop: ending claimed context keeps accepted confirmation")
        check(!destination.receive(board, source: source, generation: generation), "native drop: duplicate perform cannot claim twice")
        state.pendingSwap = nil
        state.rowDrag.begin(token)
        state.rowDrag.end(token)
        check(!destination.receive(board, source: source, generation: generation), "native drop: ended context rejects before claim")
        state.rowDrag.begin(token)
        check(!destination.receive(board, source: source, generation: UUID()), "native drop: stale generation rejects")
        check(state.rowDrag.active == token, "native drop: rejected generation does not consume context")
        let foreign = RowDragHandle.Handle()
        foreign.state = makeState()
        foreign.item = items[0]
        check(!destination.receive(board, source: foreign, generation: generation), "native drop: foreign AppState rejects")
        source.item = items[2]
        check(!destination.receive(board, source: source, generation: generation), "native drop: source identity must match token")
        source.item = items[0]
        destination.item = items[0]
        check(!destination.receive(board, source: source, generation: generation), "native drop: self target rejects")
        destination.item = items[1]

        func pasteboardItem(text: Data?, marked: Bool) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            if let text { item.setData(text, forType: .string) }
            if marked { item.setData(Data(), forType: marker) }
            return item
        }
        let bytes = Data(token.payload.utf8)
        let cases: [(String, [NSPasteboardItem])] = [
            ("missing marker", [pasteboardItem(text: bytes, marked: false)]),
            ("missing text", [pasteboardItem(text: nil, marked: true)]),
            ("wrong nonce", [pasteboardItem(text: Data(RowDragToken(id: 1).payload.utf8), marked: true)]),
            ("invalid UTF-8", [pasteboardItem(text: Data([0xff]), marked: true)]),
            ("split marker and text", [pasteboardItem(text: bytes, marked: false), pasteboardItem(text: nil, marked: true)]),
            ("ambiguous marked items", [pasteboardItem(text: bytes, marked: true), pasteboardItem(text: bytes, marked: true)]),
            ("unrelated leading item", [pasteboardItem(text: Data("other".utf8), marked: false), pasteboardItem(text: bytes, marked: true)])
        ]
        for (name, candidates) in cases {
            board.clearContents()
            check(board.writeObjects(candidates), "native drop: writes \(name) fixture")
            state.rowDrag.begin(token)
            check(!destination.receive(board, source: source, generation: generation), "native drop: refuses \(name)")
            check(state.rowDrag.active == token && state.pendingSwap == nil, "native drop: \(name) leaves context and confirmation unchanged")
        }
        let broad = NSPasteboardItem()
        broad.setData(bytes, forType: NSPasteboard.PasteboardType(UTType.plainText.identifier))
        broad.setData(Data(), forType: marker)
        board.clearContents()
        check(board.writeObjects([broad]), "native drop: writes broad-text-only fixture")
        check(!destination.receive(board, source: source, generation: generation), "native drop: no broad-text conversion fallback")
        board.clearContents()
        check(board.writeObjects([writer]), "native drop: restores actual writer")
        state.sounds = [items[0]]
        check(!destination.receive(board, source: source, generation: generation), "native drop: vanished target rejects")
        state.sounds = [items[1]]
        check(!destination.receive(board, source: source, generation: generation), "native drop: vanished source rejects")
        state.sounds = items
        let deferred = DeferredText(bytes: bytes) { state.rowDrag.begin(RowDragToken(id: 3)) }
        let delayedItem = NSPasteboardItem()
        delayedItem.setData(Data(), forType: marker)
        delayedItem.setDataProvider(deferred, forTypes: [.string])
        board.clearContents()
        check(board.writeObjects([delayedItem]), "native drop: writes deferred native text")
        check(deferred.requests == 0, "native drop: deferred callback has not run before receive")
        state.rowDrag.begin(token)
        check(!destination.receive(board, source: source, generation: generation), "native drop: replacement context during read rejects")
        check(deferred.requests == 1 && state.rowDrag.active?.id == 3, "native drop: replacement context survives rejection")
        state.rowDrag.begin(token)
        let changedTarget = DeferredText(bytes: bytes) { destination.item = items[2] }
        let reusedItem = NSPasteboardItem()
        reusedItem.setData(Data(), forType: marker)
        reusedItem.setDataProvider(changedTarget, forTypes: [.string])
        board.clearContents()
        check(board.writeObjects([reusedItem]), "native drop: writes target-reuse fixture")
        check(destination.draggingEntered(info) == .move && highlighted == 2, "native drop: target-reuse fixture begins highlighted")
        check(!destination.receive(board, source: source, generation: generation), "native drop: target reuse during read rejects")
        check(highlighted == nil, "native drop: target reuse clears the original feedback")
        check(state.pendingSwap == nil && state.rowDrag.active == token, "native drop: target reuse does not consume context")
        destination.item = items[1]
        let busyText = DeferredText(bytes: bytes) { _ = state.enterDevice() }
        let busyItem = NSPasteboardItem()
        busyItem.setData(Data(), forType: marker)
        busyItem.setDataProvider(busyText, forTypes: [.string])
        board.clearContents()
        check(board.writeObjects([busyItem]), "native drop: writes admission-change fixture")
        check(!state.deviceBusy && busyText.requests == 0, "native drop: device idle before deferred read")
        check(!destination.receive(board, source: source, generation: generation), "native drop: admission acquired during read rejects")
        check(state.deviceBusy && busyText.requests == 1, "native drop: deferred read exercised actual device admission without I/O")
        check(state.rowDrag.active == token && state.pendingSwap == nil, "native drop: busy transition preserves context without confirmation")
        check(!destination.receive(board, source: source, generation: generation), "native drop: already-busy state rejects")
        check(delegate.writes == 0, "native drop: local reads never fulfill WAV promise")
        check(NSApplication.shared.windows.isEmpty, "native drop: transport checks create no windows")
    }

    private static func containment() {
        let widths: [CGFloat] = [420, 840]
        let selections: [Set<UInt16>] = [[], [1], [1, 2]]
        let cases: [(CGFloat, Set<UInt16>)] = widths.flatMap { width in selections.map { (width, $0) } }
        for native in [false, true] {
            for (width, selection) in cases {
                print("containment case: native=\(native) width=\(width) selection=\(selection.sorted())")
                let model = Model(state: makeState())
                model.state.selection = selection
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1100),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: Root(model: model, native: native))
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: 1100)
                settle(host)
                let handles = descendants(host).compactMap { $0 as? RowDragHandle.Handle }
                check(handles.count == 3, "containment: production handles, native \(native), selection \(selection.sorted())")
                for handle in handles {
                    let center = NSPoint(x: handle.bounds.midX, y: handle.bounds.midY)
                    check(host.hitTest(handle.convert(center, to: host.superview)) === handle,
                          "containment: actual handle owns mouse hit, native \(native)")
                    let textPoint = NSPoint(x: handle.bounds.maxX + 110, y: handle.bounds.midY)
                    check(host.hitTest(handle.convert(textPoint, to: host.superview)) !== handle,
                          "containment: row text is outside grip, native \(native)")
                }
                let containers = descendants(host).compactMap { $0 as? NativeRowDropView }
                check(containers.count == (native ? 3 : 0), "containment: destination ancestry matches row route")
                check(model.state.selection == selection, "containment: mounting preserves selection")
                if native {
                    for handle in handles {
                        check(containers.contains { handle.isDescendant(of: $0) }, "containment: destination contains actual handle")
                    }
                }
                if let table = descendants(host).compactMap({ $0 as? NSTableView }).first,
                   let first = handles.first(where: { $0.item?.id == 1 }),
                   let last = handles.first(where: { $0.item?.id == 3 }) {
                    let rows = [table.row(for: first), table.row(for: last)]
                    check(rows.allSatisfy { $0 >= 0 }, "containment: production rows have native selection identity")
                    if rows.allSatisfy({ $0 >= 0 }) {
                        table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
                    }
                    settle(host)
                    check(model.state.selection == [1, 3], "containment: native table selection reaches app binding, native \(native)")
                } else {
                    check(false, "containment: production List exposes actual rows for selection")
                }
                let identities = containers.map(ObjectIdentifier.init)
                model.state.beginInlineRename(items[0])
                model.focus = .rename(1)
                settle(host)
                editField("sound name", value: "edited name", host: host, window: window, native: native)
                check(model.state.inlineRename?.draft == "edited name", "containment: production rename binding, native \(native)")
                check(model.focus == .rename(1), "containment: parent focus binding remains attached, native \(native)")
                model.state.inlineRename = nil
                model.state.inlineSlotEdit = InlineSlotEdit(id: 1, generation: 0)
                model.focus = .slot(model.state.inlineSlotEdit!.session)
                settle(host)
                editField("slot", value: "44", host: host, window: window, native: native)
                check(model.state.inlineSlotEdit?.draft == "44", "containment: production slot binding, native \(native)")
                model.disabled = true
                settle(host)
                let disabledSlot = descendants(host).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "slot" }
                check(disabledSlot?.isEnabled == false, "containment: inherited disabled environment reaches field, native \(native)")
                model.disabled = false
                model.state.inlineSlotEdit = nil
                var metadata = InlineMetadataEdit(id: 1, name: items[0].displayName, generation: 0)
                _ = metadata.loaded(request: metadata.request!, metadata: ["sound.rootnote": .int(60)], error: nil)
                model.state.metadataEditing = metadata
                model.focus = .metadataField(metadata.session, "sound.rootnote")
                settle(host)
                editField("", value: "61", initial: "60", host: host, window: window, native: native)
                check(model.state.metadataEditing?.form?.text["sound.rootnote"] == "61",
                      "containment: production metadata binding, native \(native)")
                model.typeSize = .accessibility2
                settle(host)
                check(model.state.metadataEditing?.form?.text["sound.rootnote"] == "61",
                      "containment: environment update retains editor draft, native \(native)")
                model.state.metadataEditing = nil
                model.typeSize = .large
                settle(host)
                let before = containers.first?.frame.height
                let record = WaveformPeakRecord(pcm: [0, 0, 0, 128], channels: 1, sampleRate: 46875)!
                model.state.waveformShown = WaveformShown(item: items[0], record: record, loopStart: nil,
                                                          loopEnd: nil, cached: false, metadataConfirmed: true)
                settle(host)
                let updatedHandles = descendants(host).compactMap { $0 as? RowDragHandle.Handle }
                check(updatedHandles.map(ObjectIdentifier.init) == handles.map(ObjectIdentifier.init),
                      "containment: editor and waveform updates retain actual source views, native \(native)")
                if native {
                    let current = descendants(host).compactMap { $0 as? NativeRowDropView }
                    check(current.map(ObjectIdentifier.init) == identities, "containment: updates retain native container identity")
                    check((current.first?.frame.height ?? 0) > (before ?? 0), "containment: inline waveform changes row height")
                }
                check(!window.isVisible && !window.isKeyWindow && !window.isMainWindow, "containment: window remains hidden and inactive")
                window.close()
                settle(host)
            }
        }
    }

    private static func editField(_ placeholder: String, value: String, initial: String? = nil, host: NSView, window: NSWindow, native: Bool) {
        guard let field = descendants(host).compactMap({ $0 as? NSTextField }).first(where: {
            if let initial { return $0.stringValue == initial && $0.isEditable }
            return $0.placeholderString == placeholder
        }) else {
            check(false, "containment: actual \(placeholder) field exists, native \(native)")
            return
        }
        let focused = field.currentEditor() != nil || window.firstResponder === field
        let key = "\(Int(host.bounds.width)):\(placeholder)"
        let font = "\(field.font?.fontName ?? "none"):\(field.font?.pointSize ?? 0)"
        if native {
            check(focused == baselineFocus[key], "containment: parent FocusState matches hidden baseline for \(placeholder)")
            check(font == baselineFonts[key], "containment: inherited production font matches baseline for \(placeholder)")
        } else {
            baselineFocus[key] = focused
            baselineFonts[key] = font
            print("containment baseline: field=\(placeholder) automatic-focus=\(focused) font=\(font)")
        }
        check(field.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
              "containment: inherited dark appearance reaches field, native \(native)")
        check(window.makeFirstResponder(field), "containment: \(placeholder) accepts first responder, native \(native)")
        if let editor = field.currentEditor() { editor.string = value }
        field.stringValue = value
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        settle(host)
    }

    private static func settle(_ host: NSView) {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private final class DragInfo: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingSource: Any?
        let draggingDestinationWindow: NSWindow? = nil
        var draggingSourceOperationMask: NSDragOperation = [.copy, .move]
        let draggingLocation = NSPoint.zero
        let draggedImageLocation = NSPoint.zero
        let draggedImage: NSImage? = nil
        let draggingSequenceNumber = 1
        var draggingFormation = NSDraggingFormation.none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        let springLoadingHighlight = NSSpringLoadingHighlight.none

        @MainActor init(pasteboard: NSPasteboard, source: Any?) {
            draggingPasteboard = pasteboard
            draggingSource = source
        }

        func slideDraggedImage(to screenPoint: NSPoint) { preconditionFailure("unexpected drag-image movement") }
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
            preconditionFailure("unexpected promised-file request")
        }
        func resetSpringLoading() { preconditionFailure("unexpected spring loading") }
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
            preconditionFailure("unexpected drag-image enumeration")
        }
    }

    private final class DeferredText: NSObject, NSPasteboardItemDataProvider {
        let bytes: Data
        let provide: () -> Void
        private(set) var requests = 0

        init(bytes: Data, provide: @escaping () -> Void) {
            self.bytes = bytes
            self.provide = provide
        }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            requests += 1
            provide()
            item.setData(bytes, forType: type)
        }
    }

    private final class Model: ObservableObject {
        let state: AppState
        @Published var focus: SoundFocus?
        @Published var disabled = false
        @Published var typeSize = DynamicTypeSize.large
        init(state: AppState) { self.state = state }
    }

    private struct Root: View {
        @ObservedObject var model: Model
        let native: Bool
        var body: some View {
            ContentView(state: model.state, rowDropCheck: native ? nil : false, rowDropCheckFocus: $model.focus,
                        suppressDeviceObservationForCheck: true)
                .environment(\.colorScheme, .dark)
                .environment(\.dynamicTypeSize, model.typeSize)
                .disabled(model.disabled)
        }
    }
}
#endif
