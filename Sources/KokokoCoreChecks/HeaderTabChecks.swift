import KokokoLibrary

extension KokokoCoreChecks {
    static func headerTabChecks() {
        eq(HeaderTab.allCases.map(\.title), ["sounds", "projects", "settings", "bin"], "tabs: all four, in header order")
        eq(HeaderTab.allCases.filter { !$0.needsDevice }, [.bin], "tabs: only the bin works without a device")
        for tab in HeaderTab.allCases where tab.needsDevice {
            eq(tabNotice(tab, device: .failed), "device not connected", "tabs: \(tab.title) says the device is not connected once the scan fails")
            eq(tabNotice(tab, device: .searching), "scanning for midi devices...", "tabs: \(tab.title) says it is scanning while it scans")
            eq(tabNotice(tab, device: .connecting("EP-133")), "connecting to EP-133...", "tabs: \(tab.title) names the device it is connecting to")
            eq(tabNotice(tab, device: .connected), nil, "tabs: \(tab.title) shows its content with a device")
        }
        for device: DevicePhase in [.searching, .connecting("EP-133"), .failed] {
            eq(tabNotice(.bin, device: device), nil, "tabs: the bin shows its content without a device (\(device))")
        }
        eq(HeaderTab.allCases.filter(\.readsDeviceWhenOpened), [.projects, .settings],
           "tabs: projects and settings read from the device when opened")
        eq(tabNotice(.projects, device: .connected, waitingForDevice: true), "device busy, loading when free",
           "tabs: a tab waiting for a busy device says it loads once the device is free")
        eq(tabNotice(.settings, device: .failed, waitingForDevice: true), "device not connected",
           "tabs: a missing device outranks waiting for it")
        eq(tabNotice(.bin, device: .connected, waitingForDevice: true), nil, "tabs: the bin never waits for the device")

        var load = PendingTabLoad()
        eq(load.open(.projects, deviceBusy: false), .projects, "tab load: a tab opened while the device is free loads now")
        eq(load.waiting, nil, "tab load: a tab that loads now does not wait")
        eq(load.open(.projects, deviceBusy: true), nil, "tab load: a tab opened while the device is busy does not load now")
        eq(load.waiting, .projects, "tab load: it waits for the device instead")
        eq(load.deviceReleased(showing: .projects), .projects, "tab load: it loads once the device is released")
        eq(load.waiting, nil, "tab load: after loading it no longer waits")
        eq(load.deviceReleased(showing: .projects), nil, "tab load: a later release loads nothing more")
        _ = load.open(.settings, deviceBusy: true)
        eq(load.deviceReleased(showing: .sounds), nil, "tab load: a tab left before the device was released does not load")
        eq(load.waiting, nil, "tab load: and stops waiting")
        _ = load.open(.projects, deviceBusy: true)
        _ = load.open(.settings, deviceBusy: true)
        eq(load.deviceReleased(showing: .settings), .settings, "tab load: the last tab opened is the one that waits")
        _ = load.open(.projects, deviceBusy: true)
        eq(load.open(.sounds, deviceBusy: true), nil, "tab load: a tab that reads nothing on opening never loads here")
        eq(load.waiting, nil, "tab load: opening such a tab ends the wait of the one before")
        eq(load.open(.settings, needsLoad: false, deviceBusy: true), nil, "tab load: a tab with nothing to load does not load")
        eq(load.waiting, nil, "tab load: nor does it wait for the device")
        _ = load.open(.projects, showing: .sounds, deviceBusy: true)
        eq(load.open(.projects, showing: .projects, deviceBusy: true), nil,
           "tab load: a waiting tab chosen again while the device is busy does not load now")
        eq(load.waiting, .projects, "tab load: it keeps waiting")
        eq(load.deviceReleased(showing: .projects), .projects, "tab load: and still loads once the device is released")
        eq(load.open(.projects, showing: .projects, deviceBusy: true), nil,
           "tab load: a tab on screen chosen again while the device is busy does not load now")
        eq(load.waiting, nil, "tab load: nor does it start waiting, so it keeps what it shows")
        eq(load.open(.projects, showing: .projects, deviceBusy: false), .projects,
           "tab load: a tab on screen chosen again while the device is free loads again")
        _ = load.open(.settings, deviceBusy: true)
        eq(load.deviceReleased(showing: .settings, needsLoad: false), nil,
           "tab load: a waiting tab that the operation holding the device already loaded does not load again")
        eq(load.waiting, nil, "tab load: and stops waiting")
    }
}
