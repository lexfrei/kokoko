import Foundation
import KokokoCore
import KokokoMIDI

public enum UploadSoundError: LocalizedError {
    /// The audio landed in `slot` but its metadata write failed; `removed`
    /// says whether the half-written sound was deleted again.
    case metadataRefused(slot: UInt16, reason: String, removed: Bool)

    public var errorDescription: String? {
        switch self {
        case .metadataRefused(let slot, let reason, let removed):
            let slotText = String(format: "%03d", slot)
            return removed
                ? "metadata write failed (\(reason)), slot \(slotText) removed again"
                : "metadata write failed (\(reason)), slot \(slotText) still holds the sound without its metadata"
        }
    }
}

/// Puts a prepared sound under `parent` and writes its metadata, name
/// included. When the metadata write fails the new node is deleted again
/// instead of staying behind without the metadata the app wrote for it.
public func uploadSound(files: DeviceFileService, parent: UInt16, name: String, pcm: [UInt8],
                        metadata: [String: JSONValue],
                        progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> UInt16 {
    let slot = try await files.put(parentID: parent, name: name, data: pcm, progress: progress)
    var meta = metadata
    meta["name"] = .string(name)
    do {
        try await files.setMetadata(fileID: slot, meta)
    } catch {
        let removed = (try? await files.delete(fileID: slot)) != nil
        throw UploadSoundError.metadataRefused(slot: slot, reason: error.localizedDescription,
                                               removed: removed)
    }
    return slot
}
