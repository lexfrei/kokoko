import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    /// Replays a plan like the device would: a move needs an occupied source
    /// and a free target.
    private static func apply(_ plan: [(from: UInt16, to: UInt16)]?,
                              to slots: [UInt16: String], selected: Set<UInt16>? = nil) -> [UInt16: String]? {
        guard let plan else { return nil }
        var state = slots
        var selection = selected ?? Set(slots.keys)
        let selectedSounds = Set(selection.compactMap { slots[$0] })
        let identities = Set(slots.values)
        for move in plan {
            guard (1...999).contains(move.from), (1...999).contains(move.to),
                  let sound = state[move.from], state[move.to] == nil else { return nil }
            state[move.from] = nil
            state[move.to] = sound
            selection = remapSelection(selection, moves: [move])
            guard Set(state.values) == identities, state.count == slots.count,
                  selection.count == selectedSounds.count,
                  Set(selection.compactMap { state[$0] }) == selectedSounds else { return nil }
        }
        return state
    }

    private static func bulk(_ slots: [UInt16: String], selected: [UInt16],
                             start: UInt16) -> [UInt16: String]? {
        guard let plan = planBulkMove(selected: selected, occupied: Set(slots.keys), start: start)
        else { return nil }
        return apply(plan, to: slots, selected: Set(selected))
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
              "bulk move refuses targets beyond the sound-slot range")
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

        for invalid: UInt16 in [0, 1000, 1001, 65000, 65535] {
            check(planBulkMove(selected: [1], occupied: [1], start: invalid) == nil,
                  "bulk move: rejects a destination outside sound slots")
            check(planBulkMove(selected: [invalid], occupied: [invalid], start: 1) == nil,
                  "bulk move: rejects a source outside sound slots")
            let swap: [(from: UInt16, to: UInt16)]? = planSwap(1, invalid, occupied: [1, invalid])
            check(swap == nil, "swap: rejects either endpoint outside sound slots")
        }
        for missing: UInt16 in [1, 2] {
            check(planSwap(1, 2, occupied: [missing]) == nil, "swap: either missing source refuses the whole plan")
        }
        check(planSwap(1, 1, occupied: [1])?.isEmpty == true, "swap: same occupied slot needs no move")
        check(planBulkMove(selected: [1, 1], occupied: [1], start: 2) == nil,
              "bulk move: duplicate sources cannot produce a colliding plan")
        check(planBulkMove(selected: [2], occupied: [1], start: 3) == nil,
              "bulk move: a missing source refuses the whole plan")
        check(planBulkMove(selected: [1, 2], occupied: [1, 2], start: 999) == nil,
              "bulk move: targets cannot run beyond the last sound slot")
        let full = Set(UInt16(1)...UInt16(999))
        let fullSwap: [(from: UInt16, to: UInt16)]? = planSwap(1, 2, occupied: full)
        check(fullSwap == nil, "swap: a full library has no safe scratch slot")
        check(planBulkMove(selected: [1, 2], occupied: full, start: 1) == nil,
              "bulk move: a full library refuses before any move")
        check(planBulkMove(selected: [1, 2], occupied: full.subtracting([999]), start: 1) == nil,
              "bulk move: one free scratch cannot stage two sounds")
        let oneFree = Dictionary(uniqueKeysWithValues: full.subtracting([999]).map { ($0, String($0)) })
        var swapped = oneFree
        swapped[1] = "2"
        swapped[2] = "1"
        eq(apply(planSwap(1, 2, occupied: Set(oneFree.keys)), to: oneFree), swapped,
           "swap: one free valid scratch suffices in a nearly full library")
        let twoFree = Dictionary(uniqueKeysWithValues: full.subtracting([998, 999]).map { ($0, String($0)) })
        eq(bulk(twoFree, selected: [1, 2], start: 1), twoFree,
           "bulk move: just enough scratch preserves a nearly full library")
        check(planBulkMove(selected: [1], occupied: full.subtracting([999]), start: 999) == nil,
              "bulk move: a reserved final target is not scratch")
        eq(bulk([1: "a", 2: "b", 998: "x", 1000: "root", 65000: "other"], selected: [1, 2], start: 997),
           [997: "a", 998: "x", 999: "b", 1000: "root", 65000: "other"],
           "bulk move: sparse occupancy and global nodes never collide with scratch or targets")

        func pairs(_ steps: [(from: UInt16, to: UInt16)]?) -> [[UInt16]]? { steps?.map { [$0.from, $0.to] } }
        eq(pairs(planSwap(3, 7, occupied: [3, 7])), [[3, 999], [7, 3], [999, 7]],
           "swap: through the first free temporary slot")
        eq(pairs(planSwap(3, 7, occupied: [3, 7, 999, 998, 65000])), [[3, 997], [7, 3], [997, 7]],
           "swap: the temporary slot skips occupied ones")
        eq(apply(planSwap(3, 7, occupied: [3, 7]), to: [3: "kick", 7: "snare"], selected: [3]), [3: "snare", 7: "kick"],
           "swap: replayed like the device, the two sounds trade slots")
    }
}
