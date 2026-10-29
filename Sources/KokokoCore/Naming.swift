import Foundation

/// Filename rules observed in the original tool: drop extension, strip unsafe
/// characters, transliterate diacritics, cap at 16 chars, lowercase.
public func normalizedDeviceFileName(_ name: String, stripLeadingNumber: Bool = false) -> String {
    var a = name
    if stripLeadingNumber, let range = a.range(of: #"^\d{3} "#, options: .regularExpression) {
        a.removeSubrange(range)
    }
    // Drop extension: everything after the first dot-group at the end.
    let parts = a.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count > 1 {
        a = parts.dropLast().joined(separator: ".")
    }
    a = a.replacingOccurrences(of: "/", with: "")
    a = a.trimmingCharacters(in: .whitespaces)
    a = a.decomposedStringWithCanonicalMapping
        .components(separatedBy: CharacterSet.nonBaseCharacters).joined()
    a = String(a.unicodeScalars.map { (0x20...0x7F).contains($0.value) ? Character($0) : "?" })
    a = a.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
    if a.count > 16 {
        a = a.prefix(7) + "." + a.suffix(8)
    }
    return a.lowercased()
}

/// CRC-32 (ISO-HDLC, reflected, poly 0xEDB88320), chained across chunks.
public func crc32(_ data: some Sequence<UInt8>, continuing previous: UInt32 = 0) -> UInt32 {
    var c = previous ^ 0xFFFFFFFF
    for byte in data {
        c ^= UInt32(byte)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1
        }
    }
    return c ^ 0xFFFFFFFF
}
