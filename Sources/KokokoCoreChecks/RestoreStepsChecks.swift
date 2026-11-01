import Foundation
import KokokoLibrary
import KokokoMIDI

extension KokokoCoreChecks {
    private actor Removed {
        var ids: [String] = []
        func add(_ id: String) { ids.append(id) }
    }

    private struct Refused: LocalizedError { var errorDescription: String? { "refused" } }

    /// Runs the restore steps and returns the error they threw (nil on success)
    /// and the ids they tried to remove; a direct delete is marked "d", a
    /// removal after listing "l".
    private static func restoreOutcome(slot: UInt16, put: @escaping @Sendable () async throws -> UInt16,
                                       setMetadata: @escaping @Sendable (UInt16) async throws -> Void = { _ in },
                                       removable: Bool) async -> ((any Error)?, [String]) {
        let removed = Removed()
        do {
            _ = try await restoreSoundSteps(
                slot: slot, put: put, setMetadata: setMetadata,
                delete: { await removed.add("d\($0)"); if !removable { throw Refused() } },
                removeIfListed: { await removed.add("l\($0)"); return removable })
            return (nil, await removed.ids)
        } catch {
            return (error, await removed.ids)
        }
    }

    static func restoreStepsChecks() async {
        let cut: @Sendable () async throws -> UInt16 = {
            throw FileServiceError.putIncomplete(fileID: 7, underlying: "timeout")
        }
        var (error, removed) = await restoreOutcome(slot: 0, put: cut, removable: true)
        check(error.map { if case FileServiceError.putIncomplete(7, _) = $0 { true } else { false } } == true,
              "restore steps: a cut-short put whose node was removed passes the incomplete put on — got \(String(describing: error))")
        eq(removed, ["d7"], "restore steps: the node a cut-short put names is deleted by its id")
        (error, removed) = await restoreOutcome(slot: 7, put: cut, removable: false)
        eq(error as? RecycleBinError, .partialSoundMayRemain(slot: 7, underlying: "timeout"),
           "restore steps: a cut-short put into the original slot whose removal fails may remain there")

        let refusal: @Sendable () async throws -> UInt16 = {
            throw SessionError.deviceError(.badRequest, message: nil)
        }
        for slot: UInt16 in [0, 5] {
            (error, removed) = await restoreOutcome(slot: slot, put: refusal, removable: false)
            check(error.map { if case SessionError.deviceError = $0 { true } else { false } } == true,
                  "restore steps: an init the device refuses passes the refusal on (slot \(slot)) — got \(String(describing: error))")
            eq(removed, [], "restore steps: an init the device refuses removes nothing (slot \(slot))")
        }

        let lostReplies: [(String, any Error)] = [
            ("lost", SessionError.timeout(command: 2, requestID: 1)),
            ("lost on the wire", WireError.timeout),
            ("unreadable", FileServiceError.missingResponse),
        ]
        for (label, failure) in lostReplies {
            let put: @Sendable () async throws -> UInt16 = { throw failure }
            (error, removed) = await restoreOutcome(slot: 0, put: put, removable: true)
            eq(error as? RecycleBinError,
               .partialSoundMayRemain(slot: nil, underlying: failure.localizedDescription),
               "restore steps: an init whose reply is \(label) into an assigned slot may leave a sound")
            eq(removed, [], "restore steps: an init whose reply is \(label) into an assigned slot removes nothing")

            (error, removed) = await restoreOutcome(slot: 5, put: put, removable: true)
            eq(error?.localizedDescription, failure.localizedDescription,
               "restore steps: an init whose reply is \(label) into a removed original slot passes its error on")
            eq(removed, ["l5"], "restore steps: an init whose reply is \(label) clears the original slot only if listed")

            (error, removed) = await restoreOutcome(slot: 5, put: put, removable: false)
            eq(error as? RecycleBinError,
               .partialSoundMayRemain(slot: 5, underlying: failure.localizedDescription),
               "restore steps: an init whose reply is \(label) into an original slot that stays may leave a sound there")
        }

        let refuseMetadata: @Sendable (UInt16) async throws -> Void = { _ in throw Refused() }
        (error, removed) = await restoreOutcome(slot: 0, put: { 9 }, setMetadata: refuseMetadata, removable: true)
        check(error is Refused, "restore steps: a refused metadata write is passed on once the sound is removed")
        eq(removed, ["d9"], "restore steps: a sound whose metadata write failed is deleted by its id")
        (error, _) = await restoreOutcome(slot: 0, put: { 9 }, setMetadata: refuseMetadata, removable: false)
        eq(error as? RecycleBinError, .partialSoundMayRemain(slot: 9, underlying: "refused"),
           "restore steps: a sound whose metadata write failed and stays is named")

        (error, removed) = await restoreOutcome(slot: 5, put: { 5 }, removable: true)
        check(error == nil && removed.isEmpty, "restore steps: a restore that succeeds removes nothing")

        eq(RecycleBinError.partialSoundMayRemain(slot: 5, underlying: "timeout").localizedDescription,
           "timeout; an incomplete sound may remain in slot 005",
           "restore steps: the message names the slot")
        eq(RecycleBinError.partialSoundMayRemain(slot: nil, underlying: "timeout").localizedDescription,
           "timeout; an incomplete sound may remain on the device",
           "restore steps: without a slot the message says the device")
    }
}
