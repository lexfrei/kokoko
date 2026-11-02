import CoreGraphics

/// Where items of the given sizes go when laid out left to right and wrapped
/// onto a new line before the item that would pass `maxWidth`; an item wider
/// than `maxWidth` gets a line of its own. Items on a line share its top edge.
public func flowPlacement(sizes: [CGSize], maxWidth: CGFloat,
                          spacing: CGFloat) -> (origins: [CGPoint], size: CGSize) {
    var origins: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var width: CGFloat = 0
    for size in sizes {
        if x > 0, x + size.width > maxWidth {
            x = 0
            y += lineHeight + spacing
            lineHeight = 0
        }
        origins.append(CGPoint(x: x, y: y))
        width = max(width, x + size.width)
        lineHeight = max(lineHeight, size.height)
        x += size.width + spacing
    }
    return (origins, CGSize(width: width, height: sizes.isEmpty ? 0 : y + lineHeight))
}
