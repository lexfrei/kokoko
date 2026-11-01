import KokokoLibrary

extension KokokoCoreChecks {
    static func rowGlyphChecks() {
        let expected: [(RowAction, String, String)] = [
            (.play, "[>]", "Play preview"), (.download, "[v]", "Download"), (.rename, "[r]", "Rename"),
            (.renumber, "[#]", "Move to slot"), (.metadata, "[m]", "Edit metadata"), (.delete, "[x]", "Delete"),
            (.restore, "[restore]", "Restore to the device"), (.removeFromBin, "[x]", "Remove from bin"),
            (.downloadArchive, "[v tar]", "Download tar archive"),
        ]
        for (action, glyph, label) in expected {
            eq(action.glyph, glyph, "row glyph: \(label) keeps its glyph")
            eq(action.accessibilityLabel, label, "row glyph: \(glyph) reads as \(label)")
        }
        eq(Set(RowAction.allCases.map(\.accessibilityLabel)).count, RowAction.allCases.count,
           "row glyph: every action reads differently")
        for action in RowAction.allCases {
            check(labelHasEveryWord(action.glyph, action.accessibilityLabel),
                  "row glyph: \(action.glyph) is in its label \"\(action.accessibilityLabel)\"")
        }
        check(!labelHasEveryWord("[ backup sounds ]", "Back up sounds"), "label in name: a word missing from the label is caught")

        eq(tabTitle("sounds", selected: false), "[ sounds ]", "tab: an unselected tab keeps its brackets")
        eq(tabTitle("sounds", selected: true), "[*sounds*]", "tab: the selected tab is marked by a glyph, not color")
        eq(tabTitle("bin", selected: true).count, tabTitle("bin", selected: false).count,
           "tab: marking the selected tab keeps its width")
    }
}
