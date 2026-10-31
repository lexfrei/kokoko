import Foundation

extension RecycleBinError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notASound(let slot):
            return "slot " + String(format: "%03d", slot) + " is not a sound on the device"
        case .incompleteCopy(let slot, let expected, let got):
            return "slot " + String(format: "%03d", slot)
                + " read back \(got) of \(expected) bytes, so no copy was kept"
        case .partialSoundMayRemain(let underlying):
            return "upload failed (\(underlying)); a partial sound may remain on the device"
        }
    }
}
