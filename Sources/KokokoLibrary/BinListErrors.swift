import Foundation

extension RecycleBinError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notASound(let slot):
            return "slot " + String(format: "%03d", slot) + " is not a sound on the device"
        case .incompleteCopy(let slot, let expected, let got):
            return "slot " + String(format: "%03d", slot)
                + " read back \(got) of \(expected) bytes, so no copy was kept"
        case .partialSoundMayRemain(let slot, let underlying):
            let place = slot.map { "in slot " + String(format: "%03d", $0) } ?? "on the device"
            return "\(underlying); an incomplete sound may remain \(place)"
        }
    }
}
