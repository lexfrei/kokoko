import Foundation

/// Conservative application policy for sound moves, not global filesystem node IDs.
public let soundMoveSlots: ClosedRange<UInt16> = 1...999

public enum SoundMoveError: LocalizedError {
    case invalidSlot

    public var errorDescription: String? { "sound move slots must be from 1 to 999" }
}

/// Places the selection in slot order, skipping unselected occupants. Each sound
/// needs a free scratch slot outside the final targets; nil refuses the whole plan.
public func planBulkMove(selected: [UInt16], occupied: Set<UInt16>,
                         start: UInt16) -> [(from: UInt16, to: UInt16)]? {
    let ids = selected.sorted()
    let selectedSet = Set(ids)
    guard soundMoveSlots.contains(start), ids.allSatisfy(soundMoveSlots.contains),
          selectedSet.count == ids.count, selectedSet.isSubset(of: occupied) else { return nil }
    var targets: [UInt16] = []
    var target = Int(start)
    for _ in ids {
        while target <= Int(soundMoveSlots.upperBound), occupied.contains(UInt16(target)),
              !selectedSet.contains(UInt16(target)) {
            target += 1
        }
        guard target <= Int(soundMoveSlots.upperBound) else { return nil }
        targets.append(UInt16(target))
        target += 1
    }
    let reserved = occupied.union(targets)
    let scratch = Array(soundMoveSlots.reversed().filter { !reserved.contains($0) }.prefix(ids.count))
    guard scratch.count == ids.count else { return nil }
    return zip(ids, scratch).map { (from: $0, to: $1) }
        + zip(scratch, targets).map { (from: $0, to: $1) }
}

/// Moves that take back `done`, newest first, so every slot a move vacated
/// is free again when its sound returns. Invalid sound slots refuse the whole undo.
public func undoMoves(_ done: [(from: UInt16, to: UInt16)]) -> [(from: UInt16, to: UInt16)] {
    guard done.allSatisfy({ soundMoveSlots.contains($0.from) && soundMoveSlots.contains($0.to) }) else { return [] }
    return done.reversed().map { (from: $0.to, to: $0.from) }
}

/// Whether a move whose reply failed ran anyway, judged from the slots the
/// device lists afterwards. Its target was free and its source occupied
/// before it was sent, so the opposite now means it ran.
public func stepLanded(_ step: (from: UInt16, to: UInt16), occupied: Set<UInt16>) -> Bool {
    occupied.contains(step.to) && !occupied.contains(step.from)
}

/// The prefix of `undoMoves(done)` that is safe against the slots the device
/// lists now: it stops before the first undo whose source is empty or whose
/// target is taken, so a rollback never moves a sound onto another one.
public func rollbackMoves(_ done: [(from: UInt16, to: UInt16)],
                          occupied: Set<UInt16>) -> [(from: UInt16, to: UInt16)] {
    var slots = occupied
    var safe: [(from: UInt16, to: UInt16)] = []
    for step in undoMoves(done) {
        guard slots.contains(step.from), !slots.contains(step.to) else { break }
        slots.remove(step.from)
        slots.insert(step.to)
        safe.append(step)
    }
    return safe
}

/// Swaps two occupied sound slots through a free sound slot, or refuses the whole plan.
public func planSwap(_ a: UInt16, _ b: UInt16, occupied: Set<UInt16>) -> [(from: UInt16, to: UInt16)]? {
    guard soundMoveSlots.contains(a), soundMoveSlots.contains(b),
          occupied.contains(a), occupied.contains(b) else { return nil }
    guard a != b else { return [] }
    guard let temp = soundMoveSlots.reversed().first(where: { !occupied.contains($0) }) else { return nil }
    return [(a, temp), (b, a), (temp, b)]
}

/// The selection after a single move whose reply failed, given the slots the
/// device lists afterwards, or nil when they could not be read: carried to the
/// target when the move ran, unchanged otherwise. Applied to a move whose
/// selection was already remapped, it drops the sound from the selection.
public func selectionAfterFailedMove(_ selection: Set<UInt16>, move: (from: UInt16, to: UInt16),
                                     occupied: Set<UInt16>?) -> Set<UInt16> {
    guard let occupied, stepLanded(move, occupied: occupied) else { return selection }
    return remapSelection(selection, moves: [move])
}
