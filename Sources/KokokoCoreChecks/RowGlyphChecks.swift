import KokokoLibrary

extension KokokoCoreChecks {
    static func rowGlyphChecks() {
        let expected: [(RowAction, String, String)] = [
            (.play, "[>]", "Play preview"), (.download, "[v]", "Download"), (.rename, "[r]", "Rename"),
            (.metadata, "[m]", "Edit metadata"), (.delete, "[x]", "Delete"),
            (.restore, "[restore]", "Restore to the device"), (.removeFromBin, "[x]", "Remove from bin"),
            (.downloadArchive, "[v tar]", "Download tar archive"),
            (.waveform, "[~]", "Show waveform"), (.actions, "[...]", "Actions"),
        ]
        for (action, glyph, label) in expected {
            eq(action.glyph, glyph, "row glyph: \(label) keeps its glyph")
            eq(action.accessibilityLabel, label, "row glyph: \(glyph) reads as \(label)")
        }
        check(!RowAction.allCases.map(\.glyph).contains("[#]"), "slot number replaces the redundant bracketed move action")
        eq(slotNumberLabel(32), "Move to slot, current slot 032", "slot number: label includes the visible padded number")
        eq(slotNumberLabel(65535), "Move to slot, current slot 65535", "slot number: label preserves large slot ids")
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
