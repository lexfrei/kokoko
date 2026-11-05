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
        for compact in [false, true] {
            for snapshot in [nil, Self.snapshot] {
                let thumbnail = NSHostingView(rootView: WaveformThumbnail(snapshot: snapshot, compact: compact))
                thumbnail.layoutSubtreeIfNeeded()
                check(abs(thumbnail.fittingSize.width - CGFloat(WaveformMiniature.width(compact: compact))) < 0.5,
                      "waveform thumbnail: fixed width, compact \(compact), cached \(snapshot != nil)")
                check(abs(thumbnail.fittingSize.height - minHitHeight) < 0.5,
                      "waveform thumbnail: fixed hit height, compact \(compact), cached \(snapshot != nil)")
            }
        }
        for expanded in [false, true] {
            for selected: Set<Int> in [[], [1], [1, 2]] {
                let height: CGFloat = expanded ? 480 : 300
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: height),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: Rows(selected: selected, expanded: expanded))
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: 600, height: height)
                host.layoutSubtreeIfNeeded()
                if let table = descendants(host).compactMap({ $0 as? NSTableView }).first {
                    for row in 0..<table.numberOfRows {
                        _ = table.rowView(atRow: row, makeIfNecessary: true)
                        _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
                    }
                }
                host.layoutSubtreeIfNeeded()
                let handles = descendants(host).compactMap { $0 as? RowDragHandle.Handle }
                check(handles.count == 3, "drag hit: three real handles, selection \(selected.sorted()), expanded \(expanded)")
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
        }
        print(failures == 0 ? "drag hit: all checks passed" : "drag hit: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    private static let snapshot: WaveformRowSnapshot = {
        var rows = WaveformRows()
        let record = WaveformPeakRecord(pcm: [0, 0, 0, 128], channels: 1, sampleRate: 46875)!
        rows.remember(slot: 1, size: 4, record: record)
        return rows.snapshot(slot: 1, size: 4)!
    }()

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
        let expanded: Bool
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
                                        Button {} label: { WaveformThumbnail(snapshot: RowDragHitChecks.snapshot, compact: false) }
                                            .buttonStyle(.plain)
                                        Button("play") {}.focused($focus, equals: .button(id))
                                    }
                                    if expanded, id == 2 {
                                        WaveformBars(waveform: Waveform(record: RowDragHitChecks.snapshot.record, columns: 40,
                                                                       loopStart: 0, loopEnd: 1))
                                            .frame(height: 64)
                                        Text("loop from 0.00 s to 0.00 s")
                                        HStack { Button("[ refresh ]") {}; Button("[ close ]") {} }
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
