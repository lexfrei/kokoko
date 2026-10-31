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
