#if os(macOS) && DEBUG
import AppKit
import KokokoLibrary
import SwiftUI

@MainActor
enum RowDragHitChecks {
    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "ok  " : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        for selected: Set<Int> in [[], [1], [1, 2]] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: Rows(selected: selected))
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
            host.layoutSubtreeIfNeeded()
            if let table = descendants(host).compactMap({ $0 as? NSTableView }).first {
                for row in 0..<table.numberOfRows {
                    _ = table.rowView(atRow: row, makeIfNecessary: true)
                    _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
                }
            }
            host.layoutSubtreeIfNeeded()
            let handles = descendants(host).compactMap { $0 as? RowDragHandle.Handle }
            check(handles.count == 3, "drag hit: three real handles, selection \(selected.sorted())")
            for (index, handle) in handles.enumerated() {
                let center = NSPoint(x: handle.bounds.midX, y: handle.bounds.midY)
                let hit = host.hitTest(handle.convert(center, to: host.superview))
                check(hit === handle || hit?.isDescendant(of: handle) == true,
                      "drag hit: handle \(index) owns its center, selection \(selected.sorted())")
                let namePoint = NSPoint(x: handle.bounds.maxX + 40, y: handle.bounds.midY)
                let nameHit = host.hitTest(handle.convert(namePoint, to: host.superview))
                check(nameHit != nil && nameHit !== handle && nameHit?.isDescendant(of: handle) == false,
                      "drag hit: row text remains outside the handle")
            }
            check(!window.isVisible && !window.isKeyWindow && !window.isMainWindow, "drag hit: window was never shown or focused")
            window.close()
        }
        print(failures == 0 ? "drag hit: all checks passed" : "drag hit: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private struct Fixture: NSViewRepresentable {
        func makeNSView(context: Context) -> RowDragHandle.Handle { RowDragHandle.Handle() }
        func updateNSView(_ view: RowDragHandle.Handle, context: Context) {}
    }

    private enum Focus: Hashable { case list, button(Int), slot(Int), metadata(Int) }

    private struct Drop: DropDelegate {
        func performDrop(info: DropInfo) -> Bool { false }
    }

    private struct Rows: View {
        @State var selected: Set<Int>
        @State private var slot = "0"
        @State private var bpm = "120"
        @FocusState private var focus: Focus?

        var body: some View {
            List(selection: $selected) {
                ForEach(soundSections(all: [1, 2, 3], visible: [1, 2, 3])) { section in
                    Section {
                        if section.slots.isEmpty {
                            Text("empty").selectionDisabled()
                        } else {
                            ForEach(section.slots, id: \.self) { slot in
                                let id = Int(slot)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Fixture().frame(width: 28, height: 28)
                                        if selected == [id] {
                                            TextField("slot", text: $slot)
                                                .textFieldStyle(.plain)
                                                .frame(width: 64)
                                                .focused($focus, equals: .slot(id))
                                        } else {
                                            Button("000") {}.buttonStyle(.plain)
                                                .frame(width: 64)
                                                .focused($focus, equals: .slot(id))
                                        }
                                        Text("row \(id)")
                                        Spacer()
                                        Button("play") {}.focused($focus, equals: .button(id))
                                    }
                                    if selected == [id] {
                                        Divider()
                                        HStack {
                                            Text("sound.bpm")
                                            TextField("", text: $bpm)
                                                .textFieldStyle(.plain)
                                                .focused($focus, equals: .metadata(id))
                                        }
                                    }
                                }
                                .tag(id)
                                .onDrop(of: [rowMoveTextType], delegate: Drop())
                            }
                        }
                    } header: {
                        Text(section.title).id(section.id)
                    }
                }
            }
            .focused($focus, equals: .list)
            .onKeyPress(.space, phases: .down) { _ in .ignored }
            .onKeyPress(.return, phases: .down) { _ in .ignored }
            .onDrop(of: [.audio], delegate: Drop())
        }
    }
}
#endif
