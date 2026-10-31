import Foundation

/// Replays slot moves, in the order they ran on the device, over a selection
/// of slots, so each selected sound stays selected under its new slot and a
/// slot taken over by an unselected sound drops out.
public func remapSelection(_ selection: Set<UInt16>,
                           moves: [(from: UInt16, to: UInt16)]) -> Set<UInt16> {
    var result = selection
    for move in moves {
        let carried = result.remove(move.from) != nil
        if carried {
            result.insert(move.to)
        } else {
            result.remove(move.to)
        }
    }
    return result
}
