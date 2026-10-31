import Foundation

/// Sounds to offer for a delete without a bin copy after a delete into the
/// bin threw: only the one the batch stopped on, and only if a fresh listing
/// still shows it. Sounds after it were never tried, and a stale slot means
/// nothing was attempted at all.
public func binFallbackCandidates(ids: [UInt16], lastStarted: Int?, error: Error,
                                  listed: Set<UInt16>) -> Set<UInt16> {
    let failed: UInt16?
    switch error {
    case RecycleBinError.notASound:
        failed = nil
    case RecycleBinError.incompleteCopy(let slot, _, _):
        failed = slot
    default:
        failed = lastStarted.flatMap { ids.indices.contains($0) ? ids[$0] : nil }
    }
    guard let failed, listed.contains(failed) else { return [] }
    return [failed]
}

/// The text under the delete-without-a-copy confirmation, naming the sound
/// it will remove for good: most errors do not carry a slot themselves.
public func binFallbackPrompt(slot: UInt16, name: String, reason: String) -> String {
    String(format: "%03d", slot) + " \(name) will be deleted without a copy. \(reason)"
}
