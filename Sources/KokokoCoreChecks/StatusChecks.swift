import Foundation
import KokokoCore
import KokokoMIDI

extension KokokoCoreChecks {
    static func statusChecks() async {
        for byte: UInt8 in [4, 15, 128, 255] {
            eq(TEStatus(byte), .unknown(byte), "status: undefined byte \(byte) is kept as unknown")
        }
        eq(TEStatus(1), .error, "status: byte 1 is still the generic error")
        eq(SessionError.deviceError(.unknown(5), message: nil).localizedDescription,
           "device answered unknown status 5", "status: an unknown status is named with its number")

        let wire = FakeWire()
        let session = SysExSession(wire: wire, identityCode: 0x10)
        async let echo = session.call(command: TECommand.echo, payload: [1])
        try? await Task.sleep(for: .milliseconds(50))
        if let sent = wire.sent.last {
            wire.emulateIncoming(deviceResponse(to: sent, status: 5, payload: []))
        }
        do {
            _ = try await echo
            check(false, "status: a reply with an undefined status fails the call")
        } catch SessionError.deviceError(let status, _) {
            eq(status, .unknown(5), "status: the session passes an undefined status on as unknown")
        } catch {
            check(false, "status: an undefined status is a device error — got \(error)")
        }
    }
}
