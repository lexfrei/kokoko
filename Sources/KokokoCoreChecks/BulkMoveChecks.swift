import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    /// Replays a plan like the device would: a move needs an occupied source
    /// and a free target.
    private static func apply(_ plan: [(from: UInt16, to: UInt16)],
                              to slots: [UInt16: String]) -> [UInt16: String]? {
        var state = slots
        for move in plan {
            guard let sound = state[move.from], state[move.to] == nil else { return nil }
            state[move.from] = nil
            state[move.to] = sound
        }
        return state
    }

    private static func bulk(_ slots: [UInt16: String], selected: [UInt16],
                             start: UInt16) -> [UInt16: String]? {
        guard let plan = planBulkMove(selected: selected, occupied: Set(slots.keys), start: start)
        else { return nil }
        return apply(plan, to: slots)
    }

    static func bulkMoveChecks() {
        eq(bulk([10: "a", 11: "b"], selected: [10, 11], start: 10), [10: "a", 11: "b"],
           "bulk move onto its own slots leaves nothing in temporary slots")
        eq(bulk([5: "a", 7: "b"], selected: [7, 5], start: 5), [5: "a", 6: "b"],
           "bulk move starting at a selected slot keeps sorted order")
        eq(bulk([2: "a", 3: "b", 10: "x"], selected: [2, 3], start: 10), [10: "x", 11: "a", 12: "b"],
           "bulk move skips slots held by unselected sounds")
        eq(bulk([10: "a", 12: "b", 11: "x"], selected: [10, 12], start: 10), [10: "a", 11: "x", 12: "b"],
           "bulk move around an unselected sound in the target range")

        let once = bulk([3: "a", 9: "b"], selected: [3, 9], start: 20)
        eq(once, [20: "a", 21: "b"], "bulk move to a free range")
        eq(once.flatMap { bulk($0, selected: [20, 21], start: 20) }, once,
           "repeating a bulk move is a no-op")

        check(planBulkMove(selected: [1, 2], occupied: [1, 2], start: 65534) == nil,
              "bulk move refuses targets that would wrap or reach temporary slots")
        check(planBulkMove(selected: [], occupied: [1], start: 1)?.isEmpty == true,
              "bulk move of nothing is empty")

        let slots: [UInt16: String] = [10: "a", 11: "b", 30: "c"]
        if let plan = planBulkMove(selected: [10, 11, 30], occupied: Set(slots.keys), start: 10),
           let final = apply(plan, to: slots) {
            let selectedAfter = remapSelection([10, 11, 30], moves: plan)
            eq(selectedAfter, Set(final.keys), "selection follows every sound through a bulk move")
        } else {
            check(false, "selection follows every sound through a bulk move")
        }
    }
}
