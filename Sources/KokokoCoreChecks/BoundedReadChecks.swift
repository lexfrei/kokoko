import Foundation
import KokokoCore
import KokokoLibrary
import KokokoMIDI

extension KokokoCoreChecks {
    static func boundedReadChecks() async {
        let cap = 16 * 1024 * 1024
        let cases: [BoundedReadCase] = [
            .init(name: "empty", size: 0, pages: [], limit: cap, expected: 0, requests: 0, capacity: 0),
            .init(name: "exact budget", size: UInt32(cap), pages: Array(repeating: 1024 * 1024, count: 16),
                  limit: cap, expected: cap, requests: 16, capacity: cap),
            .init(name: "announced over budget", size: UInt32(cap + 1), pages: [], limit: cap, failure: .limit, requests: 0),
            .init(name: "giant announcement", size: .max, pages: [], limit: cap, failure: .limit, requests: 0),
            .init(name: "remaining offset budget", size: .max, pages: [4], limit: 4, offset: .max - 4,
                  expected: 4, requests: 1, capacity: 4),
            .init(name: "offset at end", size: 4, pages: [], limit: 0, offset: 4, expected: 0, requests: 0, capacity: 0),
            .init(name: "offset past end", size: 4, pages: [], limit: cap, offset: 5, failure: .offset, requests: 0),
            .init(name: "negative budget", size: 4, pages: [], limit: -1, failure: .negative, requests: 0, initRequests: 0),
            .init(name: "zero budget permits empty", size: 0, pages: [], limit: 0, expected: 0, requests: 0, capacity: 0),
            .init(name: "zero budget refuses bytes", size: 1, pages: [], limit: 0, failure: .limit, requests: 0),
            .init(name: "page crosses budget", size: 6, pages: [4, 3], limit: 6, failure: .limit, requests: 2, capacity: 6),
            .init(name: "page exceeds announcement", size: 4, pages: [6], limit: 8, failure: .truncated, requests: 1, capacity: 4),
            .init(name: "short whole read", size: 6, pages: [4, 0], limit: 6, failure: .truncated, requests: 2, capacity: 6),
            .init(name: "wrong page", size: 4, pages: [4], limit: 4, failure: .page, requests: 1, capacity: 4, wrongPage: true),
            .init(name: "malformed init", size: 4, pages: [], limit: 4, failure: .response, requests: 0, malformedInit: true),
            .init(name: "refused init", size: 4, pages: [], limit: 4, failure: .device, requests: 0, refusedInit: true),
            .init(name: "malformed page", size: 4, pages: [4], limit: 4, failure: .response, requests: 1, capacity: 4, malformedPage: true),
            .init(name: "refused page", size: 4, pages: [4], limit: 4, failure: .device, requests: 1, capacity: 4, refusedPage: true)
        ]
        for test in cases {
            let wire = BoundedReadWire(test)
            let session = SysExSession(wire: wire, identityCode: 0x10)
            let allocations = ReadAllocations()
            let files = DeviceFileService(session: session, allocateReadBuffer: { allocations.allocate($0) })
            let progress = ReadProgress()
            do {
                let read: (name: String, data: [UInt8])
                if test.offset == 0 {
                    read = try await files.getWhole(fileID: 1, maximumBytes: test.limit) { progress.record($0, $1) }
                } else {
                    let partial = try await files.get(fileID: 1, offset: test.offset, maximumBytes: test.limit) { progress.record($0, $1) }
                    read = (partial.name, try wholeData(partial.data, announced: partial.size, fileID: 1))
                }
                check(test.failure == nil && read.data.count == test.expected && read.name == "sound" && read.data.allSatisfy { $0 == 7 },
                      "bounded read: \(test.name) returns exactly the announced bytes")
            } catch {
                check(test.accepts(error), "bounded read: \(test.name) refuses with the expected error, got \(error)")
            }
            check(progress.values.allSatisfy { $0[0] <= $0[1] && $0[0] <= (test.limit ?? Int.max) },
                  "bounded read: \(test.name) never publishes over-budget or over-announcement progress")
            eq(wire.dataRequests, test.requests, "bounded read: \(test.name) data request boundary")
            eq(wire.initRequests, test.initRequests, "bounded read: \(test.name) init request boundary")
            eq(allocations.capacities, test.capacity.map { [$0] } ?? [],
               "bounded read: \(test.name) actual reader requests no allocation before validation")
            let next = Task { try await files.list(nodeID: 0) }
            for _ in 0..<1000 {
                if wire.listRequests > 0 { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            check(wire.listRequests == 1, "bounded read: \(test.name) releases service ownership")
            if wire.listRequests == 1 { check((try? await next.value)?.isEmpty == true, "bounded read: next operation completes") }
            else { next.cancel() }
            await session.close()
        }
        await readCompatibilityChecks()
    }

    private static func readCompatibilityChecks() async {
        for offset: UInt32 in [0, 2, 7] {
            var results: [(String, [UInt8], Int, [[Int]], [Int])] = []
            for explicitNil in [false, true] {
                let test = BoundedReadCase(name: "legacy", size: 6, pages: [2, 2, 2], limit: nil, offset: offset)
                let wire = BoundedReadWire(test)
                let session = SysExSession(wire: wire, identityCode: 0x10)
                let allocations = ReadAllocations()
                let files = DeviceFileService(session: session, allocateReadBuffer: { allocations.allocate($0) })
                let progress = ReadProgress()
                do {
                    let read = if explicitNil {
                        try await files.get(fileID: 1, offset: offset, maximumBytes: nil) { progress.record($0, $1) }
                    } else {
                        try await files.get(fileID: 1, offset: offset) { progress.record($0, $1) }
                    }
                    results.append((read.name, read.data, read.size, progress.values, allocations.capacities))
                } catch { check(false, "bounded read: legacy offset \(offset) threw \(error)") }
                await session.close()
            }
            check(results.count == 2 && results[0].0 == results[1].0 && results[0].1 == results[1].1
                  && results[0].2 == results[1].2 && results[0].3 == results[1].3 && results[0].4 == results[1].4,
                  "bounded read: nil/default preserve offset results, progress and allocation")
            if let read = results.first {
                eq(read.2, 6 - Int(offset), "bounded read: legacy reported remaining count is unchanged")
                eq(read.4, [6], "bounded read: legacy reserve still uses announced full size")
                let count = max(6 - Int(offset), 0)
                eq(read.1, Array(repeating: 7, count: count), "bounded read: legacy offset bytes are unchanged")
                let expectedProgress = stride(from: 2, through: count, by: 2).map { [$0, 6 - Int(offset)] }
                eq(read.3, expectedProgress, "bounded read: legacy progress events are unchanged")
            }
        }
        for explicitNil in [false, true] {
            let wire = BoundedReadWire(.init(name: "whole legacy", size: 4, pages: [2, 2], limit: nil))
            let session = SysExSession(wire: wire, identityCode: 0x10)
            let files = DeviceFileService(session: session)
            let progress = ReadProgress()
            do {
                let read = if explicitNil {
                    try await files.getWhole(fileID: 1, maximumBytes: nil) { progress.record($0, $1) }
                } else {
                    try await files.getWhole(fileID: 1) { progress.record($0, $1) }
                }
                check(read.name == "sound" && read.data == [7, 7, 7, 7], "bounded read: nil/default whole read retains bytes and trailing closure")
                eq(progress.values, [[2, 4], [4, 4]], "bounded read: nil/default whole read retains progress")
            } catch { check(false, "bounded read: legacy whole read threw \(error)") }
            await session.close()
        }
        let offsetWire = BoundedReadWire(.init(name: "large legacy offset", size: .max, pages: [4], limit: nil))
        let offsetSession = SysExSession(wire: offsetWire, identityCode: 0x10)
        let allocations = ReadAllocations()
        let offsetFiles = DeviceFileService(session: offsetSession, allocateReadBuffer: { allocations.allocate($0) })
        do {
            let read = try await offsetFiles.get(fileID: 1, offset: .max - 4)
            check(read.size == 4 && read.data == [7, 7, 7, 7], "bounded read: unlimited large offset retains remaining result")
            eq(allocations.capacities, [Int(UInt32.max)], "bounded read: unlimited large offset retains legacy allocation request")
        } catch { check(false, "bounded read: legacy large offset threw \(error)") }
        await offsetSession.close()
        let test = BoundedReadCase(name: "legacy overshoot", size: 3, pages: [4], limit: nil)
        let wire = BoundedReadWire(test)
        let session = SysExSession(wire: wire, identityCode: 0x10)
        let files = DeviceFileService(session: session)
        do {
            let read = try await files.get(fileID: 1)
            check(read.data.count == 4 && read.size == 3, "bounded read: unlimited get retains legacy overshoot result")
            let progress = ReadProgress()
            _ = try await files.getWhole(fileID: 1) { progress.record($0, $1) }
            check(false, "bounded read: unlimited whole read still rejects overshoot")
        } catch FileServiceError.truncated(_, let expected, let got) {
            check(expected == 3 && got == 4, "bounded read: unlimited whole read keeps exact-size validation")
        } catch { check(false, "bounded read: legacy overshoot threw \(error)") }
        await session.close()
    }
}

private struct BoundedReadCase: Sendable {
    enum Failure { case limit, offset, negative, truncated, page, response, device }
    let name: String
    let size: UInt32
    let pages: [Int]
    let limit: Int?
    var offset: UInt32 = 0
    var expected: Int? = nil
    var failure: Failure? = nil
    var requests = 0
    var capacity: Int? = nil
    var initRequests = 1
    var wrongPage = false
    var malformedInit = false
    var refusedInit = false
    var malformedPage = false
    var refusedPage = false

    func accepts(_ error: Error) -> Bool {
        switch (failure, error) {
        case (.limit, FileServiceError.readLimitExceeded(let id, let maximum)):
            id == 1 && maximum == limit
        case (.offset, FileServiceError.invalidReadOffset(let id, let gotOffset, let gotSize)):
            id == 1 && gotOffset == offset && gotSize == size
        case (.negative, FileServiceError.invalidReadLimit(let maximum)):
            maximum == limit
        case (.truncated, FileServiceError.truncated(let id, let expected, let got)):
            id == 1 && expected == Int(size) - Int(offset) && got == pages.reduce(0, +)
        case (.page, FileServiceError.unexpectedPage(let expected, let got)):
            expected == 0 && got == 1
        case (.response, FileServiceError.missingResponse), (.device, SessionError.deviceError): true
        default: false
        }
    }
}

private final class ReadAllocations: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [Int] = []
    var capacities: [Int] { lock.withLock { requested } }
    func allocate(_ capacity: Int) -> [UInt8] {
        lock.withLock { requested.append(capacity) }
        var bytes: [UInt8] = []
        // A missing reader guard must not crash the fixture with a giant allocation.
        if capacity <= 16 * 1024 * 1024 { bytes.reserveCapacity(capacity) }
        return bytes
    }
}

private final class ReadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[Int]] = []
    var values: [[Int]] { lock.withLock { recorded } }
    func record(_ done: Int, _ total: Int) { lock.withLock { recorded.append([done, total]) } }
}

private final class BoundedReadWire: MIDIWire, @unchecked Sendable {
    private let inner = FakeWire()
    private let test: BoundedReadCase
    private let lock = NSLock()
    private var dataCalls = 0
    private var initCalls = 0
    private var listCalls = 0
    var dataRequests: Int { lock.withLock { dataCalls } }
    var initRequests: Int { lock.withLock { initCalls } }
    var listRequests: Int { lock.withLock { listCalls } }

    init(_ test: BoundedReadCase) { self.test = test }
    func setMessageHandler(_ handler: (@Sendable ([UInt8]) -> Void)?) { inner.setMessageHandler(handler) }
    func send(_ bytes: [UInt8]) async throws {
        try await inner.send(bytes)
        guard let frame = TEFrame.parse(bytes), frame.payload.count >= 2 else { throw WireError.noDevice }
        let result = lock.withLock { () -> (UInt8, [UInt8]) in
            var payload: [UInt8] = []
            switch (frame.payload[0], frame.payload[1]) {
            case (FileSub.get, 0):
                initCalls += 1
                dataCalls = 0
                if test.refusedInit { return (3, []) }
                if test.malformedInit { return (0, []) }
                appendU16(1, to: &payload)
                payload.append(FileTypeFlag.file | FileCapability.read)
                appendU32(test.size, to: &payload)
                payload += Array("sound".utf8) + [0]
            case (FileSub.get, 1):
                let page = dataCalls
                dataCalls += 1
                if test.refusedPage { return (3, []) }
                if test.malformedPage { return (0, [0]) }
                appendU16(test.wrongPage ? 1 : UInt16(page), to: &payload)
                if page < test.pages.count { payload += Array(repeating: 7, count: test.pages[page]) }
            case (FileSub.list, _): listCalls += 1
            default: return (3, [])
            }
            return (0, payload)
        }
        inner.emulateIncoming(deviceResponse(to: bytes, status: result.0, payload: result.1))
    }
}
