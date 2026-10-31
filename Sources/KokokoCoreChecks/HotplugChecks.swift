import Foundation
import KokokoMIDI
import VirtualEP

extension KokokoCoreChecks {
    static func hotplugChecks() async {
        let vep = VirtualEPDevice(name: "kokoko-vep-hotplug-\(getpid())")
        func listed() -> Bool { enumerateMIDIPairs().contains { $0.name == vep.name } }
        do {
            try vep.start()
            try await Task.sleep(for: .milliseconds(300))
            check(listed(), "vep: a started device is listed")
            vep.stop()
            try await Task.sleep(for: .milliseconds(300))
            check(!listed(), "vep: a stopped device is no longer listed")
            try vep.start()
            try await Task.sleep(for: .milliseconds(300))
            check(listed(), "vep: a device started again after stop is listed")
            vep.stop()
        } catch {
            check(false, "hotplug checks threw \(error)")
        }
    }
}
