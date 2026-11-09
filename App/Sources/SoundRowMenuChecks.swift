#if os(macOS) && DEBUG
    import AppKit
    import ASCIIUI
    import SwiftUI
    import KokokoLibrary
    @testable import KokokoMIDI

    @MainActor
    final class SoundRowMenuProbe {
        var open: ((UInt16) -> Void)?
        var activate: ((Int?) -> Void)?
        var dismiss: (() -> Void)?
        var menu: PopupMenuState?
        var frames: [String: CGRect] = [:]
        var focus: SoundFocus?
    }

    @MainActor
    enum SoundRowMenuChecks {
        private static var failures = 0
        private static let item = SoundItem(
            node: FSNode(id: 1, parentID: 10, name: "1", flags: 0xff, size: 4), displayName: "fixture")

        static func run() -> Int32 {
            NSApplication.shared.setActivationPolicy(.prohibited)
            for (size, dark) in [
                (DynamicTypeSize.large, false), (.large, true), (.accessibility2, false), (.accessibility2, true),
            ] {
                fixture(size: size, dark: dark) { state, probe, host in
                    let anchor = probe.frames["row-menu-1"]
                    probe.open?(1)
                    settle(host)
                    check(probe.menu?.items.compactMap { $0 }.count == 5, "shared menu preserves row commands")
                    check(anchor != nil && probe.menu?.anchor == anchor, "menu freezes its trigger anchor")
                    check(
                        probe.frames["popup-panel"].map { host.bounds.contains($0) } == true, "panel stays inside host")
                    check(probe.frames["row-menu-1"] == anchor, "opening menu does not move its row")
                    probe.dismiss?()
                    settle(host)
                    check(probe.menu == nil && probe.focus == .rowMenu(1), "cancel restores trigger focus")
                    probe.open?(1)
                    settle(host)
                    probe.activate?(2)
                    settle(host)
                    check(probe.menu == nil && state.inlineRename?.id == 1, "menu dismisses before rename action")
                    check(probe.focus == .rename(1), "rename retains editor focus")
                }
            }
            for refusedAction in ["metadata", "rename"] {
                fixture { state, probe, host in
                    if refusedAction == "metadata" {
                        state.beginInlineRename(item)
                    } else {
                        state.metadataEditing = InlineMetadataEdit(id: item.id, name: item.displayName, generation: 0)
                    }
                    settle(host)
                    let renameSession = state.inlineRename?.session
                    let metadataSession = state.metadataEditing?.session
                    probe.open?(1)
                    settle(host)
                    check(probe.menu != nil, "refused \(refusedAction): menu opens over the existing editor")
                    probe.activate?(refusedAction == "metadata" ? 3 : 2)
                    settle(host)
                    check(probe.menu == nil, "refused \(refusedAction): menu dismisses")
                    check(
                        state.inlineRename?.session == renameSession && state.metadataEditing?.session == metadataSession,
                        "refused \(refusedAction): existing editor is preserved")
                    check(probe.focus == .rowMenu(item.id), "refused \(refusedAction): focus returns to the trigger")
                }
            }
            for ready in [false, true] {
                fixture { state, probe, host in
                    state.selection = [item.id]
                    var edit = InlineMetadataEdit(id: item.id, name: item.displayName, generation: 0)
                    _ = edit.loaded(request: edit.request!, metadata: ready ? [:] : nil, error: ready ? nil : "fixture read failed")
                    state.metadataEditing = edit
                    settle(host)
                    probe.open?(1)
                    settle(host)
                    probe.activate?(3)
                    settle(host)
                    check(
                        probe.menu == nil && state.metadataEditing?.session == edit.session,
                        "metadata handoff preserves the existing session")
                    let expected: SoundFocus = ready ? .metadataField(edit.session, MetadataEditForm.keys[0]) : .rowMenu(item.id)
                    check(probe.focus == expected, "metadata handoff restores focus unless a ready editor receives it")
                }
            }
            for invalidation in ["busy", "disconnect", "removed", "replaced"] {
                fixture { state, probe, host in
                    probe.open?(1)
                    settle(host)
                    check(probe.menu != nil, "\(invalidation): fixture opens menu")
                    switch invalidation {
                    case "busy": check(state.enterDevice(), "busy fixture acquires admission without I/O")
                    case "disconnect": state.connection = .idle
                    case "removed": state.sounds = []
                    default:
                        state.sounds = [SoundItem(node: item.node, displayName: "replacement")]
                    }
                    probe.activate?(2)
                    settle(host)
                    check(state.inlineRename == nil && probe.menu == nil, "\(invalidation): stale action is refused")
                }
            }
            print(failures == 0 ? "row menu: all checks passed" : "row menu: \(failures) check(s) failed")
            return failures == 0 ? 0 : 1
        }

        private static func fixture(
            size: DynamicTypeSize = .large, dark: Bool = false,
            _ checkBody: (AppState, SoundRowMenuProbe, NSView) -> Void
        ) {
            let state = AppState(listedSounds: [item])
            state.connection = .connected(deviceName: "fixture", serial: "fixture", osVersion: "test")
            let probe = SoundRowMenuProbe()
            let host = NSHostingView(
                rootView: ContentView(
                    state: state, suppressDeviceObservationForCheck: true, rowMenuProbeForCheck: probe
                ).dynamicTypeSize(size).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 420, height: 700), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = CGRect(x: 0, y: 0, width: 420, height: 700)
            settle(host)
            checkBody(state, probe, host)
            check(!window.isVisible && !window.isKeyWindow && !window.isMainWindow, "checks stay hidden and inactive")
            probe.open = nil
            probe.activate = nil
            probe.dismiss = nil
            window.contentView = nil
            window.close()
        }

        private static func settle(_ host: NSView) {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
        }

        private static func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "ok  " : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
    }
#endif
