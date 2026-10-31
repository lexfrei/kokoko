import CoreMIDI
import Foundation
import KokokoMIDI

extension KokokoCoreChecks {
    static func pairingChecks() async {
        var client = MIDIClientRef()
        guard MIDIClientCreate("kokoko-pairing-check" as CFString, nil, nil, &client) == noErr else {
            check(false, "pairing: client created")
            return
        }
        defer { MIDIClientDispose(client) }

        func source(_ name: String) -> MIDIEndpointRef {
            var endpoint = MIDIEndpointRef()
            if MIDISourceCreate(client, name as CFString, &endpoint) != noErr {
                check(false, "pairing: source \(name) created")
            }
            return endpoint
        }
        func destination(_ name: String) -> MIDIEndpointRef {
            var endpoint = MIDIEndpointRef()
            if MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &endpoint, { _, _ in }) != noErr {
                check(false, "pairing: destination \(name) created")
            }
            return endpoint
        }
        func virtualPair(_ name: String) -> (source: MIDIEndpointRef, destination: MIDIEndpointRef) {
            (source(name), destination(name))
        }

        let shared = "kokoko-pairing-\(getpid())"
        let solo = "kokoko-pairing-solo-\(getpid())"
        let twoDestinations = "kokoko-pairing-2dst-\(getpid())"
        let twoSources = "kokoko-pairing-2src-\(getpid())"
        let created = [virtualPair(shared), virtualPair(shared), virtualPair(solo)]
        _ = (source(twoDestinations), destination(twoDestinations), destination(twoDestinations))
        _ = (source(twoSources), source(twoSources), destination(twoSources))
        try? await Task.sleep(for: .milliseconds(300))

        let pairs = enumerateMIDIPairs()
        let isCreatedPair = { (pair: MIDIEndpointPair) in
            created.contains { $0.source == pair.source && $0.destination == pair.destination }
        }
        let sharedPairs = pairs.filter { $0.name == shared }
        check(sharedPairs.allSatisfy(isCreatedPair),
              "pairing never mixes endpoints of same-named virtual devices")
        eq(sharedPairs.count, 0, "pairing skips a name shared by two virtual devices")
        eq(pairs.filter { $0.name == twoDestinations }.count, 0,
           "pairing skips a name with one source and two destinations")
        eq(pairs.filter { $0.name == twoSources }.count, 0,
           "pairing skips a name with two sources and one destination")
        let soloPairs = pairs.filter { $0.name == solo }
        check(soloPairs.count == 1 && soloPairs.allSatisfy(isCreatedPair),
              "pairing still finds a uniquely named virtual device")
    }
}
