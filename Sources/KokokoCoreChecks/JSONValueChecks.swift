import Foundation
import KokokoCore
import KokokoLibrary

extension KokokoCoreChecks {
    static func jsonValueChecks() {
        func decoded(_ text: String) -> [String: JSONValue] {
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            return object.compactMapValues { JSONValue(any: $0) }
        }
        let values = decoded(#"{"t":true,"f":false,"i":2,"d":2.0,"x":2.5,"n":null,"a":[1,null,true],"o":{"k":null},"big":9223372036854775808,"max":18446744073709551615}"#)
        eq(values["t"], .bool(true), "json true decodes as bool")
        eq(values["f"], .bool(false), "json false decodes as bool")
        eq(values["i"], .int(2), "json 2 decodes as int")
        eq(values["d"], .double(2.0), "json 2.0 decodes as double")
        eq(values["x"], .double(2.5), "json 2.5 decodes as double")
        eq(values["d"]?.intValue, 2, "an integral double still reads as an int")
        eq(values["x"]?.intValue, nil, "a fractional double does not read as an int")
        eq(values["n"], .null, "json null is kept")
        eq(values["a"], .array([.int(1), .null, .bool(true)]), "json null and bool inside an array")
        eq(values["o"], .object(["k": .null]), "json null inside an object")
        eq(values["big"], .double(9.223372036854776e18), "an integer past Int.max stays an approximate double")
        eq(values["max"], .double(1.8446744073709552e19), "the largest unsigned 64-bit integer stays positive")

        let written = (try? JSONSerialization.data(withJSONObject: ["t": JSONValue.bool(true).anyValue,
                                                                    "n": JSONValue.null.anyValue],
                                                   options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
        eq(written, #"{"n":null,"t":true}"#, "bool and null write back as JSON bool and null")

        let tricky: [String: JSONValue] = ["flag": .bool(true), "nothing": .null, "ratio": .double(2.5),
                                           "list": .array([.null, .bool(false)])]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kokoko-json-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let bin = RecycleBin(root: root.appendingPathComponent("bin"))
            let entry = try bin.add(SoundBackup(nodeID: 4, pcm: [1], metadata: tricky))
            eq(try bin.load(entry).metadata, tricky, "bin keeps bool, null and fractional metadata")

            let backupDir = root.appendingPathComponent("backup")
            try BackupStore.write(DeviceBackup(deviceSKU: "x", osVersion: "y", createdAt: Date(),
                                               sounds: [SoundBackup(nodeID: 4, pcm: [1], metadata: tricky)],
                                               projectMetadata: [9: tricky]), to: backupDir)
            let reread = try BackupStore.read(from: backupDir)
            eq(reread.sounds.first?.metadata, tricky, "backup folder keeps bool, null and fractional sound metadata")
            eq(reread.projectMetadata[9], tricky, "backup folder keeps bool, null and fractional project metadata")
        } catch {
            check(false, "json value store round trip threw \(error)")
        }
    }
}
