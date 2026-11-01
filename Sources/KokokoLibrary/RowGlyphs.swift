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
        case .restore: "Restore to the device"
        case .removeFromBin: "Remove from bin"
        case .downloadArchive: "Download tar archive"
        }
    }
}

/// A tab's text in the header. The selected tab is marked by asterisks inside its
/// brackets as well as by color, and keeps the same width.
public func tabTitle(_ name: String, selected: Bool) -> String {
    selected ? "[*\(name)*]" : "[ \(name) ]"
}

/// A bracketed text button outside the rows.
public enum BarAction: CaseIterable, Sendable {
    case retry, moveSelection, downloadSelection, deleteSelection
    case addSounds, backupSounds, backupProjects, backupAll, restoreBackup, refresh

    public var text: String {
        switch self {
        case .retry: "[ retry ]"
        case .moveSelection: "[ move ]"
        case .downloadSelection: "[ v to folder ]"
        case .deleteSelection: "[ x ]"
        case .addSounds: "[ + add sounds ]"
        case .backupSounds: "[ back up sounds ]"
        case .backupProjects: "[ back up projects ]"
        case .backupAll: "[ back up all ]"
        case .restoreBackup: "[ restore backup ]"
        case .refresh: "[ refresh ]"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .retry: "Retry"
        case .moveSelection: "Move to slot"
        case .downloadSelection: "Download to folder"
        case .deleteSelection: "Delete selected"
        case .addSounds: "Add sounds"
        case .backupSounds: "Back up sounds"
        case .backupProjects: "Back up projects"
        case .backupAll: "Back up all"
        case .restoreBackup: "Restore backup"
        case .refresh: "Refresh"
        }
    }
}

/// The footer's error line and the header's connection status.
public enum StatusLine: Sendable {
    case error(String), connectionFailed(String)
    case connected(name: String, serial: String, os: String, firmware: FirmwareStatus?)

    public var text: String {
        switch self {
        case .error(let message): "error: \(message)"
        case .connectionFailed(let reason): "[ !! \(reason) ]"
        case .connected(let name, let serial, let os, let firmware):
            "[ \(name) \(serial) os \(os)\(firmwareSuffix(firmware)) ]"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .error(let message): "Error: \(message)"
        case .connectionFailed(let reason): "Connection failed: \(reason)"
        case .connected(let name, let serial, let os, let firmware):
            "Connected: \(name), serial \(serial), OS \(os)" + {
                switch firmware {
                case .current?: ", up to date"
                case .behind(let latest)?: ", update \(latest) available"
                case .ahead?: ", newer than the published release"
                case nil: ""
                }
            }()
        }
    }
}
