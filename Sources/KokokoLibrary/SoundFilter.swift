import Foundation

/// Every query matches the name, case-insensitively. An all-digit query also
/// matches the zero-padded slot by prefix or the exact slot: "1" finds slot 1
/// and 100..199 but not 10..19, "01" finds 010..019, "808" finds "808 kick".
public func soundMatches(name: String, slot: UInt16, query: String) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces)
    if q.isEmpty { return true }
    if name.localizedCaseInsensitiveContains(q) { return true }
    guard q.allSatisfy(\.isASCII) && q.allSatisfy(\.isNumber) else { return false }
    return String(format: "%03d", slot).hasPrefix(q) || String(slot) == q
}

/// Selection restricted to slots that exist and pass the filter, so batch
/// actions never reach rows the user cannot see.
public func visibleSelection(_ selection: Set<UInt16>,
                             items: [(slot: UInt16, name: String)],
                             query: String) -> Set<UInt16> {
    let visible = items.filter { soundMatches(name: $0.name, slot: $0.slot, query: query) }
    return selection.intersection(visible.map(\.slot))
}

/// Why the sound list shows no rows, said in place of them.
public enum SoundListEmpty: Equatable, Sendable {
    case noSounds
    case noMatch(String)

    public var text: String {
        switch self {
        case .noSounds: "no sounds on the device"
        case .noMatch(let query): "no sound matches \"\(query)\""
        }
    }
}

/// With no sounds at all, the filter is not what hides them. An empty list
/// is called empty only once a listing has succeeded and the device is not
/// busy, since otherwise it may be unread or still loading.
public func soundListEmpty(total: Int, visible: Int, query: String, deviceBusy: Bool = false,
                           listed: Bool = true) -> SoundListEmpty? {
    if total == 0 { return listed && !deviceBusy ? .noSounds : nil }
    return visible == 0 ? .noMatch(query.trimmingCharacters(in: .whitespaces)) : nil
}
