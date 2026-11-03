import SwiftUI
import UniformTypeIdentifiers
import KokokoLibrary

enum RowDragDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["KOKOKO_DRAG_DIAGNOSTICS"] == "1"

    static func event(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        try? FileHandle.standardError.write(contentsOf: Data("kokoko drag \(message())\n".utf8))
    }

    static func error(_ stage: String, _ error: Error?) {
        guard let error else { return }
        let value = error as NSError
        event("\(stage) error-domain=\(value.domain) error-code=\(value.code)")
    }
}

#if os(macOS)
struct RowDragHandle: NSViewRepresentable {
    let item: SoundItem
    let state: AppState

    func makeNSView(context: Context) -> Handle {
        let view = Handle()
        RowDragDiagnostics.event("source make id=\(ObjectIdentifier(view))")
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("drag sound to reorder or export")
        return view
    }

    func updateNSView(_ view: Handle, context: Context) {
        view.item = item
        view.state = state
        RowDragDiagnostics.event("source update id=\(ObjectIdentifier(view))")
    }

    final class Handle: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
        var item: SoundItem?
        var state: AppState?
        private var token: RowDragToken?
        private var startEvent: NSEvent?

        init() {
            super.init(frame: .zero)
            RowDragDiagnostics.event("source init id=\(ObjectIdentifier(self))")
        }

        deinit { RowDragDiagnostics.event("source deinit id=\(ObjectIdentifier(self))") }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func draw(_ dirtyRect: NSRect) {
            let glyph = "≡" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height), withAttributes: attributes)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            RowDragDiagnostics.event("source down id=\(ObjectIdentifier(self)) clicks=\(event.clickCount) window=\(event.windowNumber) point=\(event.locationInWindow)")
            startEvent = event
        }

        override func mouseUp(with event: NSEvent) {
            RowDragDiagnostics.event("source up id=\(ObjectIdentifier(self))")
            startEvent = nil
        }

        override func mouseDragged(with event: NSEvent) {
            RowDragDiagnostics.event("source dragged id=\(ObjectIdentifier(self))")
            guard let startEvent else { RowDragDiagnostics.event("source reject=no-down"); return }
            guard let item else { RowDragDiagnostics.event("source reject=no-item"); return }
            guard let state else { RowDragDiagnostics.event("source reject=no-state"); return }
            guard !state.deviceBusy else { RowDragDiagnostics.event("source reject=busy"); return }
            self.startEvent = nil
            let token = RowDragToken(id: item.id)
            self.token = token
            state.rowDrag.begin(token)
            let provider = RowPromise(fileType: UTType.wav.identifier, delegate: self)
            provider.token = token
            provider.userInfo = item
            let drag = NSDraggingItem(pasteboardWriter: provider)
            drag.setDraggingFrame(bounds, contents: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "sound"))
            RowDragDiagnostics.event("source session-request id=\(ObjectIdentifier(self))")
            beginDraggingSession(with: [drag], event: startEvent, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            RowDragDiagnostics.event("source mask id=\(ObjectIdentifier(self)) local=\(context == .withinApplication)")
            return context == .withinApplication ? [.copy, .move] : .copy
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            RowDragDiagnostics.event("source session-begin id=\(ObjectIdentifier(self))")
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            RowDragDiagnostics.event("source session-end id=\(ObjectIdentifier(self)) operation=\(operation.rawValue)")
            if let token { state?.rowDrag.end(token) }
            token = nil
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            RowDragDiagnostics.event("promise name-request id=\(ObjectIdentifier(self))")
            return ((filePromiseProvider.userInfo as? SoundItem)?.displayName ?? "sound") + ".wav"
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            RowDragDiagnostics.event("promise write-request id=\(ObjectIdentifier(self))")
            let item = filePromiseProvider.userInfo as? SoundItem
            let token = (filePromiseProvider as? RowPromise)?.token
            // AppKit supplies an unannotated callback on our main operation queue.
            nonisolated(unsafe) let completion = completionHandler
            MainActor.assumeIsolated {
                guard let state, let item else {
                    RowDragDiagnostics.event("promise reject=no-source")
                    completion(CocoaError(.fileNoSuchFile))
                    return
                }
                if let token { state.rowDrag.end(token) }
                Task { @MainActor in
                    switch await state.download(item) {
                    case .success(let result):
                        do {
                            try Data(result.wav).write(to: url)
                            RowDragDiagnostics.event("promise write-complete success=true")
                            completion(nil)
                        } catch {
                            RowDragDiagnostics.error("promise write", error)
                            completion(error)
                        }
                    case .failure(let error):
                        RowDragDiagnostics.error("promise download", error)
                        completion(error)
                    }
                }
            }
        }
    }
}

private final class RowPromise: NSFilePromiseProvider {
    var token: RowDragToken?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        RowDragDiagnostics.event("promise types-request")
        return super.writableTypes(for: pasteboard) + [.string, NSPasteboard.PasteboardType(UTType.soundRowMove.identifier)]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == .string || type.rawValue == UTType.soundRowMove.identifier { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        RowDragDiagnostics.event("promise representation-request type=\(type.rawValue)")
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
