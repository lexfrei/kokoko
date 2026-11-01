import Foundation
import KokokoMIDI

extension KokokoCoreChecks {
    static func hotplugPolicyChecks() {
        var idle = HotplugPolicy(debounce: 1)
        eq(idle.changed(now: 0, pairOnline: false), .rescanLater, "hotplug policy: a change while unconnected asks for a rescan")
        check(!idle.takeRescan(now: 0.5, busy: false), "hotplug policy: no rescan before the debounce ends")
        check(idle.takeRescan(now: 1, busy: false), "hotplug policy: a rescan once the debounce ends")
        check(!idle.takeRescan(now: 2, busy: false), "hotplug policy: one rescan per burst")

        var burst = HotplugPolicy(debounce: 1)
        _ = burst.changed(now: 0, pairOnline: false)
        _ = burst.changed(now: 0.8, pairOnline: false)
        check(!burst.takeRescan(now: 1.2, busy: false), "hotplug policy: a later change in a burst pushes the rescan back")
        check(burst.takeRescan(now: 1.8, busy: false), "hotplug policy: the rescan runs after the last change of a burst")

        var busy = HotplugPolicy(debounce: 1)
        _ = busy.changed(now: 0, pairOnline: false)
        check(!busy.takeRescan(now: 5, busy: true), "hotplug policy: no rescan while an operation holds the device")
        check(busy.takeRescan(now: 5, busy: false), "hotplug policy: the deferred rescan runs once the device is free")

        var connected = HotplugPolicy(debounce: 1)
        check(connected.commitConnection(token: connected.currentGeneration()), "hotplug policy: a scan commits its connection")
        eq(connected.changed(now: 0, pairOnline: true), .none, "hotplug policy: another device's change leaves a connection alone")
        check(!connected.takeRescan(now: 5, busy: false), "hotplug policy: no rescan while connected")
        eq(connected.changed(now: 10, pairOnline: false), .disconnect, "hotplug policy: losing the connected pair disconnects")
        check(!connected.isConnected, "hotplug policy: a disconnect drops the connection")
        check(connected.takeRescan(now: 11, busy: false), "hotplug policy: a disconnect is followed by a rescan")

        // A scan that started before a disconnect must not bring back a stale connection.
        var stale = HotplugPolicy(debounce: 1)
        _ = stale.commitConnection(token: stale.currentGeneration())
        let token = stale.currentGeneration()
        _ = stale.changed(now: 0, pairOnline: false)
        check(!stale.commitConnection(token: token), "hotplug policy: a scan begun before a disconnect cannot commit")
        check(!stale.isConnected, "hotplug policy: a refused commit leaves the device disconnected")
        check(stale.commitConnection(token: stale.currentGeneration()), "hotplug policy: a scan begun after the disconnect commits")

        // Work begun on one device must not write its results once another may be connected.
        var current = HotplugPolicy(debounce: 1)
        _ = current.commitConnection(token: current.currentGeneration())
        let started = current.currentGeneration()
        check(current.isCurrent(started), "hotplug policy: work begun on the connected device is current")
        _ = current.changed(now: 0, pairOnline: false)
        check(!current.isCurrent(started), "hotplug policy: work begun before a disconnect is no longer current")
    }
}
