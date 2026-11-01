import CoreMIDI
import Foundation
import KokokoMIDI
import VirtualEP

extension KokokoCoreChecks {
    private final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    static func hotplugChecks() async {
        check(isDeviceChange(.msgPropertyChanged, property: kMIDIPropertyOffline as String),
              "hotplug: an offline flag change counts as a device change")
        check(!isDeviceChange(.msgPropertyChanged, property: kMIDIPropertyName as String),
              "hotplug: a renamed endpoint is not a device change")
        check(isDeviceChange(.msgObjectAdded, property: nil), "hotplug: an added object is a device change")
        check(isDeviceChange(.msgObjectRemoved, property: nil), "hotplug: a removed object is a device change")
        check(!isDeviceChange(.msgSetupChanged, property: nil),
              "hotplug: a bare setup change is not a device change, it follows every other notification")
        check(!isDeviceChange(.msgIOError, property: nil), "hotplug: an I/O error is not a device change")

        let vep = VirtualEPDevice(name: "kokoko-vep-hotplug-\(getpid())")
        func listed() -> Bool { enumerateMIDIPairs().contains { $0.name == vep.name } }
        let signals = Signals()
        do {
            let watcher = try HotplugWatcher { signals.bump() }
            defer { withExtendedLifetime(watcher) {} }
            try vep.start()
            try await Task.sleep(for: .milliseconds(300))
            check(listed(), "vep: a started device is listed")
            let plugged = signals.value
            check(plugged > 0, "hotplug: plugging a device in is signalled")
            guard let pair = enumerateMIDIPairs().first(where: { $0.name == vep.name }) else { return }
            check(pairIsOnline(pair), "hotplug: a plugged-in pair is online")

            try await Task.sleep(for: .milliseconds(300))
            let beforeRename = signals.value
            MIDIObjectSetStringProperty(pair.destination, kMIDIPropertyName, "\(vep.name) renamed" as CFString)
            try await Task.sleep(for: .milliseconds(300))
            eq(signals.value, beforeRename, "hotplug: renaming a port is not signalled")
            MIDIObjectSetStringProperty(pair.destination, kMIDIPropertyName, vep.name as CFString)
            try await Task.sleep(for: .milliseconds(300))

            let beforeOffline = signals.value
            vep.setOffline(true)
            try await Task.sleep(for: .milliseconds(300))
            check(!pairIsOnline(pair), "hotplug: an offline pair is not online")
            check(signals.value > beforeOffline, "hotplug: going offline is signalled")
            let beforeOnline = signals.value
            vep.setOffline(false)
            try await Task.sleep(for: .milliseconds(300))
            check(pairIsOnline(pair), "hotplug: a pair back online is online")
            check(signals.value > beforeOnline, "hotplug: coming back online is signalled")
            let beforeUnplug = signals.value
            vep.stop()
            try await Task.sleep(for: .milliseconds(300))
            check(!listed(), "vep: a stopped device is no longer listed")
            check(signals.value > beforeUnplug, "hotplug: unplugging a device is signalled")
            check(!pairIsOnline(pair), "hotplug: an unplugged pair is no longer online")
            try vep.start()
            try await Task.sleep(for: .milliseconds(300))
            check(listed(), "vep: a device started again after stop is listed")
            vep.stop()
        } catch {
            check(false, "hotplug checks threw \(error)")
        }
    }
}
