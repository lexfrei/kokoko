import KokokoLibrary

extension KokokoCoreChecks {
    static func headerTabChecks() {
        eq(HeaderTab.allCases.map(\.title), ["sounds", "projects", "settings", "bin"], "tabs: all four, in header order")
        eq(HeaderTab.allCases.filter { !$0.needsDevice }, [.bin], "tabs: only the bin works without a device")
        for tab in HeaderTab.allCases where tab.needsDevice {
            eq(tabNotice(tab, connected: false), "device not connected", "tabs: \(tab.title) says the device is not connected")
            eq(tabNotice(tab, connected: true), nil, "tabs: \(tab.title) shows its content with a device")
        }
        eq(tabNotice(.bin, connected: false), nil, "tabs: the bin shows its content without a device")
        eq(HeaderTab.allCases.filter { $0.isEnabled(deviceBusy: false) }.count, 4, "tabs: every tab can be chosen when the device is idle")
        eq(HeaderTab.allCases.filter(\.readsDeviceWhenOpened), [.projects, .settings],
           "tabs: projects and settings read from the device when opened")
        eq(HeaderTab.allCases.filter { $0.isEnabled(deviceBusy: true) }, [.sounds, .bin],
           "tabs: while the device is busy, the tabs that load from it on opening wait")
    }
}
