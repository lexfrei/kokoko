import Foundation

/// What a restore will write, for the confirmation shown before it starts.
public struct RestoreSummary: Sendable {
    public let soundCount: Int
    public let projects: [String]
    public let hasProjectSettings: Bool

    public init(soundCount: Int, projects: [String], hasProjectSettings: Bool) {
        self.soundCount = soundCount
        self.projects = projects.sorted()
        self.hasProjectSettings = hasProjectSettings
    }

    public init(_ backup: DeviceBackup) {
        self.init(soundCount: backup.sounds.count, projects: Array(backup.projectArchives.keys),
                  hasProjectSettings: !backup.projectMetadata.isEmpty)
    }

    public static let title = "restore backup?"

    public var message: String {
        var parts: [String] = []
        if soundCount > 0 {
            parts.append(soundCount == 1 ? "1 sound is restored." : "\(soundCount) sounds are restored.")
            parts.append("A sound whose original slot already holds the same audio keeps that slot and takes the "
                + "backup's name and settings; any other goes into its original slot when free, or into another free slot.")
        }
        if !projects.isEmpty {
            let names = projects.map { "P\($0)" }
            let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
            parts.append(names.count == 1
                ? "\(list) is replaced with the backup's archive where that slot exists on the device."
                : "\(list) are replaced with the backup's archives where those slots exist on the device.")
        }
        if hasProjectSettings {
            parts.append("Project settings from the backup are applied to the matching projects on the device.")
        }
        return parts.isEmpty ? "nothing in this backup is written to the device." : parts.joined(separator: " ")
    }
}
