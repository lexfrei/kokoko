import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func filterChecks() {
        check(soundMatches(name: "micro kick", slot: 1, query: ""), "filter empty matches all")
        check(soundMatches(name: "micro kick", slot: 1, query: "   "), "filter blank matches all")

        check(soundMatches(name: "micro kick", slot: 1, query: "KICK"), "filter name case-insensitive")
        check(!soundMatches(name: "micro kick", slot: 1, query: "snare"), "filter name miss")

        check(soundMatches(name: "x", slot: 120, query: "12"), "filter slot prefix 120")
        check(soundMatches(name: "x", slot: 12, query: "12"), "filter exact slot 12")
        check(!soundMatches(name: "x", slot: 212, query: "12"), "filter slot 212 not matched by 12")
        check(soundMatches(name: "x", slot: 7, query: "00"), "filter 00 matches 007")
        check(soundMatches(name: "x", slot: 7, query: "007"), "filter padded exact")
        check(!soundMatches(name: "x", slot: 10, query: "1"), "filter 1 does not find 010")
        check(soundMatches(name: "x", slot: 10, query: "01"), "filter 01 finds 010")
        check(!soundMatches(name: "x", slot: 1, query: "01"), "filter 01 does not find 001")
        check(soundMatches(name: "808 kick", slot: 42, query: "808"), "filter digit query also matches name")

        check(soundMatches(name: "kick 9x9 dirt", slot: 11, query: "9x9"), "filter mixed query goes by name")
        check(!soundMatches(name: "kick", slot: 909, query: "9x9"), "filter mixed query never hits slot")

        // Rename inside a filtered list: slot 2 no longer matches and must leave the selection.
        let afterRename: [(slot: UInt16, name: String)] = [(1, "kick a"), (2, "snare"), (3, "kick c")]
        eq(visibleSelection([1, 2, 3], items: afterRename, query: "kick"), [1, 3],
           "selection drops rows hidden by the filter")
        eq(visibleSelection([1, 2, 3], items: afterRename, query: ""), [1, 2, 3],
           "selection kept without a filter")
        eq(visibleSelection([1, 9], items: afterRename, query: ""), [1],
           "selection drops slots that no longer exist")
    }
}
