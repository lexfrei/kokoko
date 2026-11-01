import Foundation
import KokokoMIDI

/// A wire whose every send fails, as when the device is gone.
private final class DeadWire: MIDIWire, @unchecked Sendable {
    func send(_ bytes: [UInt8]) async throws { throw WireError.noDevice }
    func setMessageHandler(_ handler: (@Sendable ([UInt8]) -> Void)?) {}
}

extension KokokoCoreChecks {
    static func identifyChecks() async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await identifyDevice(on: DeadWire(), timeout: .seconds(2))
            check(false, "identify: a failed send fails the identify")
        } catch WireError.noDevice {
            check(clock.now - start < .seconds(1), "identify: a failed send is reported at once, not after the timeout")
        } catch {
            check(false, "identify: a failed send passes its error on — got \(error)")
        }
    }
}
