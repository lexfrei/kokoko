import CoreMIDI
import Foundation

/// Calls `onChange` whenever CoreMIDI reports that devices or endpoints were
/// added, removed, or went offline or online, anywhere on the system, with the
/// object the notification names. Callers re-read the device list to learn
/// what changed.
public final class HotplugWatcher: @unchecked Sendable {
    private var client = MIDIClientRef()

    public init(onChange: @escaping @Sendable (MIDIObjectRef) -> Void) throws {
        let status = MIDIClientCreateWithBlock("kokoko-hotplug" as CFString, &client) { notification in
            let id = notification.pointee.messageID
            let raw = UnsafeRawPointer(notification)
            var property: String?
            var object = MIDIObjectRef()
            switch id {
            case .msgPropertyChanged:
                let change = raw.assumingMemoryBound(to: MIDIObjectPropertyChangeNotification.self).pointee
                property = change.propertyName.takeUnretainedValue() as String
                object = change.object
            case .msgObjectAdded, .msgObjectRemoved:
                object = raw.assumingMemoryBound(to: MIDIObjectAddRemoveNotification.self).pointee.child
            default:
                break
            }
            if isDeviceChange(id, property: property) { onChange(object) }
        }
        guard status == noErr else { throw CoreMIDIError.osStatus("MIDIClientCreateWithBlock", status) }
    }

    deinit {
        MIDIClientDispose(client)
    }
}

/// Whether a CoreMIDI notification can mean a device came, went, or changed
/// between offline and online. `property` is the changed property's name for
/// a property change.
public func isDeviceChange(_ message: MIDINotificationMessageID, property: String?) -> Bool {
    switch message {
    // Not msgSetupChanged: CoreMIDI sends it after every other notification,
    // a renamed port included, so it would let any change through.
    case .msgObjectAdded, .msgObjectRemoved:
        return true
    case .msgPropertyChanged:
        return property == kMIDIPropertyOffline as String
    default:
        return false
    }
}

/// Whether `pair` is still in the device list with its destination online.
public func pairIsOnline(_ pair: MIDIEndpointPair) -> Bool {
    guard enumerateMIDIPairs().contains(where: {
        $0.source == pair.source && $0.destination == pair.destination
    }) else { return false }
    var offline: Int32 = 0
    MIDIObjectGetIntegerProperty(pair.destination, kMIDIPropertyOffline, &offline)
    return offline == 0
}
