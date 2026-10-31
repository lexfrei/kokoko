import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func binFallbackChecks() {
        struct DeviceRefused: Error {}
        let ids: [UInt16] = [10, 11, 12, 13]

        eq(binFallbackCandidates(ids: ids, lastStarted: 1, error: DeviceRefused(), listed: [11, 12, 13]),
           [11], "bin fallback: only the sound the batch stopped on, not the untried ones")
        eq(binFallbackCandidates(ids: ids, lastStarted: nil, error: RecycleBinError.notASound(99),
                                 listed: [10, 11, 12, 13]),
           [], "bin fallback: a stale slot offers nothing")
        eq(binFallbackCandidates(ids: ids, lastStarted: 2,
                                 error: RecycleBinError.incompleteCopy(slot: 12, expected: 100, got: 40),
                                 listed: [12, 13]),
           [12], "bin fallback: a short read offers its slot")
        eq(binFallbackCandidates(ids: ids, lastStarted: 1, error: DeviceRefused(), listed: []),
           [], "bin fallback: nothing when the sound is gone or the list could not be read")
        eq(binFallbackCandidates(ids: ids, lastStarted: nil, error: DeviceRefused(), listed: [10, 11]),
           [], "bin fallback: nothing when the batch failed before its first sound")
        eq(binFallbackCandidates(ids: ids, lastStarted: 9, error: DeviceRefused(), listed: [10, 11]),
           [], "bin fallback: nothing for an index outside the batch")

        let prompt = binFallbackPrompt(slot: 12, name: "kick", reason: "device did not answer in time")
        check(prompt.contains("012") && prompt.contains("kick") && prompt.contains("did not answer"),
              "bin fallback: the prompt names the sound it will delete — got \(prompt)")

        let short = RecycleBinError.incompleteCopy(slot: 7, expected: 4096, got: 1024).localizedDescription
        check(short.contains("007") && short.contains("4096") && short.contains("1024"),
              "bin errors: a short read names the slot and both sizes — got \(short)")
        let stray = RecycleBinError.notASound(42).localizedDescription
        check(stray.contains("042"), "bin errors: a stale slot is named — got \(stray)")
        let partial = RecycleBinError.partialSoundMayRemain(underlying: "timeout").localizedDescription
        check(partial.contains("timeout") && partial.contains("partial"),
              "bin errors: a failed restore says a partial sound may remain — got \(partial)")
    }
}
