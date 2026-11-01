import Foundation

/// Moves that put the selected sounds, in slot order, on consecutive free
/// slots from `start`, skipping slots held by unselected sounds. Every
/// selected sound first moves out to a temporary slot counting down from
/// 65000, so targets that are themselves selected never collide. Nil when
/// the targets would wrap or run into the temporary slots.
public func planBulkMove(selected: [UInt16], occupied: Set<UInt16>,
                         start: UInt16) -> [(from: UInt16, to: UInt16)]? {
    let ids = selected.sorted()
    let selectedSet = Set(ids)
    var moveOut: [(from: UInt16, to: UInt16)] = []
    var temp: UInt16 = 65000
    for id in ids {
        while occupied.contains(temp) { temp &-= 1 }
        moveOut.append((id, temp))
        temp &-= 1
    }
    let lowestTemp = moveOut.last?.to ?? UInt16.max

    var moveIn: [(from: UInt16, to: UInt16)] = []
    var target = Int(start)
    for pair in moveOut {
        while target < Int(lowestTemp), occupied.contains(UInt16(target)),
              !selectedSet.contains(UInt16(target)) {
            target += 1
        }
        guard target < Int(lowestTemp) else { return nil }
        moveIn.append((pair.to, UInt16(target)))
        target += 1
    }
    return moveOut + moveIn
}

/// Moves that take back `done`, newest first, so every slot a move vacated
/// is free again when its sound returns.
public func undoMoves(_ done: [(from: UInt16, to: UInt16)]) -> [(from: UInt16, to: UInt16)] {
    done.reversed().map { (from: $0.to, to: $0.from) }
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

/// Moves that swap the sounds in slots `a` and `b` through a temporary slot,
/// the first free one counting down from 65000.
public func planSwap(_ a: UInt16, _ b: UInt16, occupied: Set<UInt16>) -> [(from: UInt16, to: UInt16)] {
    var temp: UInt16 = 65000
    while occupied.contains(temp) { temp &-= 1 }
    return [(a, temp), (b, a), (temp, b)]
}
