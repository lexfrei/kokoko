import SwiftUI
import UniformTypeIdentifiers
import KokokoLibrary

#if os(macOS)
struct RowDragHandle: NSViewRepresentable {
    let item: SoundItem
    let state: AppState

    func makeNSView(context: Context) -> Handle {
        let view = Handle()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("drag sound to reorder or export")
        return view
    }

    func updateNSView(_ view: Handle, context: Context) {
        view.item = item
        view.state = state
    }

    final class Handle: NSTextField, NSDraggingSource, NSFilePromiseProviderDelegate {
        var item: SoundItem?
        var state: AppState?
        private var token: RowDragToken?
        private var startEvent: NSEvent?

        init() {
            super.init(frame: .zero)
            stringValue = "≡"
            isEditable = false
            isSelectable = false
            isBezeled = false
            drawsBackground = false
            alignment = .center
            font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func mouseDown(with event: NSEvent) { startEvent = event }

        override func mouseDragged(with event: NSEvent) {
            guard let startEvent, let item, let state, !state.deviceBusy else { return }
            self.startEvent = nil
            let token = RowDragToken(id: item.id)
            self.token = token
            state.rowDrag.begin(token)
            let provider = RowPromise(fileType: UTType.wav.identifier, delegate: self)
            provider.token = token
            provider.userInfo = item
            let drag = NSDraggingItem(pasteboardWriter: provider)
            drag.setDraggingFrame(bounds, contents: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "sound"))
            beginDraggingSession(with: [drag], event: startEvent, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? [.copy, .move] : .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if let token { state?.rowDrag.end(token) }
            token = nil
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            ((filePromiseProvider.userInfo as? SoundItem)?.displayName ?? "sound") + ".wav"
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            let item = filePromiseProvider.userInfo as? SoundItem
            let token = (filePromiseProvider as? RowPromise)?.token
            // AppKit supplies an unannotated callback on our main operation queue.
            nonisolated(unsafe) let completion = completionHandler
            MainActor.assumeIsolated {
                guard let state, let item else {
                    completion(CocoaError(.fileNoSuchFile))
                    return
                }
                if let token { state.rowDrag.end(token) }
                Task { @MainActor in
                    switch await state.download(item) {
                    case .success(let result):
                        do {
                            try Data(result.wav).write(to: url)
                            completion(nil)
                        } catch { completion(error) }
                    case .failure(let error): completion(error)
                    }
                }
            }
        }
    }
}

private final class RowPromise: NSFilePromiseProvider {
    var token: RowDragToken?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.string, NSPasteboard.PasteboardType(UTType.soundRowMove.identifier)]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == .string || type.rawValue == UTType.soundRowMove.identifier { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .string { return token?.payload }
        if type.rawValue == UTType.soundRowMove.identifier { return Data() }
        return super.pasteboardPropertyList(forType: type)
    }
}
#else
struct RowDragHandle: UIViewRepresentable {
    let item: SoundItem
    let state: AppState

    func makeUIView(context: Context) -> Handle {
        let view = Handle()
        view.text = "≡"
        view.textAlignment = .center
        view.isUserInteractionEnabled = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = "drag sound to reorder or export"
        let interaction = UIDragInteraction(delegate: view)
        interaction.isEnabled = true
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ view: Handle, context: Context) {
        view.item = item
        view.state = state
    }

    final class Handle: UILabel, UIDragInteractionDelegate {
        var item: SoundItem?
        var state: AppState?

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
            guard let item, let state, !state.deviceBusy else { return [] }
            let token = RowDragToken(id: item.id)
            session.localContext = token
            state.rowDrag.begin(token)
            return [UIDragItem(itemProvider: state.dragProvider(for: item, token: token))]
        }

        func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
            if let token = session.localContext as? RowDragToken { state?.rowDrag.end(token) }
            session.localContext = nil
        }
    }
}
#endif
