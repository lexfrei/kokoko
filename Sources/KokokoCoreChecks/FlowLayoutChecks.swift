import CoreGraphics
import KokokoLibrary

extension KokokoCoreChecks {
    static func flowLayoutChecks() {
        let three = [CGSize(width: 40, height: 10), CGSize(width: 40, height: 20), CGSize(width: 40, height: 10)]
        let wide = flowPlacement(sizes: three, maxWidth: 200, spacing: 8)
        eq(wide.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 48, y: 0), CGPoint(x: 96, y: 0)],
           "flow: items that fit stay on one line")
        eq(wide.size, CGSize(width: 136, height: 20), "flow: one line is as tall as its tallest item")

        let narrow = flowPlacement(sizes: three, maxWidth: 100, spacing: 8)
        eq(narrow.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 48, y: 0), CGPoint(x: 0, y: 28)],
           "flow: the item that would pass the width starts the next line, below the tallest item and the spacing")
        eq(narrow.size, CGSize(width: 88, height: 38), "flow: the size spans every line")

        let exact = flowPlacement(sizes: three, maxWidth: 136, spacing: 8)
        eq(exact.origins.map(\.y), [0, 0, 0], "flow: an item ending exactly at the width stays on the line")

        let oversized = flowPlacement(sizes: [CGSize(width: 30, height: 10), CGSize(width: 300, height: 10),
                                              CGSize(width: 30, height: 10)], maxWidth: 100, spacing: 8)
        eq(oversized.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 18), CGPoint(x: 0, y: 36)],
           "flow: an item wider than the width gets a line of its own")
        eq(oversized.size, CGSize(width: 300, height: 46), "flow: an oversized item widens the size")

        let empty = flowPlacement(sizes: [], maxWidth: 100, spacing: 8)
        check(empty.origins.isEmpty && empty.size == .zero, "flow: no items take no space")
    }
}
