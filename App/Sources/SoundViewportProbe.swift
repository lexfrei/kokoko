#if os(macOS) || DEBUG
import SwiftUI
import KokokoLibrary
import KokokoMIDI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SoundViewportContext: Equatable, Sendable {
    let node: FSNode
    let generation: Int
    let session: UUID?
    let content: UUID
    let descriptor: WaveformDescriptor?
}

struct SoundViewportSample: Equatable {
    var rect: CGRect
    var clipped: CGRect
    var attached: Bool
    var active: Bool
    var shown: Bool
    var hidden: Bool
    var blocked: Bool
    var clipCount: Int
    var tracksScroll: Bool
    var owner = UUID()
    var retired = false

    var eligible: Bool {
        attached && active && shown && !hidden && !blocked && tracksScroll && !retired
            && !clipped.isNull && clipped.width > 0 && clipped.height > 0
    }
}

struct SoundViewportProbe: View {
    let slot: UInt16
    let blocked: Bool
    var context: SoundViewportContext? = nil
    var registered: (@MainActor (UInt16, ViewportView) -> Void)? = nil
    let report: @MainActor (UInt16, SoundViewportSample) -> Void

    var body: some View {
        GeometryReader { geometry in
            PlatformViewportProbe(slot: slot, blocked: blocked, context: context, registered: registered,
                                  invalidatedBy: geometry.frame(in: .global), report: report)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if os(macOS)
private struct PlatformViewportProbe: NSViewRepresentable {
    let slot: UInt16
    let blocked: Bool
    let context: SoundViewportContext?
    let registered: (@MainActor (UInt16, ViewportView) -> Void)?
    let invalidatedBy: CGRect
    let report: @MainActor (UInt16, SoundViewportSample) -> Void

    func makeNSView(context: Context) -> ViewportView { ViewportView() }

    func updateNSView(_ view: ViewportView, context: Context) {
        if view.slot != slot || view.context != self.context {
            view.stop()
            view.slot = slot
            view.context = self.context
            view.owner = UUID()
            registered?(slot, view)
        }
        view.blocked = blocked
        view.report = report
        view.observe()
        view.sample()
    }

    static func dismantleNSView(_ view: ViewportView, coordinator: ()) { view.stop() }
}

final class ViewportView: NSView {
    var slot: UInt16?
    var context: SoundViewportContext?
    var owner = UUID()
    var blocked = false
    var report: (@MainActor (UInt16, SoundViewportSample) -> Void)?
    private var observations: [NSObjectProtocol] = []
    private let clipViews = NSHashTable<NSClipView>.weakObjects()
    var clips: [NSClipView] { clipViews.allObjects }
    private(set) var samples = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); sample() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observe(); sample() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observe(); sample() }

    func stop() {
        observations.forEach(NotificationCenter.default.removeObserver)
        observations = []
        clipViews.removeAllObjects()
        if let slot {
            report?(slot, SoundViewportSample(rect: .zero, clipped: .zero, attached: false, active: false,
                                             shown: false, hidden: true, blocked: blocked, clipCount: 0, tracksScroll: false,
                                             owner: owner, retired: true))
        }
        report = nil
        slot = nil
        context = nil
    }

    func observe() {
        observations.forEach(NotificationCenter.default.removeObserver)
        observations = []
        clipViews.removeAllObjects()
        guard let window else { return }
        var ancestor = superview
        while let view = ancestor {
            if let clip = view as? NSClipView { clipViews.add(clip) }
            ancestor = view.superview
        }
        for clip in clips {
            listen(NSView.boundsDidChangeNotification, object: clip)
            listen(NSView.frameDidChangeNotification, object: clip)
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didUpdateNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            listen(name, object: window)
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            listen(name, object: NSApplication.shared)
        }
    }

    private func listen(_ name: Notification.Name, object: AnyObject) {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        })
    }

    func sample() {
        guard let slot else { return }
        samples += 1
        report?(slot, currentSample())
    }

    func currentSample() -> SoundViewportSample {
        let clipped = bounds.intersection(visibleRect)
        var obstructed = blocked
        for clip in clips {
            if let table = clip.documentView as? NSTableView {
                table.enumerateAvailableRowViews { row, _ in
                    if row.isGroupRowStyle && row.convert(row.bounds, to: self).intersects(self.bounds) { obstructed = true }
                }
            }
        }
        return SoundViewportSample(rect: convert(bounds, to: nil), clipped: clipped.isEmpty ? .zero : convert(clipped, to: nil),
                                        attached: window != nil,
                                        active: NSApplication.shared.isActive && window?.isKeyWindow == true,
                                        shown: window?.isVisible == true && window?.isMiniaturized == false,
                                        hidden: isHiddenOrHasHiddenAncestor, blocked: obstructed,
                                        clipCount: clips.count,
                                        tracksScroll: !clips.isEmpty && clips.allSatisfy(\.postsBoundsChangedNotifications), owner: owner)
    }
}
#else
private struct PlatformViewportProbe: UIViewRepresentable {
    let slot: UInt16
    let blocked: Bool
    let context: SoundViewportContext?
    let registered: (@MainActor (UInt16, ViewportView) -> Void)?
    let invalidatedBy: CGRect
    let report: @MainActor (UInt16, SoundViewportSample) -> Void

    func makeUIView(context: Context) -> ViewportView { ViewportView() }
    func updateUIView(_ view: ViewportView, context: Context) {
        if view.slot != slot || view.context != self.context {
            view.stop()
            view.slot = slot
            view.context = self.context
            view.owner = UUID()
            registered?(slot, view)
        }
        view.blocked = blocked
        view.report = report
        view.sample()
    }
    static func dismantleUIView(_ view: ViewportView, coordinator: ()) { view.stop() }
}

final class ViewportView: UIView {
    var slot: UInt16?
    var context: SoundViewportContext?
    var owner = UUID()
    var blocked = false
    var report: (@MainActor (UInt16, SoundViewportSample) -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); sample() }
    override func didMoveToWindow() { super.didMoveToWindow(); sample() }

    func stop() {
        if let slot {
            report?(slot, SoundViewportSample(rect: .zero, clipped: .zero, attached: false, active: false,
                                             shown: false, hidden: true, blocked: blocked, clipCount: 0, tracksScroll: false,
                                             owner: owner, retired: true))
        }
        report = nil
        slot = nil
        context = nil
    }

    func sample() {
        guard let slot else { return }
        var clipped = bounds
        var hidden = isHidden || alpha <= 0
        var count = 0
        var ancestor = superview
        while let view = ancestor {
            hidden = hidden || view.isHidden || view.alpha <= 0
            if view.clipsToBounds { clipped = clipped.intersection(convert(view.bounds, from: view)) }
            if view is UIScrollView { count += 1 }
            ancestor = view.superview
        }
        if let window { clipped = clipped.intersection(convert(window.bounds, from: window)) }
        // Scroll invalidation through this hosted List has not been verified on UIKit.
        let value = SoundViewportSample(rect: convert(bounds, to: window), clipped: convert(clipped, to: window),
                                        attached: window != nil, active: window?.windowScene?.activationState == .foregroundActive,
                                        shown: window?.isHidden == false, hidden: hidden, blocked: blocked,
                                        clipCount: count, tracksScroll: false, owner: owner)
        report?(slot, value)
    }
}
#endif
#endif
