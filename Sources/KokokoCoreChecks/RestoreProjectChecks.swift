import Foundation
import KokokoCore
import KokokoLibrary
import KokokoMIDI
import VirtualEP

extension KokokoCoreChecks {
    static func restoreProjectChecks() async {
        let vep = VirtualEPDevice(name: "kokoko-vep-restore-projects-\(getpid())")
        do {
            try vep.start()
            try await Task.sleep(for: .milliseconds(300))
            guard let pair = enumerateMIDIPairs().first(where: { $0.name == vep.name }) else {
                check(false, "restore projects: device enumerated")
                return
            }
            let wire = try CoreMIDIWire(pair: pair)
            let identity = try await identifyDevice(on: wire)
            let session = SysExSession(wire: wire, identityCode: identity.deviceID)
            let files = DeviceFileService(session: session)
            try await files.initialize()
            let library = DeviceLibrary(files: files)
            let projectsRoot = try await library.resolve("/projects")
            let slot01 = try await files.put(parentID: projectsRoot, name: "01", data: [0])

            let archive = [UInt8](repeating: 7, count: 300)
            let skipped = try await library.restore(DeviceBackup(
                deviceSKU: "", osVersion: "", createdAt: Date(), sounds: [], projectMetadata: [:],
                projectArchives: ["01": archive, "07": archive, "09": archive]))
            eq(skipped, ["07", "09"], "restore projects: archives without a slot on the device are reported")
            check(try await files.get(fileID: slot01).data == archive,
                  "restore projects: an archive with a slot is still written")
            eq(try await files.list(nodeID: projectsRoot).map(\.name), ["01"],
               "restore projects: no slot is created for a skipped archive")
            eq(try await library.restore(DeviceBackup(
                deviceSKU: "", osVersion: "", createdAt: Date(), sounds: [], projectMetadata: [:],
                projectArchives: ["01": archive])), [],
               "restore projects: nothing is reported when every archive has a slot")
            eq(RestoreSkip.message(projects: ["07", "09"]), "P07, P09 skipped: no such project slot on the device",
               "restore projects: the message names every skipped project")
            eq(RestoreSkip.message(projects: []), nil, "restore projects: no message when nothing was skipped")
        } catch {
            check(false, "restore project checks threw \(error)")
        }
    }
}
