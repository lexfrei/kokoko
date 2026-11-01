import KokokoLibrary

extension KokokoCoreChecks {
    static func appCommandChecks() {
        let all = AppCommand.allCases
        func enabled(tab: HeaderTab = .sounds, connected: Bool = true, busy: Bool = false, selection: Int = 0,
                     modalOpen: Bool = false) -> [AppCommand] {
            all.filter { $0.isEnabled(tab: tab, connected: connected, busy: busy, selection: selection, modalOpen: modalOpen) }
        }

        eq(all.filter { $0.title.isEmpty }, [], "commands: every command has a title")
        let keys = all.compactMap(\.shortcut)
        eq(Set(keys).count, keys.count, "commands: no two commands share a shortcut")
        eq(AppCommand.addSounds.shortcut, Shortcut("o"), "commands: add sounds is Command-O, the standard Open")
        eq(AppCommand.refresh.shortcut, Shortcut("r"), "commands: refresh is Command-R")
        eq([AppCommand.showSounds, .showProjects, .showSettings, .showBin].map(\.shortcut),
           [Shortcut("1"), Shortcut("2"), Shortcut("3"), Shortcut("4")], "commands: the tabs are Command-1 to Command-4, in header order")
        // Standard keys: Command-Delete deletes to the line start in a focused text
        // field, Command-B is Bold, Shift-Command-S is Save As.
        for taken in [Shortcut("\u{8}"), Shortcut("\u{7F}"), Shortcut("b"), Shortcut("s", shift: true)] {
            check(!keys.contains(taken), "commands: \(taken) is left to the system")
        }
        eq(AppCommand.deleteSelected.shortcut, nil, "commands: delete has no menu shortcut; the list handles the Delete key")

        eq(AppCommand.addSounds.selectsTab, .sounds, "commands: add sounds switches to the sounds tab to show the upload")
        eq([AppCommand.showSounds, .showProjects, .showSettings, .showBin].map(\.selectsTab),
           [.sounds, .projects, .settings, .bin], "commands: each tab command selects its tab")

        eq(enabled(busy: true), [.showSounds, .showBin],
           "commands: while the device is busy only the tabs that do not read from it on opening stay available")
        eq(enabled(connected: false), [.showSounds, .showProjects, .showSettings, .showBin, .scan],
           "commands: without a device only the tabs and the scan are available")
        eq(enabled(tab: .bin, connected: false), [.showSounds, .showProjects, .showSettings, .showBin, .refresh, .scan],
           "commands: the bin refreshes without a device")
        eq(enabled(selection: 0).contains(.downloadSelected) || enabled(selection: 0).contains(.deleteSelected), false,
           "commands: nothing selected, nothing to download or delete")
        check(enabled(selection: 2).contains(.downloadSelected) && enabled(selection: 2).contains(.deleteSelected),
              "commands: a selection on the sounds tab can be downloaded and deleted")
        check(!enabled(tab: .projects, selection: 2).contains(.downloadSelected) && !enabled(tab: .projects, selection: 2).contains(.deleteSelected),
              "commands: the sound selection is not acted on from another tab")
        check(enabled(tab: .bin).contains(.addSounds), "commands: add sounds works from any tab while connected")
        eq(enabled(), all.filter { ![.downloadSelected, .deleteSelected, .scan].contains($0) },
           "commands: connected and idle, everything but the selection commands and the scan is available")
        let panelCommands: [AppCommand] = [.addSounds, .downloadSelected, .backupSounds, .backupProjects, .backupAll, .restoreBackup]
        eq(all.filter(\.opensPanel), panelCommands, "commands: the commands that open a file panel")
        eq(enabled(selection: 1, modalOpen: true).filter(panelCommands.contains), [],
           "commands: while a panel, alert or sheet is up, no command opens a file panel")
        check(enabled(selection: 1, modalOpen: true).contains(.showBin), "commands: the tabs stay available while a panel, alert or sheet is up")
        check(!enabled().contains(.scan), "commands: no scan while a device is connected; the scan would open the device a second time")
    }
}
