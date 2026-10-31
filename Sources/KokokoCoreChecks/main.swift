import Foundation
import KokokoCore

// Self-check runner: no test framework is available in Command Line Tools,
// so these run via `swift run KokokoCoreChecks`. Exit code 1 on any failure.

@MainActor
@main
struct KokokoCoreChecks {
    static var failures = 0

    static func check(_ cond: Bool, _ name: String) {
        if cond {
            print("ok   \(name)")
        } else {
            print("FAIL \(name)")
            failures += 1
        }
    }

    static func eq<T: Equatable>(_ a: T, _ b: T, _ name: String) {
        check(a == b, "\(name) — got \(a), want \(b)")
    }

    static func main() async {
        sevenBitCoding()
        frames()
        fileMessages()
        namesAndCRC()
        await sessionChecks()
        umpChecks()
        eventListChecks()
        filterChecks()
        dropChecks()
        progressChecks()
        batchErrorChecks()
        selectionChecks()
        bulkMoveChecks()
        rollbackChecks()
        recycleBinChecks()
        fileServiceErrorChecks()
        await pairingChecks()
        do {
            try audioChecks()
        } catch {
            check(false, "audio checks threw \(error)")
        }

        if failures > 0 {
            print("\(failures) check(s) FAILED")
            exit(1)
        }
        print("all checks passed")
    }

    static func sevenBitCoding() {
        eq(SevenBitCoding.pack([]), [], "pack empty")
        eq(SevenBitCoding.unpack([]), [], "unpack empty")
        eq(SevenBitCoding.pack([0x80]), [0x01, 0x00], "pack high bit")
        eq(SevenBitCoding.unpack([0x01, 0x00]), [0x80], "unpack high bit")
        eq(SevenBitCoding.pack([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
           [0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F], "pack full group")
        let src100: [UInt8] = (0..<100).map { UInt8($0 & 0xFF) }
        eq(SevenBitCoding.unpack(SevenBitCoding.pack(src100)), src100, "round trip 100 bytes")
        let eight: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x80]
        let packed8 = SevenBitCoding.pack(eight)
        check(packed8.count == 10 && packed8[8] == 0x01 && packed8[9] == 0x00, "second header at 8")
        eq(SevenBitCoding.unpack(packed8), eight, "round trip 8 bytes")
        eq(SevenBitCoding.packedLength(for: 0), 0, "packedLength 0")
        eq(SevenBitCoding.packedLength(for: 7), 8, "packedLength 7")
        eq(SevenBitCoding.packedLength(for: 8), 10, "packedLength 8")
    }

    static func frames() {
        let greet = TEFrame(identityCode: 0x10, requestID: 0x123, command: TECommand.greet, payload: [])
        eq(greet.bytes, [0xF0, 0x00, 0x20, 0x76, 0x10, 0x40, 0x62, 0x23, 0x01, 0xF7], "greet request bytes")

        let echoFrame = TEFrame(identityCode: 0, requestID: 0, command: TECommand.echo, payload: [0x80]).bytes
        check(echoFrame.count == 12 && echoFrame[9] == 0x01 && echoFrame[10] == 0x00 && echoFrame[11] == 0xF7,
              "packed payload in frame")

        let respRaw: [UInt8] = [0xF0, 0x00, 0x20, 0x76, 0x10, 0x40, 0x22, 0x23, 0x01, 0x00, 0x01, 0x41, 0xF7]
        let resp = TEFrame.parse(respRaw)
        eq(resp?.kind, .response, "parse response kind")
        eq(resp?.requestID, 0x123, "parse response request id")
        eq(resp?.command, 0x01, "parse response command")
        eq(resp?.status, .ok, "parse response status")
        eq(resp?.payload, [0xC1], "parse response payload unpacked")
        check(TEFrame.parse([]) == nil, "parse empty nil")
        check(TEFrame.parse([0xF0, 0x00, 0x20, 0x77, 0x10, 0x40, 0x60, 0x00, 0x01, 0xF7]) == nil,
              "reject foreign manufacturer")

        var logRaw: [UInt8] = [0xF0, 0x00, 0x20, 0x76, 0x10, 0x33]
        logRaw.append(contentsOf: SevenBitCoding.pack(Array("hi".utf8)))
        logRaw.append(0xF7)
        let logFrame = TEFrame.parse(logRaw)
        eq(logFrame?.kind, .deviceLog, "device log kind")
        eq(logFrame.flatMap { String(bytes: $0.payload, encoding: .utf8) }, "hi", "device log text")

        eq(TEStatus(0), .ok, "status ok")
        eq(TEStatus(1), .error, "status error")
        eq(TEStatus(2), .commandNotFound, "status not found")
        eq(TEStatus(3), .badRequest, "status bad request")
        eq(TEStatus(16), .specificError(16), "status specific error low")
        eq(TEStatus(63), .specificError(63), "status specific error high")
        eq(TEStatus(64), .specificSuccess(64), "status specific success")

        eq(Identity.requestBytes, [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], "identity request")
        let idReply: [UInt8] = [0xF0, 0x7E, 0x42, 0x06, 0x02, 0x00, 0x20, 0x76,
                                32, 0, 1, 0, 2, 0, 5, 0, 0xF7]
        eq(Identity.parseReply(idReply)?.deviceID, 0x42, "identity device id")
        eq(Identity.parseReply(idReply)?.sku, "TE032AS001", "identity sku")
        check(Identity.parseReply(Array(idReply.dropLast(2))) == nil, "identity wrong length")

        let meta = GreetMetadata.parse("chip_id:aa;mode:normal;os_version:2.1.0;product:ep;serial:s1;sku:TE032AS001;sw_version:x;base_sku:TE032AS001;ignored:zzz;")
        eq(meta.chipID, "aa", "greet chip")
        eq(meta.mode, "normal", "greet mode")
        eq(meta.osVersion, "2.1.0", "greet os")
        eq(meta.serial, "s1", "greet serial")
        eq(meta.baseSKU, "TE032AS001", "greet base sku")
    }

    static func fileMessages() {
        eq(FileInitRequest(maxResponseLength: 4 * 1024 * 1024, subscribe: true).bytes,
           [0x01, 0x01, 0x00, 0x40, 0x00, 0x00], "file init request")
        eq(FileInitResponse(payload: [0x00, 0x00, 0x04, 0x00, 0x00])?.chunkSize, 0x00040000,
           "file init chunk size")

        var putInitExpected: [UInt8] = [0x02, 0x00, 0x05, 0x00, 0x00, 0x00, 0x05, 0x01, 0x02, 0x03, 0x04]
        putInitExpected.append(contentsOf: Array("kick".utf8)); putInitExpected.append(0)
        eq(PutInitRequest(fileID: 0, parentID: 5, flags: 0x05, fileSize: 0x01020304,
                          filename: "kick", metadata: nil).bytes,
           putInitExpected, "put init request")
        eq(PutInitResponse(payload: [0x12, 0x34])?.fileID, 0x1234, "put init response")
        eq(PutInitRequest(fileID: 0, parentID: 0, flags: 0, fileSize: 0,
                          filename: String(repeating: "a", count: 80), metadata: nil).filename.count,
           54, "put init filename truncated")

        eq(PutDataRequest(page: 0x1234, data: [0xAA, 0xBB]).bytes, [0x02, 0x01, 0x12, 0x34, 0xAA, 0xBB],
           "put data")

        eq(GetInitRequest(fileID: 7, offset: 0x01020304).bytes,
           [0x03, 0x00, 0x00, 0x07, 0x01, 0x02, 0x03, 0x04], "get init request")
        let gi = GetInitResponse(payload: [0x00, 0x07, 0x05, 0x00, 0x00, 0x10, 0x00,
                                           0x73, 0x6E, 0x61, 0x72, 0x65, 0x00])
        eq(gi?.fileID, 7, "get init id")
        eq(gi?.fileSize, 0x1000, "get init size")
        eq(gi?.fileName, "snare", "get init name")
        eq(GetDataRequest(page: 3).bytes, [0x03, 0x01, 0x00, 0x03], "get data request")
        let gd = GetDataResponse(payload: [0x00, 0x03, 9, 9, 9])
        eq(gd?.page, 3, "get data page")
        eq(gd?.nextPage, 4, "get data next page")
        eq(gd?.data, [9, 9, 9], "get data payload")
        eq(GetDataResponse(payload: [0xFF, 0xFF])?.nextPage, 0, "page wraps at 65536")

        eq(ListRequest(page: 1, nodeID: 2).bytes, [0x04, 0x00, 0x01, 0x00, 0x02], "list request")
        let listPayload: [UInt8] = [0x00, 0x00]
            + [0x00, 0x2A, 0x05, 0x00, 0x00, 0x00, 0x40, 0x61, 0x00]
            + [0x00, 0x2B, 0x06, 0x00, 0x00, 0x00, 0x00, 0x62, 0x63, 0x00]
        let lr = ListResponse(payload: listPayload)
        eq(lr?.page, 0, "list page")
        eq(lr?.entries.count, 2, "list entries count")
        eq(lr?.entries[0].nodeID, 42, "list entry id")
        eq(lr?.entries[1].fileName, "bc", "list entry name")
        eq(lr?.entries[1].type, .directory, "list entry dir type")

        eq(FileInfoRequest(fileID: 9).bytes, [0x0B, 0x00, 0x09], "info request")
        let fi = FileInfoResponse(payload: [0x00, 0x09, 0x00, 0x01, 0x15,
                                            0x00, 0x00, 0x08, 0x00, 0x6E, 0x00])
        eq(fi?.nodeID, 9, "info id")
        eq(fi?.parentID, 1, "info parent")
        eq(fi?.flags, 0x15, "info flags")
        eq(fi?.fileSize, 0x800, "info size")
        eq(fi?.fileName, "n", "info name")

        eq(DeleteRequest(fileID: 0x1234).bytes, [0x06, 0x12, 0x34], "delete request")
        eq(PlaybackRequest(fileID: 1, action: .start, offset: 0, length: 1000).bytes,
           [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0x03, 0xE8], "playback start")
        eq(PlaybackRequest(fileID: 1, action: .stop, offset: 0, length: 0).bytes[1], 0x02,
           "playback stop")
        eq(MoveRequest(fileID: 1, parentID: 2, newFileID: 3).bytes,
           [0x0C, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03], "move request")
        let mv = MoveResponse(payload: [0x00, 0x01, 0x00, 0x02, 0x00, 0x03])
        eq(mv?.oldFileID, 1, "move old")
        eq(mv?.newFileID, 3, "move new")

        var setMetaExpected: [UInt8] = [0x07, 0x01, 0x00, 0x05]
        setMetaExpected.append(contentsOf: Array(#"{"a":1}"#.utf8)); setMetaExpected.append(0)
        eq(SetMetadataRequest(fileID: 5, json: #"{"a":1}"#).bytes, setMetaExpected, "set metadata")
        var getMetaExpected: [UInt8] = [0x07, 0x02, 0x00, 0x05, 0x00, 0x02]
        getMetaExpected.append(contentsOf: Array("formats".utf8)); getMetaExpected.append(0)
        eq(GetMetadataRequest(fileID: 5, page: 2, key: "formats").bytes, getMetaExpected,
           "get metadata request")
        let gmr = GetMetadataResponse(payload: [0x00, 0x02, 0x7B, 0x7D, 0x00])
        eq(gmr?.page, 2, "get metadata page")
        eq(gmr?.fragment, "{}", "get metadata fragment")
        eq(gmr?.isLast, true, "get metadata last")
        eq(SetMetadataPagedInitRequest(fileID: 5, totalSize: 0x1000).bytes,
           [0x07, 0x04, 0x00, 0x00, 0x05, 0x00, 0x00, 0x10, 0x00], "paged metadata init")
        eq(SetMetadataPagedDataRequest(page: 1, data: [1, 2]).bytes,
           [0x07, 0x04, 0x01, 0x00, 0x01, 1, 2], "paged metadata data")

        if case .addedUpdated(let id, let size, let name)? =
            FileEvent.parse([0x08, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x78, 0x00]) {
            check(id == 9 && size == 0x40 && name == "x", "event added")
        } else { check(false, "event added") }

        if case .deleted(let did) = FileEvent.parse([0x0A, 0x00, 0x09]) {
            eq(did, 9, "event deleted")
        } else { check(false, "event deleted") }

        if case .metadataUpdated(let mid, let json) =
            FileEvent.parse([0x03, 0x00, 0x09] + Array(#"{"free":5}"#.utf8) + [0x00]) {
            check(mid == 9 && json == #"{"free":5}"#, "event metadata")
        } else { check(false, "event metadata") }

        if case .moved(let o, let p, let n)? =
            FileEvent.parse([0x0D, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03]) {
            check(o == 1 && p == 2 && n == 3, "event moved")
        } else { check(false, "event moved") }

        check(FileEvent.parse([0x63]) == nil, "event unknown nil")

        eq(maxChunkPayloadLength(chunkSize: 256), 209, "max payload 256")
        eq(maxChunkPayloadLength(chunkSize: 10), 0, "max payload tiny")
    }

    static func namesAndCRC() {
        eq(normalizedDeviceFileName("Kick Drum.WAV"), "kick drum", "normalize basic")
        eq(normalizedDeviceFileName("001 snare.wav", stripLeadingNumber: true), "snare",
           "normalize strip number")
        eq(normalizedDeviceFileName("001 snare.wav", stripLeadingNumber: false), "001 snare",
           "normalize keep number")
        eq(normalizedDeviceFileName("a/b\\c\"d.wav"), "abcd", "normalize unsafe chars")
        eq(normalizedDeviceFileName("café.wav"), "cafe", "normalize diacritics")
        eq(normalizedDeviceFileName("averyverylongfilename01.wav"), "averyve.lename01",
           "normalize long name")

        eq(crc32(Array("123456789".utf8)), 0xCBF43926, "crc32 vector")
    }
}
