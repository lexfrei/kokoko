import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func barActionChecks() {
        let all = BarAction.allCases
        eq(all.filter { !$0.text.hasPrefix("[ ") || !$0.text.hasSuffix(" ]") }, [], "bar: every button keeps the bracketed text style")
        eq(Set(all.map(\.text)).count, all.count, "bar: no two buttons share a text")
        eq(Set(all.map(\.accessibilityLabel)).count, all.count, "bar: no two buttons share a label")
        let symbols = CharacterSet(charactersIn: "[]+!*#>")
        eq(all.filter { $0.accessibilityLabel.isEmpty || $0.accessibilityLabel.rangeOfCharacter(from: symbols) != nil }, [],
           "bar: every button has a label without brackets or symbols")
        // WCAG 2.5.3, Label in Name: every word on the button is in its label.
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 })
        }
        func labelHasEveryWord(_ text: String, _ label: String) -> Bool { words(text).isSubset(of: words(label)) }
        for action in all {
            check(labelHasEveryWord(action.text, action.accessibilityLabel), "bar: \(action.text) is in its label \"\(action.accessibilityLabel)\"")
        }
        for line in [StatusLine.error("upload: kick.wav: storage full"), .connectionFailed("no device found")] {
            check(labelHasEveryWord(line.text, line.accessibilityLabel), "status: \(line.text) is in its label \"\(line.accessibilityLabel)\"")
        }
        eq(BarAction.addSounds.text, "[ + add sounds ]", "bar: add sounds keeps its text")
        eq(BarAction.deleteSelection.accessibilityLabel, "Delete selected", "bar: the footer [ x ] is read as Delete selected")
        eq(BarAction.downloadSelection.accessibilityLabel, "Download to folder", "bar: the footer [ v to folder ] is read as Download to folder")
        eq(BarAction.backupSounds.text, "[ back up sounds ]", "bar: back up is the verb, two words")
    }
}
