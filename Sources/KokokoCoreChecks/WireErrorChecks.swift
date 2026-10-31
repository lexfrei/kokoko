import Foundation
import KokokoMIDI

extension KokokoCoreChecks {
    static func wireErrorChecks() {
        eq(WireError.noDevice.localizedDescription, "no device is connected", "wire error text: no device")
        eq(WireError.timeout.localizedDescription, "device did not answer in time", "wire error text: timeout")
    }
}
