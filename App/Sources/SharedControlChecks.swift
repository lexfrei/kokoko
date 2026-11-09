#if os(macOS) && DEBUG
    import AppKit
    import ASCIIUI
    import SwiftUI
    import KokokoLibrary
    @testable import KokokoMIDI

    @MainActor
    enum SharedControlChecks {
        private static var failures = 0

        static func run() -> Int32 {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let _: ASCIIButton = barButton(.refresh) {}
            checkFontScale()
            checkCaptionColumns()
            for size: DynamicTypeSize in [.large, .accessibility2] {
                for dark in [false, true] {
                    checkBars(size: size, dark: dark)
                    checkWorkspace(size: size, dark: dark)
                }
            }
            print(
                failures == 0
                    ? "shared controls: all checks passed" : "shared controls: \(failures) check(s) failed")
            return failures == 0 ? 0 : 1
        }

        private static func checkBars(size: DynamicTypeSize, dark: Bool) {
            var calls = 0
            let content = VStack {
                ForEach(Array(BarAction.allCases.enumerated()), id: \.offset) { _, action in
                    barButton(action) { calls += 1 }
                }
            }.font(.system(.body, design: .monospaced)).dynamicTypeSize(size)
                .environment(\.colorScheme, dark ? .dark : .light)
            render(content, width: 840) { host in
                let controls = buttons(host)
                check(
                    controls.count == BarAction.allCases.count, "bar renderer creates shared native controls")
                for (control, action) in zip(controls, BarAction.allCases) {
                    check(
                        ASCIICaption.button(action.title) == action.text,
                        "bar caption remains literal: \(action)")
                    check(
                        control.bounds.height >= PopupMetrics.macOS.minimumTargetHeight,
                        "bar target keeps minimum height")
                    control.performClick(nil)
                }
                check(calls == BarAction.allCases.count, "bar callbacks invoke once per control")
            }
        }

        private static func checkFontScale() {
            var widths: [CGFloat] = []
            for fontSize: CGFloat in [13, 26] {
                let content = barButton(.refresh) {}.font(.system(size: fontSize, design: .monospaced))
                render(content, width: 840) { host in
                    guard let control = buttons(host).first else {
                        check(false, "scaled bar has a native control")
                        return
                    }
                    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                    let required = (ASCIICaption.button(BarAction.refresh.title) as NSString).size(
                        withAttributes: [.font: font]).width
                    check(
                        control.bounds.width >= required && control.bounds.width < required + 1,
                        "shared button inherits parent font scale without clipping")
                    widths.append(control.bounds.width)
                    for x in [CGFloat(1), control.bounds.midX, control.bounds.maxX - 1] {
                        let point = NSPoint(x: x, y: control.bounds.midY)
                        let hit = host.hitTest(control.convert(point, to: host.superview))
                        check(
                            hit === control || hit?.isDescendant(of: control) == true,
                            "scaled button owns its full horizontal hit target")
                    }
                }
            }
            check(
                widths.count == 2 && widths[1] > widths[0] * 1.9,
                "parent font enlargement changes actual control width")
        }

        private static func checkCaptionColumns() {
            for fontSize: CGFloat in [13, 26] {
                let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                let cell = (CellSizeKey.sample as NSString).size(withAttributes: [.font: font])
                let columns = SoundColumns(
                    width: 840, cell: CGSize(width: cell.width / CGFloat(CellSizeKey.sample.count), height: cell.height))
                for action in [RowAction.play, .actions] {
                    render(
                        ASCIIButton(action.title, accessibilityLabel: action.accessibilityLabel) {}.font(
                            .system(size: fontSize, design: .monospaced)), width: 840
                    ) { host in
                        guard let control = buttons(host).first else {
                            check(false, "caption column has a native control")
                            return
                        }
                        let width =
                            action == .actions
                            ? SoundColumns(
                                width: 420, cell: CGSize(width: cell.width / CGFloat(CellSizeKey.sample.count), height: cell.height)
                            ).actions : columns.action
                        check(width >= control.bounds.width, "column contains actual shared caption at parent font scale")
                    }
                }
            }
        }

        private static func checkWorkspace(size: DynamicTypeSize, dark: Bool) {
            let item = SoundItem(
                node: FSNode(id: 1, parentID: 10, name: "1", flags: 0xff, size: 4), displayName: "fixture")
            let state = AppState(listedSounds: [item])
            state.connection = .connected(deviceName: "fixture", serial: "fixture", osVersion: "test")
            let probe = SoundRangeTabProbe()
            let content = ContentView(
                state: state, suppressDeviceObservationForCheck: true, rangeTabProbeForCheck: probe
            )
            .dynamicTypeSize(size).environment(\.colorScheme, dark ? .dark : .light)
            render(content, width: 1100) { host in
                let controls = buttons(host)
                check(
                    controls.count >= HeaderTab.allCases.count + SoundRange.all.count + 1 + 5,
                    "workspace renders shared controls and native range adapters")
                let headerWidths = controls.prefix(HeaderTab.allCases.count).map { $0.bounds.width }
                state.view = .bin
                settle(host)
                check(
                    buttons(host).prefix(HeaderTab.allCases.count).map { $0.bounds.width } == headerWidths,
                    "header selection preserves actual rendered widths")
                state.view = .sounds
                settle(host)
                let initial = probe.frames["sound-range-all"]
                probe.actions[.rangeJump(0)]?()
                settle(host)
                check(
                    probe.frames["sound-range-all"] == initial,
                    "range selection preserves actual rendered geometry")
                check(state.soundRange == SoundRange.all[0], "shared range callback retains exact scope")
                for control in buttons(host) {
                    for x in [CGFloat(1), control.bounds.midX, control.bounds.maxX - 1] {
                        for y in [CGFloat(1), control.bounds.midY, control.bounds.maxY - 1] {
                            let point = NSPoint(x: x, y: y)
                            let hit = control.hitTest(control.convert(point, to: control.superview))
                            check(
                                hit === control || hit?.isDescendant(of: control) == true,
                                "shared control owns its complete rectangular hit target")
                        }
                    }
                }
            }
        }

        private static func render<Content: View>(
            _ content: Content, width: CGFloat, checkBody: (NSView) -> Void
        ) {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: content)
            window.contentView = host
            host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            settle(host)
            checkBody(host)
            check(
                !window.isVisible && !window.isKeyWindow && !window.isMainWindow,
                "shared checks stay hidden and inactive")
            window.contentView = nil
            window.close()
        }

        private static func settle(_ host: NSView) {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
        }

        private static func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }

        private static func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "ok  " : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
    }
#endif
