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
