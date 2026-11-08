import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    /// Device rules for a move: occupied source, free target.
    private static func applyStrict(_ moves: [(from: UInt16, to: UInt16)],
                                    to slots: inout [UInt16: String]) -> Bool {
        for move in moves {
            guard (1...999).contains(move.from), (1...999).contains(move.to),
                  let sound = slots[move.from], slots[move.to] == nil else { return false }
            slots[move.from] = nil
            slots[move.to] = sound
        }
        return true
    }

    static func rollbackChecks() {
        // The last two put targets inside the selection, the overlap a blind
        // undo gets wrong when the failed move ran.
        let cases: [(slots: [UInt16: String], selected: [UInt16], start: UInt16)] = [
            ([10: "a", 11: "b", 20: "x"], [10, 11], 20),
            ([2: "a", 3: "b", 4: "c", 6: "d"], [2, 3, 4, 6], 4),
            ([5: "a", 8: "b", 6: "x"], [5, 8], 5),
        ]
        var restored = true
        var neverIntoOccupied = true
        var setUp = true
        for testCase in cases {
            guard let plan = planBulkMove(selected: testCase.selected,
                                          occupied: Set(testCase.slots.keys), start: testCase.start)
            else { restored = false; continue }
            for failedIndex in plan.indices {
                // The device either refused the failing move or ran it and the reply was lost.
                for landed in [false, true] {
                    var state = testCase.slots
                    let confirmed = Array(plan.prefix(failedIndex))
                    if !applyStrict(confirmed + (landed ? [plan[failedIndex]] : []), to: &state) {
                        setUp = false
                    }
                    let occupied = Set(state.keys)
                    let failed = plan[failedIndex]
                    var done = confirmed
                    if stepLanded(failed, occupied: occupied) { done.append(failed) }
                    let undo = rollbackMoves(done, occupied: occupied)
                    let selection = remapSelection(Set(testCase.selected), moves: done)
                    if !applyStrict(undo, to: &state) { neverIntoOccupied = false }
                    if state != testCase.slots || remapSelection(selection, moves: undo) != Set(testCase.selected) { restored = false }
                }
            }
        }
        check(setUp, "rollback: every simulated failure state is reachable")
        check(neverIntoOccupied, "rollback: no undo targets an occupied slot, even when the failed move ran")
        check(restored, "rollback: every failure point of a bulk move ends with all sounds back")

        check(rollbackMoves([(from: 1, to: 2)], occupied: [1, 2]).isEmpty,
              "rollback: stops before moving into an occupied slot")
        check(rollbackMoves([(from: 1, to: 2)], occupied: []).isEmpty,
              "rollback: stops when the sound to return is gone")
        check(rollbackMoves([], occupied: [1]).isEmpty, "rollback: nothing to undo")

        if let plan = planSwap(5, 8, occupied: [5, 8, 999]) {
            for count in 0...plan.count {
                var slots: [UInt16: String] = [5: "a", 8: "b", 999: "x"]
                let done = Array(plan.prefix(count))
                check(applyStrict(done, to: &slots), "rollback: every swap prefix is collision free")
                let undo = rollbackMoves(done, occupied: Set(slots.keys))
                check(applyStrict(undo, to: &slots) && slots == [5: "a", 8: "b", 999: "x"],
                      "rollback: every swap prefix returns all sounds through valid slots")
                check(remapSelection(remapSelection([5], moves: done), moves: undo) == [5],
                      "rollback: every swap prefix returns the selected sound")
            }
        } else { check(false, "rollback: swap fixture has valid scratch") }
        for invalid: UInt16 in [0, 1000, 1001, 65000] {
            check(undoMoves([(from: invalid, to: 2)]).isEmpty && undoMoves([(from: 1, to: invalid)]).isEmpty,
                  "undo: out-of-domain endpoints refuse the whole reversal")
            check(rollbackMoves([(from: invalid, to: 2)], occupied: [2]).isEmpty,
                  "rollback: an invalid original source cannot become an undo target")
            check(rollbackMoves([(from: 1, to: invalid)], occupied: [invalid]).isEmpty,
                  "rollback: an invalid scratch cannot become an undo source")
        }
        let swap: [(from: UInt16, to: UInt16)] = [(5, 999), (8, 5)]
        check(remapSelection(remapSelection([5], moves: swap), moves: undoMoves(swap)) == [5],
              "rollback: the selection returns with the sounds")
    }
}
