import Foundation
import KokokoCore
import KokokoLibrary

extension KokokoCoreChecks {
    static func confirmationChecks() {
        eq(RestoreSummary(soundCount: 12, projects: ["03", "01"], hasProjectSettings: false).message,
           "12 sounds are restored. "
               + "A sound whose original slot already holds the same audio keeps that slot and takes the backup's name and settings; any other goes into its original slot when free, or into another free slot. "
               + "P01 and P03 are replaced with the backup's archives where those slots exist on the device.",
           "restore: names the sound count and the project slots it replaces")
        eq(RestoreSummary(soundCount: 1, projects: [], hasProjectSettings: false).message,
           "1 sound is restored. "
               + "A sound whose original slot already holds the same audio keeps that slot and takes the backup's name and settings; any other goes into its original slot when free, or into another free slot.",
           "restore: one sound, no projects")
        eq(RestoreSummary(soundCount: 0, projects: ["02"], hasProjectSettings: false).message,
           "P02 is replaced with the backup's archive where that slot exists on the device.",
           "restore: one project, no sounds")
        eq(RestoreSummary(soundCount: 0, projects: ["01", "02", "05"], hasProjectSettings: false).message,
           "P01, P02 and P05 are replaced with the backup's archives where those slots exist on the device.",
           "restore: several projects are listed in order")
        eq(RestoreSummary(soundCount: 0, projects: [], hasProjectSettings: true).message,
           "Project settings from the backup are applied to the matching projects on the device.",
           "restore: settings alone are still named as written")
        eq(RestoreSummary(soundCount: 0, projects: [], hasProjectSettings: false).message,
           "nothing in this backup is written to the device.",
           "restore: a backup with nothing to write says so")
        let legacyOnly = DeviceBackup(deviceSKU: "", osVersion: "", createdAt: Date(), sounds: [],
                                      projectMetadata: [:], legacyProjectSettings: 3)
        eq(RestoreSummary(legacyOnly).message, "nothing in this backup is written to the device.",
           "restore: an older backup's unrestorable settings are not called absent")
        let archives = DeviceBackup(deviceSKU: "", osVersion: "", createdAt: Date(), sounds: [],
                                    projectMetadata: [:], projectArchives: ["02": [], "01": []])
        check(RestoreSummary(archives).message.hasPrefix("P01 and P02 are replaced"),
              "restore: the archives in a backup are named in order")
        eq(RestoreSummary(soundCount: 2, projects: ["01"], hasProjectSettings: true).message,
           "2 sounds are restored. "
               + "A sound whose original slot already holds the same audio keeps that slot and takes the backup's name and settings; any other goes into its original slot when free, or into another free slot. "
               + "P01 is replaced with the backup's archive where that slot exists on the device. "
               + "Project settings from the backup are applied to the matching projects on the device.",
           "restore: settings are named next to sounds and archives too")
        let settingsOnly = DeviceBackup(deviceSKU: "", osVersion: "", createdAt: Date(), sounds: [],
                                        projectMetadata: ["/projects/01": ["bpm": .int(120)]])
        check(RestoreSummary(settingsOnly).message.hasPrefix("Project settings"),
              "restore: a backup with only project settings is not called empty")
        eq(SwapSummary(dragged: (3, "kick"), target: (7, "snare")).message,
           "003 kick moves to slot 007 and 007 snare to slot 003.",
           "swap: names both sounds and where each goes")
    }
}
