import SwiftUI
import KokokoLibrary

/// A glyph run avoids the rounding error of measuring a single character.
private struct CellSizeKey: PreferenceKey {
    static let sample = String(repeating: "0", count: 100)
    static let defaultValue = CGSize(width: 8, height: 16)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct WaveformThumbnail: View {
    let snapshot: WaveformRowSnapshot?
    let compact: Bool

    var body: some View {
        Group {
            if let snapshot, !compact {
                VStack(spacing: 0) {
                    WaveformBars(waveform: Waveform(record: snapshot.record, columns: WaveformMiniature.columns,
                                                    loopStart: nil, loopEnd: nil))
                        .frame(height: 12)
                    Text(snapshot.cached ? "unverified" : "read").font(.caption2).lineLimit(1)
                }
            } else {
                Text(snapshot?.cached == true ? "[~]?" : WaveformMiniature.placeholder)
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
        }
        .frame(width: CGFloat(WaveformMiniature.width(compact: compact)), height: minHitHeight)
        .contentShape(Rectangle())
    }
}

struct WaveformDetail: View {
    @ObservedObject var state: AppState
    let shown: WaveformShown
    let focus: FocusState<SoundFocus?>.Binding
    let close: () -> Void
    @State private var cell = CellSizeKey.defaultValue
    private static let barLines: CGFloat = 3
    private static let font = Font.system(.body, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("waveform: \(shown.item.displayName)")
            Text(shown.record == nil ? "audio not loaded" : shown.cached ? "cached audio · unverified" : "audio read from device")
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                if let record = shown.record {
                    let waveform = Waveform(record: record, columns: max(Int(geometry.size.width / cell.width), 1),
                                            loopStart: shown.loopStart, loopEnd: shown.loopEnd)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(marks(waveform)).lineLimit(1)
                        WaveformBars(waveform: waveform, cellWidth: cell.width)
                            .frame(height: cell.height * Self.barLines)
                        Text(shown.metadataConfirmed ? waveform.loopDescription : "loop metadata not read")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel((shown.cached ? "Cached, unverified. " : "")
                                        + (shown.metadataConfirmed ? waveform.summary : "Waveform. Loop metadata not read"))
                } else {
                    Text("reading waveform…").foregroundStyle(.secondary)
                }
            }
            .frame(height: cell.height * (Self.barLines + 2))
            HStack {
                Button { state.requestAudition(shown.item) } label: {
                    Text(RowAction.play.glyph)
                        .frame(minWidth: 28, minHeight: minHitHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused(focus, equals: .waveformPlay(shown.id))
                .disabled(state.deviceBusy)
                .accessibilityLabel(RowAction.play.accessibilityLabel)
                barButton(.refresh) { Task { await state.showWaveform(shown.item, forceRefresh: true) } }
                    .focused(focus, equals: .waveformRefresh(shown.id))
                    .disabled(state.deviceBusy)
                    .accessibilityLabel("Read this sound's audio again")
                Spacer()
                barButton(.close, perform: close)
                    .focused(focus, equals: .waveformClose(shown.id))
            }
        }
        .padding(.vertical, 8)
        .font(Self.font)
        .background(
            Text(CellSizeKey.sample).font(Self.font).fixedSize().hidden()
                .background(GeometryReader {
                    Color.clear.preference(key: CellSizeKey.self,
                                           value: CGSize(width: $0.size.width / CGFloat(CellSizeKey.sample.count),
                                                         height: $0.size.height))
                })
        )
        .onPreferenceChange(CellSizeKey.self) { cell = $0 }
        .onKeyPress(.escape, phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            close()
            return .handled
        }
    }

    private func marks(_ waveform: Waveform) -> String {
        var row = [Character](repeating: " ", count: waveform.peaks.count)
        guard let columns = waveform.loopColumns else { return String(row) }
        row[columns.lowerBound] = "["
        row[columns.upperBound] = columns.count == 1 ? "|" : "]"
        return String(row)
    }
}

struct WaveformBars: View {
    let waveform: Waveform
    var cellWidth: CGFloat?

    var body: some View {
        Canvas { context, size in
            let width = cellWidth ?? size.width / CGFloat(max(waveform.peaks.count, 1))
            let hasLoop = waveform.loopStart != nil
            for (column, peak) in waveform.peaks.enumerated() {
                let height = max(peak * size.height, 1)
                let bar = CGRect(x: CGFloat(column) * width + width * 0.15, y: (size.height - height) / 2,
                                 width: width * 0.7, height: height)
                if !hasLoop || waveform.isInsideLoop(column: column) {
                    context.fill(Path(bar), with: .foreground)
                } else {
                    context.stroke(Path(bar), with: .foreground, lineWidth: 1)
                }
            }
        }
    }
}
