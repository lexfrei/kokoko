import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func selectionChecks() {
        eq(remapSelection([5], moves: [(from: 5, to: 9)]), [9], "selection follows a renumbered sound")
        eq(remapSelection([5, 7], moves: [(from: 3, to: 4)]), [5, 7], "selection ignores unrelated moves")

        // Drag swap of selected 5 onto unselected 8, through a temporary slot.
        let swap: [(from: UInt16, to: UInt16)] = [(5, 65000), (8, 5), (65000, 8)]
        eq(remapSelection([5], moves: swap), [8], "selection follows a swapped sound")
        eq(remapSelection([8], moves: swap), [5], "selection follows the swap partner")
        eq(remapSelection([5, 8], moves: swap), [5, 8], "selection keeps both swapped sounds")

        // Bulk move of 2 and 3 to 10, 11.
        let bulk: [(from: UInt16, to: UInt16)] = [(2, 65000), (3, 64999), (65000, 10), (64999, 11)]
        eq(remapSelection([2, 3, 6], moves: bulk), [10, 11, 6], "selection follows a bulk move")

        eq(remapSelection([4], moves: [(from: 1, to: 4)]), [],
           "an unselected sound landing on a stale selected slot is not selected")
    }
}
