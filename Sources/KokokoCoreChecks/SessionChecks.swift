import Foundation
import KokokoCore
import KokokoMIDI

/// In-memory wire: records outbound frames, injects inbound ones by hand.
final class FakeWire: MIDIWire, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [[UInt8]] = []
    private var _handler: (@Sendable ([UInt8]) -> Void)?

    var sent: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return _sent
    }

    private func recordSent(_ bytes: [UInt8]) {
        lock.lock()
        _sent.append(bytes)
        lock.unlock()
    }

    func send(_ bytes: [UInt8]) async throws {
        recordSent(bytes)
    }

    func setMessageHandler(_ handler: (@Sendable ([UInt8]) -> Void)?) {
        lock.lock()
        _handler = handler
        lock.unlock()
    }

    private func currentHandler() -> (@Sendable ([UInt8]) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return _handler
    }

    func emulateIncoming(_ bytes: [UInt8]) {
        currentHandler()?(bytes)
    }
}

/// Builds the response frame the device would send for a captured request.
func deviceResponse(to request: [UInt8], status: UInt8, payload: [UInt8]) -> [UInt8] {
    // Request: F0 00 20 76 idCode 40 (40|20|hi) lo cmd packed... F7
    let idCode = request[4]
    let requestID = (UInt16(request[6] & 31) << 7) | UInt16(request[7] & 127)
    let command = request[8]
    var out: [UInt8] = [0xF0, 0x00, 0x20, 0x76, idCode, 0x40,
                        0x20 | UInt8((requestID >> 7) & 31), UInt8(requestID & 127),
                        command, status]
    out.append(contentsOf: SevenBitCoding.pack(payload))
    out.append(0xF7)
    return out
}

extension KokokoCoreChecks {
    static func sessionChecks() async {
        let wire = FakeWire()
        let session = SysExSession(wire: wire, identityCode: 0x10)

        // greet round trip
        async let greetTask = session.greet()
        // Let the session send first.
        try? await Task.sleep(for: .milliseconds(50))
        let sentFrames = wire.sent
        check(sentFrames.count == 1, "session sent one frame")
        if let sent = sentFrames.first {
            let reply = deviceResponse(to: sent, status: 0,
                                       payload: Array("mode:normal;os_version:2.1.0;serial:x;sku:TE032AS001;".utf8))
            wire.emulateIncoming(reply)
        }
        do {
            let meta = try await greetTask
            eq(meta.mode, "normal", "session greet mode")
            eq(meta.osVersion, "2.1.0", "session greet os")
        } catch {
            check(false, "session greet threw \(error)")
        }

        // error status surfaces as deviceError
        async let echoTask = session.call(command: TECommand.echo, payload: [1])
        try? await Task.sleep(for: .milliseconds(50))
        if let sent = wire.sent.last {
            wire.emulateIncoming(deviceResponse(to: sent, status: 3, payload: []))
        }
        do {
            _ = try await echoTask
            check(false, "session error expected")
        } catch SessionError.deviceError(let status, _) {
            eq(status, .badRequest, "session maps status 3")
        } catch {
            check(false, "session wrong error \(error)")
        }

        // device event dispatch: events arrive with IS_REQUEST set, no request id
        let eventsTask = Task { () -> FileEvent? in
            var iterator = await session.fileEvents().makeAsyncIterator()
            return await iterator.next()
        }
        try? await Task.sleep(for: .milliseconds(50))
        var eventFrame: [UInt8] = [0xF0, 0x00, 0x20, 0x76, 0x10, 0x40, 0x40, 0x00, TECommand.file]
        eventFrame.append(contentsOf: SevenBitCoding.pack([0x0A, 0x00, 0x09]))
        eventFrame.append(0xF7)
        wire.emulateIncoming(eventFrame)
        if case .deleted(let nodeID) = await eventsTask.value {
            eq(nodeID, 9, "session event deleted node")
        } else {
            check(false, "session event not delivered")
        }

        // timeout
        do {
            _ = try await session.call(command: TECommand.echo, payload: [], timeout: .milliseconds(100))
            check(false, "session timeout expected")
        } catch SessionError.timeout {
            check(true, "session timeout")
        } catch {
            check(false, "session timeout wrong error \(error)")
        }

        // identity over fake wire
        let idWire = FakeWire()
        async let idTask = identifyDevice(on: idWire)
        try? await Task.sleep(for: .milliseconds(50))
        eq(idWire.sent.first, Identity.requestBytes, "identity request sent")
        wire.emulateIncoming([0xF0, 0x7E, 0x42, 0x06, 0x02, 0x00, 0x20, 0x76,
                              32, 0, 1, 0, 2, 0, 5, 0, 0xF7]) // wrong wire: ignored
        idWire.emulateIncoming([0xF0, 0x7E, 0x42, 0x06, 0x02, 0x00, 0x20, 0x76,
                                32, 0, 1, 0, 2, 0, 5, 0, 0xF7])
        do {
            let reply = try await idTask
            eq(reply.sku, "TE032AS001", "identify sku")
        } catch {
            check(false, "identify threw \(error)")
        }
    }
}
