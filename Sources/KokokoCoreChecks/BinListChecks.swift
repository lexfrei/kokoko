import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func binListChecks() {
        let utc = TimeZone(identifier: "UTC")!
        // 2026-10-31 14:05:09 UTC
        let deletedAt = Date(timeIntervalSince1970: 1_793_455_509)
        eq(binRowLabel(slot: 7, name: "micro kick", deletedAt: deletedAt, timeZone: utc),
           "007 micro kick  2026-10-31 14:05", "bin row: padded slot, name, deletion time")
        eq(binRowLabel(slot: 123, name: "x", deletedAt: deletedAt, timeZone: TimeZone(identifier: "Europe/Moscow")!),
           "123 x  2026-10-31 17:05", "bin row: time in the given zone")
    }
}
