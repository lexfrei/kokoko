import Foundation

/// One recycle bin row: the slot the sound came from, its name, and when it
/// was deleted, to the minute.
public func binRowLabel(slot: UInt16, name: String, deletedAt: Date,
                        timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return String(format: "%03d", slot) + " \(name)  " + formatter.string(from: deletedAt)
}
