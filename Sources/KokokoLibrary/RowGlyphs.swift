/// A per-row action, drawn as a bracketed glyph and read by name, since a
/// screen reader would otherwise spell out the brackets.
public enum RowAction: CaseIterable, Sendable {
    case play, download, rename, renumber, metadata, delete, restore, removeFromBin, downloadArchive

    public var glyph: String {
        switch self {
        case .play: "[>]"
        case .download: "[v]"
        case .rename: "[r]"
        case .renumber: "[#]"
        case .metadata: "[m]"
        case .delete, .removeFromBin: "[x]"
        case .restore: "[restore]"
        case .downloadArchive: "[v tar]"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .play: "Play preview"
        case .download: "Download"
        case .rename: "Rename"
        case .renumber: "Change slot"
        case .metadata: "Edit metadata"
        case .delete: "Delete"
        case .restore: "Put back on the device"
        case .removeFromBin: "Remove from bin"
        case .downloadArchive: "Download archive"
        }
    }
}

/// A tab's text in the header. The selected tab is marked by asterisks inside its
/// brackets as well as by color, and keeps the same width.
public func tabTitle(_ name: String, selected: Bool) -> String {
    selected ? "[*\(name)*]" : "[ \(name) ]"
}
