import Foundation
import KokokoCore
import KokokoLibrary
import KokokoMIDI
import VirtualEP

/// Forwards to a real wire but holds every put data page back for 30 s, so a
/// put is still in flight when the check closes the session.
private final class HoldPutDataWire: MIDIWire, @unchecked Sendable {
    private let inner: any MIDIWire
    private let lock = NSLock()
    private var _holding = false
    var holding: Bool { lock.withLock { _holding } }

    init(inner: any MIDIWire) { self.inner = inner }

    func send(_ bytes: [UInt8]) async throws {
        if let frame = TEFrame.parse(bytes), frame.payload.starts(with: [FileSub.put, 1]) {
            lock.withLock { _holding = true }
            try await Task.sleep(for: .seconds(30))
        }
        try await inner.send(bytes)
    }

    func setMessageHandler(_ handler: (@Sendable ([UInt8]) -> Void)?) { inner.setMessageHandler(handler) }
}

extension KokokoCoreChecks {
    static func sessionCloseChecks() async {
        eq(SessionError.disconnected.localizedDescription, "device disconnected", "close: a call cut off by a close reads as disconnected")
        eq(SessionError.closed.localizedDescription, "device disconnected", "close: a call refused on a closed session reads as disconnected")
        let clock = ContinuousClock()

        // A silent wire: nothing ever answers.
        let silent = FakeWire()
        let session = SysExSession(wire: silent, identityCode: 0x10)
        let files = DeviceFileService(session: session)
        let start = clock.now
        let stuck = Task { try await files.list(nodeID: 0) }
        // The call registers as pending before it sends, so a recorded send means it is pending.
        while silent.sent.isEmpty && clock.now - start < .seconds(5) { try? await Task.sleep(for: .milliseconds(5)) }
        let waiting = Task { try await files.list(nodeID: 0) }
        try? await Task.sleep(for: .milliseconds(50))
        await session.close()
        // The pending call is cut off. The second op cannot send before the first releases the
        // device lock, which happens only when close() fails it, so the second is always refused.
        for (label, task, want) in [("the pending call", stuck, SessionError.disconnected),
                                    ("a second op started right after the stuck one", waiting, SessionError.closed)] {
            do {
                _ = try await task.value
                check(false, "close: \(label) fails")
            } catch let error as SessionError {
                check(clock.now - start < .seconds(1), "close: \(label) fails within a second")
                check("\(error)" == "\(want)", "close: \(label) fails as \(want) — got \(error)")
            } catch {
                check(false, "close: \(label) fails with a session error — got \(error)")
            }
        }
        let later = clock.now
        do {
            _ = try await session.call(command: TECommand.echo, payload: [1])
            check(false, "close: a call on a closed session fails")
        } catch SessionError.closed {
            check(clock.now - later < .milliseconds(200), "close: a call on a closed session fails at once")
        } catch {
            check(false, "close: a call on a closed session is refused as closed — got \(error)")
        }

        // Nothing was sent, so nothing can remain on the device.
        do {
            _ = try await uploadSound(files: files, parent: 1, name: "late", pcm: [0, 0], metadata: [:])
            check(false, "close: an upload on a closed session fails")
        } catch {
            check(!error.localizedDescription.contains("may remain"),
                  "close: an upload on a closed session does not warn about a partial sound — got \(error.localizedDescription)")
        }

        // A put cut by the close still tells the user a partial sound may remain.
        let vep = VirtualEPDevice(name: "kokoko-vep-close-\(getpid())")
        defer { vep.stop() }
        do {
            try vep.start()
            try await Task.sleep(for: .milliseconds(300))
            guard let pair = enumerateMIDIPairs().first(where: { $0.name == vep.name }) else {
                check(false, "close: device enumerated")
                return
            }
            let raw = try CoreMIDIWire(pair: pair)
            let identity = try await identifyDevice(on: raw)
            let wire = HoldPutDataWire(inner: raw)
            let vepSession = SysExSession(wire: wire, identityCode: identity.deviceID)
            let vepFiles = DeviceFileService(session: vepSession)
            try await vepFiles.initialize()
            let soundsRoot = try await DeviceLibrary(files: vepFiles).resolve("/sounds")
            let upload = Task {
                try await uploadSound(files: vepFiles, parent: soundsRoot, name: "cut", pcm: [UInt8](repeating: 0, count: 400),
                                      metadata: ["channels": .int(1)])
            }
            let waitStart = clock.now
            while !wire.holding && clock.now - waitStart < .seconds(5) { try await Task.sleep(for: .milliseconds(10)) }
            guard wire.holding else {
                check(false, "close: the put reached its first data page")
                upload.cancel()
                return
            }
            await vepSession.close()
            do {
                _ = try await upload.value
                check(false, "close: a put cut by the close fails")
            } catch let error as UploadSoundError {
                let text = error.localizedDescription
                check(text.contains("may remain in slot"), "close: a put cut by the close names the slot that may hold a partial sound — got \(text)")
            } catch {
                check(false, "close: a put cut by the close is an upload error — got \(error)")
            }
        } catch {
            check(false, "close checks threw \(error)")
        }
    }
}
