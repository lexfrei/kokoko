#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KokokoLibrary

struct NativeRowDrop<Content: View>: NSViewControllerRepresentable {
    let item: SoundItem
    let state: AppState
    @Binding var targeted: UInt16?
    let content: Content

    func makeNSViewController(context: Context) -> NativeRowDropController {
        NativeRowDropController()
    }

    func updateNSViewController(_ controller: NativeRowDropController, context: Context) {
        controller.destination.item = item
        controller.destination.state = state
        controller.destination.targeted = $targeted
        controller.hosting.rootView = AnyView(content.environment(\.self, context.environment))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NativeRowDropController, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions(by: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                                      height: CGFloat.greatestFiniteMagnitude))
        return nsViewController.hosting.sizeThatFits(in: size)
    }

    static func dismantleNSViewController(_ controller: NativeRowDropController, coordinator: ()) {
        controller.destination.clearTarget()
    }
}

final class NativeRowDropController: NSViewController {
    let destination = NativeRowDropView()
    let hosting = NSHostingController(rootView: AnyView(EmptyView()))

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        view = destination
        addChild(hosting)
        let content = hosting.view
        content.translatesAutoresizingMaskIntoConstraints = false
        destination.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: destination.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: destination.trailingAnchor),
            content.topAnchor.constraint(equalTo: destination.topAnchor),
            content.bottomAnchor.constraint(equalTo: destination.bottomAnchor),
        ])
    }
}

final class NativeRowDropView: NSView {
    private static let marker = NSPasteboard.PasteboardType(UTType.soundRowMove.identifier)
    weak var state: AppState?
    var item: SoundItem?
    var targeted: Binding<UInt16?> = .constant(nil)
    private var generation: UUID?

    init() {
        super.init(frame: .zero)
        registerForDraggedTypes([Self.marker])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func eligible(_ source: Any?, token: RowDragToken, generation: UUID) -> Bool {
        guard let state, let item, let source = source as? RowDragHandle.Handle else { return false }
        return source.state === state && source.item?.id == token.id
            && generation == state.rowDragGeneration && state.rowDrag.active == token
            && !state.deviceBusy && token.id != item.id
            && state.sounds.contains(where: { $0.id == token.id })
            && state.sounds.contains(where: { $0.id == item.id })
    }

    func receive(_ pasteboard: NSPasteboard, source: Any?, generation: UUID) -> Bool {
        defer {
            clearTarget()
            self.generation = nil
        }
        guard let state, let item, let token = state.rowDrag.active,
              eligible(source, token: token, generation: generation),
              let items = pasteboard.pasteboardItems, items.count == 1,
              let candidate = items.first, candidate.types.contains(Self.marker),
              let data = candidate.data(forType: .string), let text = String(data: data, encoding: .utf8),
              token.matches(text), self.state === state, self.item == item,
              eligible(source, token: token, generation: generation),
              state.rowDrag.claim(target: item.id, busy: state.deviceBusy) == token else { return false }
        state.requestSwap(id: token.id, onto: item)
        return true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        generation = state?.rowDragGeneration
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let token = state?.rowDrag.active, let generation,
              sender.draggingSourceOperationMask.contains(.move),
              eligible(sender.draggingSource, token: token, generation: generation),
              sender.draggingPasteboard.types?.contains(Self.marker) == true else {
            clearTarget()
            return []
        }
        targeted.wrappedValue = item?.id
        return .move
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggingUpdated(sender) == .move
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let generation else { return false }
        return receive(sender.draggingPasteboard, source: sender.draggingSource, generation: generation)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { clearTarget() }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { clearTarget() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clearTarget() }
    }

    func clearTarget() {
        if targeted.wrappedValue == item?.id { targeted.wrappedValue = nil }
    }
}
#endif
