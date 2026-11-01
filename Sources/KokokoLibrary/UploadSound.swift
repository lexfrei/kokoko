import Foundation
import KokokoCore
import KokokoMIDI

public enum UploadSoundError: LocalizedError {
    /// The audio landed in `slot` but its metadata write failed; `removed`
    /// says whether the half-written sound was deleted again.
    case metadataRefused(slot: UInt16, reason: String, removed: Bool)
    /// The audio transfer stopped after init named `slot`; `removed` says
    /// whether that partial node was deleted again.
    case putIncomplete(slot: UInt16, reason: String, removed: Bool)
    /// No init reply was read, so whether a node exists, and under which id,
    /// is unknown.
    case initUnconfirmed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .metadataRefused(let slot, let reason, let removed):
            let slotText = String(format: "%03d", slot)
            return removed
                ? "metadata write failed (\(reason)), slot \(slotText) removed again"
                : "metadata write failed (\(reason)), slot \(slotText) still holds the sound without its metadata"
        case .putIncomplete(let slot, let reason, let removed):
            let slotText = String(format: "%03d", slot)
            return removed
                ? "upload failed (\(reason)), partial sound in slot \(slotText) removed"
                : "upload failed (\(reason)), a partial sound may remain in slot \(slotText)"
        case .initUnconfirmed(let reason):
            return "upload failed (\(reason)), a partial sound may remain on the device"
        }
    }
}

/// Puts a prepared sound under `parent` and writes its metadata, name
/// included. When the transfer stops after the device named the node, or
/// the metadata write fails, that node is deleted again.
public func uploadSound(files: DeviceFileService, parent: UInt16, name: String, pcm: [UInt8],
                        metadata: [String: JSONValue],
                        progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> UInt16 {
    var named = metadata
    named["name"] = .string(name)
    let meta = named
    return try await uploadSoundSteps(
        put: { try await files.put(parentID: parent, name: name, data: pcm, progress: progress) },
        setMetadata: { try await files.setMetadata(fileID: $0, meta) },
        delete: { try await files.delete(fileID: $0) })
}

/// The steps of `uploadSound` passed in, so their failure handling can be
/// checked without a device.
package func uploadSoundSteps(put: @Sendable () async throws -> UInt16,
                             setMetadata: @Sendable (UInt16) async throws -> Void,
                             delete: @Sendable (UInt16) async throws -> Void) async throws -> UInt16 {
    let slot: UInt16
    do {
        slot = try await put()
    } catch FileServiceError.putIncomplete(let partial, let reason) {
        let removed = (try? await delete(partial)) != nil
        throw UploadSoundError.putIncomplete(slot: partial, reason: reason, removed: removed)
    } catch where initReplyLost(error) {
        throw UploadSoundError.initUnconfirmed(reason: error.localizedDescription)
    }
    do {
        try await setMetadata(slot)
    } catch {
        let removed = (try? await delete(slot)) != nil
        throw UploadSoundError.metadataRefused(slot: slot, reason: error.localizedDescription,
                                               removed: removed)
    }
    return slot
}

/// A put init that was sent but whose reply never arrived or could not be read:
/// the device may have created a node under an id the caller does not know.
func initReplyLost(_ error: any Error) -> Bool {
    switch error {
    case SessionError.timeout, WireError.timeout, FileServiceError.missingResponse: true
    default: false
    }
}

/// The steps of a restore into `slot` (0: device-assigned), with the
/// partial-node policy of `uploadSoundSteps`: a node the restore may have left
/// and could not remove is reported as `partialSoundMayRemain`, naming its slot
/// when it is known; a refusal and every other error are passed on unchanged.
/// A node the put named is deleted by its id; an explicit slot after a lost
/// init reply only through `removeIfListed`, which returns true when the node
/// is gone afterwards.
package func restoreSoundSteps(slot: UInt16,
                              put: @Sendable () async throws -> UInt16,
                              setMetadata: @Sendable (UInt16) async throws -> Void,
                              delete: @Sendable (UInt16) async throws -> Void,
                              removeIfListed: @Sendable (UInt16) async -> Bool) async throws -> UInt16 {
    let id: UInt16
    do {
        id = try await put()
    } catch FileServiceError.putIncomplete(let partial, let reason) {
        guard (try? await delete(partial)) != nil else {
            throw RecycleBinError.partialSoundMayRemain(slot: partial, underlying: reason)
        }
        throw FileServiceError.putIncomplete(fileID: partial, underlying: reason)
    } catch where initReplyLost(error) {
        // An explicit slot is where a node the lost init created would be.
        guard slot != 0, await removeIfListed(slot) else {
            throw RecycleBinError.partialSoundMayRemain(slot: slot == 0 ? nil : slot,
                                                        underlying: error.localizedDescription)
        }
        throw error
    }
    do {
        try await setMetadata(id)
    } catch {
        guard (try? await delete(id)) != nil else {
            throw RecycleBinError.partialSoundMayRemain(slot: id, underlying: error.localizedDescription)
        }
        throw error
    }
    return id
}
