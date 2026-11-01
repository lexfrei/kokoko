/// A Command-key shortcut; `shift` adds Shift.
public struct Shortcut: Hashable, Sendable {
    public let key: Character
    public let shift: Bool

    public init(_ key: Character, shift: Bool = false) {
        self.key = key
        self.shift = shift
    }
}

public enum AppCommand: CaseIterable, Sendable {
    case addSounds, downloadSelected, deleteSelected
    case backupSounds, backupProjects, backupAll, restoreBackup
    case showSounds, showProjects, showSettings, showBin
    case refresh, scan

    public var title: String {
        switch self {
        case .addSounds: "Add Sounds…"
        case .downloadSelected: "Download Selected to Folder…"
        case .deleteSelected: "Delete Selected"
        case .backupSounds: "Back Up Sounds…"
        case .backupProjects: "Back Up Projects…"
        case .backupAll: "Back Up All…"
        case .restoreBackup: "Restore Backup…"
        case .showSounds: "Sounds"
        case .showProjects: "Projects"
        case .showSettings: "Settings"
        case .showBin: "Bin"
        case .refresh: "Refresh"
        case .scan: "Scan for Devices"
        }
    }

    public var shortcut: Shortcut? {
        switch self {
        case .addSounds: Shortcut("o")
        case .showSounds: Shortcut("1")
        case .showProjects: Shortcut("2")
        case .showSettings: Shortcut("3")
        case .showBin: Shortcut("4")
        case .refresh: Shortcut("r")
        default: nil
        }
    }

    /// The tab the command switches to before it runs.
    public var selectsTab: HeaderTab? {
        switch self {
        case .addSounds, .showSounds: .sounds
        case .showProjects: .projects
        case .showSettings: .settings
        case .showBin: .bin
        default: nil
        }
    }

    public var opensPanel: Bool {
        switch self {
        case .addSounds, .downloadSelected, .backupSounds, .backupProjects, .backupAll, .restoreBackup: true
        default: false
        }
    }

    /// `modalOpen`: a file panel, alert, dialog or sheet is up. A file panel
    /// requested then does not appear and its request stays pending, and an
    /// open file panel acts on whichever command set it last.
    public func isEnabled(tab: HeaderTab, connected: Bool, busy: Bool, selection: Int, modalOpen: Bool) -> Bool {
        if modalOpen && opensPanel { return false }
        return switch self {
        case .showSounds, .showProjects, .showSettings, .showBin:
            selectsTab.map { $0.isEnabled(deviceBusy: busy) } ?? false
        case .scan:
            !busy && !connected
        case .refresh:
            !busy && (connected || !tab.needsDevice)
        case .downloadSelected, .deleteSelected:
            connected && !busy && tab == .sounds && selection > 0
        case .addSounds, .backupSounds, .backupProjects, .backupAll, .restoreBackup:
            connected && !busy
        }
    }
}
