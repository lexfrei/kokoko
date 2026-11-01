import Foundation

/// What a restore will write, for the confirmation shown before it starts.
public struct RestoreSummary: Sendable {
    public let soundCount: Int
    public let projects: [String]
    public let hasProjectSettings: Bool
    public let unreadArchives: [String]

    public init(soundCount: Int, projects: [String], hasProjectSettings: Bool, unreadArchives: [String] = []) {
        self.soundCount = soundCount
        self.projects = projects.sorted()
        self.hasProjectSettings = hasProjectSettings
        self.unreadArchives = unreadArchives.sorted()
    }

    public init(_ backup: DeviceBackup) {
        let unreadRoots = backup.unreadArchives.map { "/projects/" + $0 }
        let applied = backup.projectMetadata.keys.contains { path in
            !unreadRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        self.init(soundCount: backup.sounds.count, projects: Array(backup.projectArchives.keys),
                  hasProjectSettings: applied, unreadArchives: backup.unreadArchives)
    }

    public static let title = "restore backup?"

    public var message: String {
        var parts: [String] = []
        if soundCount > 0 {
            parts.append(soundCount == 1 ? "1 sound is restored." : "\(soundCount) sounds are restored.")
            parts.append("A sound whose original slot already holds the same audio keeps that slot and takes the "
                + "backup's name and settings; any other goes into its original slot when free, or into another free slot.")
        }
        func list(_ slots: [String]) -> String {
            let names = slots.map { "P\($0)" }
            return names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
        if !projects.isEmpty {
            parts.append(projects.count == 1
                ? "\(list(projects)) is replaced with the backup's archive where that slot exists on the device."
                : "\(list(projects)) are replaced with the backup's archives where those slots exist on the device.")
        }
        if !unreadArchives.isEmpty {
            parts.append(unreadArchives.count == 1
                ? "\(list(unreadArchives)) is missing or damaged in the backup; neither its archive nor its settings are restored."
                : "\(list(unreadArchives)) are missing or damaged in the backup; neither their archives nor their settings are restored.")
        }
        if hasProjectSettings {
            parts.append("Project settings from the backup are applied to the matching projects on the device.")
        }
        return parts.isEmpty ? "nothing in this backup is written to the device." : parts.joined(separator: " ")
    }
}

/// The confirmation shown before a dropped row swaps two sounds.
public struct SwapSummary: Sendable {
    public let dragged: (slot: UInt16, name: String)
    public let target: (slot: UInt16, name: String)

    public init(dragged: (slot: UInt16, name: String), target: (slot: UInt16, name: String)) {
        self.dragged = dragged
        self.target = target
    }

    public static let title = "swap these sounds?"

    public var message: String {
        func slot(_ id: UInt16) -> String { String(format: "%03d", id) }
        return "\(slot(dragged.slot)) \(dragged.name) moves to slot \(slot(target.slot)) and "
            + "\(slot(target.slot)) \(target.name) to slot \(slot(dragged.slot))."
    }
}
