import Foundation
import KokokoCore
import KokokoLibrary
import KokokoMIDI
import VirtualEP

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() { lock.withLock { done = true } }
    var value: Bool { lock.withLock { done } }
}

private actor AddedEvents {
    var ids: Set<UInt16> = []
    func record(_ id: UInt16) { ids.insert(id) }
}

extension KokokoCoreChecks {
    static func vepGuardChecks() async {
        let vep = VirtualEPDevice(name: "kokoko-vep-guards-\(getpid())")
        defer { vep.stop() }
        do {
            try vep.start()
            try await Task.sleep(for: .milliseconds(300))
            guard let pair = enumerateMIDIPairs().first(where: { $0.name == vep.name }) else {
                check(false, "vep guards: device enumerated")
                return
            }
            let wire = try CoreMIDIWire(pair: pair)
            let identity = try await identifyDevice(on: wire)
            let session = SysExSession(wire: wire, identityCode: identity.deviceID)
            let files = DeviceFileService(session: session)
            try await files.initialize()
            let soundsRoot = try await DeviceLibrary(files: files).resolve("/sounds")
            let kick = try await files.list(nodeID: soundsRoot).first { $0.isFile }?.id ?? 0

            // -1e400 parses as -infinity, which JSON cannot carry back out.
            _ = try await session.call(command: TECommand.file,
                                       payload: SetMetadataRequest(fileID: kick, json: #"{"x":-1e400}"#).bytes)
            do {
                _ = try await files.getMetadata(fileID: kick)
                check(false, "vep: metadata JSON cannot carry is refused on get")
            } catch SessionError.deviceError(let status, _) {
                eq(status, .specificError(16), "vep: metadata JSON cannot carry answers status 16 on get")
            }

            // A node deleted between the start of a transfer and its last packet.
            let added = AddedEvents()
            let events = await session.fileEvents()
            let watch = Task {
                for await event in events {
                    if case .addedUpdated(let id, _, _) = event { await added.record(id) }
                }
            }
            defer { watch.cancel() }
            let initReply = try await session.call(
                command: TECommand.file,
                payload: PutInitRequest(fileID: 0, parentID: soundsRoot, flags: FileTypeFlag.file | FileCapability.read,
                                        fileSize: 0, filename: "vanish", metadata: nil).bytes)
            let vanishing = PutInitResponse(payload: initReply.payload)?.fileID ?? 0
            _ = try await session.call(command: TECommand.file, payload: DeleteRequest(fileID: vanishing).bytes)
            do {
                _ = try await session.call(command: TECommand.file, payload: PutDataRequest(page: 0, data: []).bytes)
                check(false, "vep: the last put packet for a deleted node fails")
            } catch SessionError.deviceError(let status, _) {
                eq(status, .specificError(16), "vep: the last put packet for a deleted node answers status 16")
            }
            try await Task.sleep(for: .milliseconds(300))
            check(!(await added.ids.contains(vanishing)), "vep: a put whose node was deleted announces no added node")

            let doomed = try await files.put(parentID: soundsRoot, name: "doomed", data: [0, 0])
            try await Task.sleep(for: .milliseconds(300))
            check(await added.ids.contains(doomed), "vep: a completed put announces its node")
            _ = try await session.call(command: TECommand.file,
                                       payload: SetMetadataPagedInitRequest(fileID: doomed, totalSize: 0).bytes)
            _ = try await session.call(command: TECommand.file, payload: DeleteRequest(fileID: doomed).bytes)
            do {
                _ = try await session.call(command: TECommand.file,
                                           payload: SetMetadataPagedDataRequest(page: 0, data: []).bytes)
                check(false, "vep: the last paged metadata packet for a deleted node fails")
            } catch SessionError.deviceError(let status, _) {
                eq(status, .specificError(16), "vep: the last paged metadata packet for a deleted node answers status 16")
            }
        } catch {
            check(false, "vep guard checks threw \(error)")
        }
    }

    /// Stops a device while replies are still going out, several times over.
    static func vepStopChecks() async {
        for round in 1...3 {
            let vep = VirtualEPDevice(name: "kokoko-vep-stop-\(getpid())-\(round)")
            do {
                try vep.start()
                try await Task.sleep(for: .milliseconds(300))
                guard let pair = enumerateMIDIPairs().first(where: { $0.name == vep.name }) else {
                    check(false, "vep stop: device enumerated")
                    return
                }
                let wire = try CoreMIDIWire(pair: pair)
                let identity = try await identifyDevice(on: wire)
                let session = SysExSession(wire: wire, identityCode: identity.deviceID)
                let load = Task {
                    while !Task.isCancelled {
                        await withTaskGroup(of: Void.self) { group in
                            for _ in 0..<20 {
                                group.addTask { _ = try? await session.call(command: TECommand.echo, payload: [1], timeout: .milliseconds(300)) }
                            }
                        }
                    }
                }
                defer { load.cancel() }
                try await Task.sleep(for: .milliseconds(50))
                let stopped = StopFlag()
                Thread { vep.stop(); stopped.set() }.start()
                let waitStart = ContinuousClock.now
                while !stopped.value && ContinuousClock.now - waitStart < .seconds(5) {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard stopped.value else {
                    check(false, "vep: stop() returns while replies are going out (stuck in round \(round))")
                    return
                }
            } catch {
                check(false, "vep stop checks threw \(error)")
                return
            }
        }
        check(true, "vep: stop() returns while replies are going out")
    }
}
