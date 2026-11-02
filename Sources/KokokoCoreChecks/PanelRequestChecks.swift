import KokokoLibrary

extension KokokoCoreChecks {
    static func panelRequestChecks() {
        func route(_ picker: PendingPicker, openedAt opened: Int, now: Int) -> PendingPicker? {
            var request = PanelRequest()
            request.open(picker, generation: opened)
            return request.route(currentGeneration: now)
        }
        eq(route(.restoreFolder, openedAt: 3, now: 3), .restoreFolder, "panel: a restore folder for the same device is used")
        eq(route(.backupFolder(.sounds), openedAt: 3, now: 3), .backupFolder(.sounds),
           "panel: a backup folder for the same device is used")
        eq(route(.downloadFolder([5]), openedAt: 3, now: 3), .downloadFolder([5]),
           "panel: a download folder for the same device is used")
        eq(route(.restoreFolder, openedAt: 3, now: 4), nil, "panel: a restore folder for a device that left is dropped")
        eq(route(.backupFolder(.sounds), openedAt: 3, now: 4), nil, "panel: a backup folder for a device that left is dropped")
        eq(route(.downloadFolder([5]), openedAt: 3, now: 4), nil, "panel: a download folder for a device that left is dropped")
        eq(route(.none, openedAt: 3, now: 4), PendingPicker.none, "panel: sounds to upload pass after the device changed")
        var reopened = PanelRequest()
        reopened.open(.restoreFolder, generation: 3)
        reopened.open(.none, generation: 4)
        eq(reopened.picker, PendingPicker.none, "panel: opening again replaces what it was opened for")
        eq(PanelRequest().picker, PendingPicker.none, "panel: before any panel opens it picks sounds")
    }
}
