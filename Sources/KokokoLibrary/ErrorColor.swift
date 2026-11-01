import Foundation

/// Error text colors as 0xRRGGBB. The system red is under the 4.5:1 that
/// text needs on a white background, so light appearance gets a darker red.
public enum ErrorColor {
    public static let light = 0xC4_1E_14
    public static let dark = 0xFF_45_3A
}

/// WCAG 2 contrast ratio between two 0xRRGGBB colors, from 1 to 21.
public func contrastRatio(_ a: Int, _ b: Int) -> Double {
    func luminance(_ rgb: Int) -> Double {
        func channel(_ shift: Int) -> Double {
            let c = Double((rgb >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
    let (la, lb) = (luminance(a), luminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}
