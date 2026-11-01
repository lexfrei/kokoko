import KokokoCore
import KokokoMIDI

extension KokokoCoreChecks {
    static func settingsValueChecks() {
        let accepted: [(JSONValue, String)] = [
            (.int(5), "5"), (.double(0.5), "0.5"), (.string("x"), "\"x\""), (.bool(true), "true"), (.null, "null"),
            (.array([.int(1), .null]), "[1,null]"), (.object(["k": .bool(false)]), "{\"k\":false}"),
        ]
        for (value, json) in accepted {
            eq((try? SettingsService.valueJSON(value)).map { String(decoding: $0, as: UTF8.self) }, json,
               "settings value: \(json) is written as JSON")
        }
        let refused: [(String, JSONValue)] = [
            ("NaN", .double(.nan)), ("infinity", .double(.infinity)),
            ("NaN in an array", .array([.double(.nan)])), ("infinity in an object", .object(["k": .double(-.infinity)])),
        ]
        for (label, value) in refused {
            do {
                _ = try SettingsService.valueJSON(value)
                check(false, "settings value: \(label) is refused")
            } catch SettingsError.unserializableValue {
                check(true, "settings value: \(label) is refused")
            } catch {
                check(false, "settings value: \(label) is refused with its own error — got \(error)")
            }
        }
    }
}
