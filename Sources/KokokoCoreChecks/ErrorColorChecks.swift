import KokokoLibrary

extension KokokoCoreChecks {
    static func errorColorChecks() {
        check(abs(contrastRatio(0x000000, 0xFFFFFF) - 21) < 0.01, "contrast: black on white is 21:1")
        check(abs(contrastRatio(0xFFFFFF, 0x000000) - 21) < 0.01, "contrast: the order of the colors does not matter")
        // systemRed as macOS reports it in light appearance.
        check(contrastRatio(0xFF383C, 0xFFFFFF) < 4.5, "contrast: the system red falls short on white")
        // Window background as macOS reports it: white, then 0x1E1E1E in dark appearance.
        check(contrastRatio(ErrorColor.light, 0xFFFFFF) >= 4.5, "contrast: light error text reaches 4.5:1 on white")
        for (background, name) in [(0x1E1E1E, "the dark window"), (0x000000, "black")] {
            check(contrastRatio(ErrorColor.dark, background) >= 4.5, "contrast: dark error text reaches 4.5:1 on \(name)")
        }
    }
}
