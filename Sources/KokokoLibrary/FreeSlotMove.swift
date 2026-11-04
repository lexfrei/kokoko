import Foundation
import KokokoMIDI

public enum FreeSlotMoveResult: Equatable, Sendable {
    case moved, unchanged, missing, stale
    case refused(String)
    case failed(String, at: UInt16?)
}

public func moveToFreeSlot(
    files: DeviceFileService, root: UInt16, from: UInt16, to: UInt16,
    isCurrent: @escaping @Sendable () async -> Bool
) async -> FreeSlotMoveResult {
    await moveToFreeSlotSteps(
        from: from, to: to,
        list: { Set(try await files.list(nodeID: root).map(\.id)) },
        move: { try await files.move(fileID: from, toParent: root, newFileID: to) },
        isCurrent: isCurrent)
}

package func moveToFreeSlotSteps(
    from: UInt16, to: UInt16,
    list: @Sendable () async throws -> Set<UInt16>,
    move: @Sendable () async throws -> Void,
    isCurrent: @Sendable () async -> Bool
) async -> FreeSlotMoveResult {
    guard await isCurrent() else { return .stale }
    guard to != 0 else { return .refused("slot zero is not a move destination") }
    guard from != to else { return .unchanged }
    let occupied: Set<UInt16>
    do {
        occupied = try await list()
    } catch {
        return await isCurrent() ? .refused("could not read slots: \(error.localizedDescription)") : .stale
    }
    guard await isCurrent() else { return .stale }
    guard occupied.contains(from) else { return .missing }
    guard !occupied.contains(to) else { return .refused("slot \(to) is occupied") }
    do {
        try await move()
        return await isCurrent() ? .moved : .stale
    } catch {
        guard await isCurrent() else { return .stale }
        let message = "move was not confirmed: \(error.localizedDescription)"
        let current: Set<UInt16>
        do {
            current = try await list()
        } catch {
            return await isCurrent() ? .failed(message, at: nil) : .stale
        }
        guard await isCurrent() else { return .stale }
        if stepLanded((from, to), occupied: current) { return .failed(message, at: to) }
        let at = current.contains(from) && !current.contains(to) ? from : nil
        return .failed(message, at: at)
    }
}
