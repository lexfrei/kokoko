import SwiftUI
import KokokoLibrary
/// Size of one character of the sheet's monospaced font, measured from hidden
/// text so it follows the text size the way the text does. A single glyph's
/// frame is rounded, so a run of them is measured and divided.
private struct CellSizeKey: PreferenceKey {
    static let sample = String(repeating: "0", count: 100)
    static let defaultValue = CGSize(width: 8, height: 16)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct WaveformSheet: View {
    @ObservedObject var state: AppState
    let shown: WaveformShown
    @State private var cell = CellSizeKey.defaultValue
    private static let barLines: CGFloat = 3
    private static let font = Font.system(.body, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("waveform: \(shown.item.displayName)")
            GeometryReader { geometry in
                let waveform = Waveform(pcm: shown.pcm, channels: shown.channels, sampleRate: shown.sampleRate,
                                        columns: max(Int(geometry.size.width / cell.width), 1),
                                        loopStart: shown.loopStart, loopEnd: shown.loopEnd)
                VStack(alignment: .leading, spacing: 0) {
                    Text(marks(waveform)).lineLimit(1)
                    Canvas { context, size in draw(waveform, in: context, size: size) }
                        .frame(height: cell.height * Self.barLines)
                    Text(waveform.loopDescription).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(waveform.summary)
            }
            .frame(height: cell.height * (Self.barLines + 2))
            HStack {
                Button { Task { await state.audition(shown.item) } } label: {
                    Text(RowAction.play.glyph)
                        .frame(minWidth: 28, minHeight: minHitHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.deviceBusy)
                .accessibilityLabel(RowAction.play.accessibilityLabel)
                Spacer()
                barButton(.close) { state.waveformShown = nil }
            }
        }
        .padding()
        #if os(macOS)
        // A sheet on macOS sizes to its content, and the GeometryReader has none.
        .frame(minWidth: 480)
        #endif
        .font(Self.font)
        .background(
            // This text sits outside the .font above, so it sets the font itself.
            Text(CellSizeKey.sample).font(Self.font).fixedSize().hidden()
                .background(GeometryReader {
                    Color.clear.preference(key: CellSizeKey.self,
                                           value: CGSize(width: $0.size.width / CGFloat(CellSizeKey.sample.count),
                                                         height: $0.size.height))
                })
        )
        .onPreferenceChange(CellSizeKey.self) { cell = $0 }
    }

    private func marks(_ waveform: Waveform) -> String {
        var row = [Character](repeating: " ", count: waveform.peaks.count)
        guard let columns = waveform.loopColumns else { return String(row) }
        row[columns.lowerBound] = "["
        row[columns.upperBound] = columns.count == 1 ? "|" : "]"
        return String(row)
    }

    /// Inside the loop, or everywhere when there is none, bars are filled;
    /// outside it they are outlines, so the loop does not rest on color.
    private func draw(_ waveform: Waveform, in context: GraphicsContext, size: CGSize) {
        let hasLoop = waveform.loopStart != nil
        for (column, peak) in waveform.peaks.enumerated() {
            let height = max(peak * size.height, 1)
            let bar = CGRect(x: CGFloat(column) * cell.width + cell.width * 0.15, y: (size.height - height) / 2,
                             width: cell.width * 0.7, height: height)
            if !hasLoop || waveform.isInsideLoop(column: column) {
                context.fill(Path(bar), with: .foreground)
            } else {
                context.stroke(Path(bar), with: .foreground, lineWidth: 1)
            }
        }
    }
}
