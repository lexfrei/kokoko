import Foundation
import KokokoCore
import KokokoLibrary
import KokokoMIDI
import VirtualEP

extension KokokoCoreChecks {
    static func metadataEditChecks() async {
        metadataFormChecks()
        await metadataSaveStepChecks()
        await metadataVirtualDeviceChecks()
    }

    private static func metadataFormChecks() {
        eq(MetadataEditForm.keys, ["sound.rootnote", "sound.bpm", "sound.pitch", "sound.pan",
                                   "sound.amplitude", "envelope.attack", "envelope.release",
                                   "sound.loopstart", "sound.loopend", "sound.playmode", "time.mode"],
           "metadata form: the documented sound keys, nothing set by the tool")

        let ranges: [(String, Int, Int)] = [
            ("sound.rootnote", 1, 127), ("sound.bpm", 60, 180), ("sound.pitch", -12, 12),
            ("sound.pan", -16, 16), ("sound.amplitude", 0, 200),
            ("envelope.attack", 0, 255), ("envelope.release", 0, 255),
        ]
        for (key, low, high) in ranges {
            var form = MetadataEditForm(metadata: [:])
            form.text[key] = "\(low)"
            check(form.error(for: key) == nil, "metadata form: \(key) accepts \(low)")
            form.text[key] = "\(high)"
            check(form.error(for: key) == nil, "metadata form: \(key) accepts \(high)")
            form.text[key] = "\(low - 1)"
            eq(form.error(for: key), "\(low)...\(high)", "metadata form: \(key) refuses \(low - 1)")
            check(form.changes == nil, "metadata form: an out-of-range \(key) blocks saving")
            form.text[key] = "\(high + 1)"
            eq(form.error(for: key), "\(low)...\(high)", "metadata form: \(key) refuses \(high + 1)")
        }
        for key in ["sound.loopstart", "sound.loopend"] {
            var form = MetadataEditForm(metadata: [:])
            form.text[key] = "0"
            check(form.error(for: key) == nil, "metadata form: \(key) accepts 0")
            form.text[key] = "-1"
            eq(form.error(for: key), "0 or more", "metadata form: \(key) refuses -1")
        }

        var form = MetadataEditForm(metadata: [:])
        form.text["sound.bpm"] = "120.5"
        eq(form.error(for: "sound.bpm"), "a whole number", "metadata form: a fraction is refused")
        form.text["sound.bpm"] = "fast"
        eq(form.error(for: "sound.bpm"), "a whole number", "metadata form: text in a number field is refused")
        form.text["sound.bpm"] = " 90 "
        eq(form.changes, ["sound.bpm": .int(90)], "metadata form: surrounding spaces are ignored")

        let original: [String: JSONValue] = [
            "name": .string("kick"), "channels": .int(1), "sound.bpm": .int(120),
            "sound.pitch": .double(1.5), "sound.playmode": .string("oneshot"),
        ]
        form = MetadataEditForm(metadata: original)
        eq(form.text["sound.bpm"], "120", "metadata form: an integer is shown as is")
        eq(form.text["sound.pitch"], "1.5", "metadata form: a stored fraction is shown as is")
        eq(form.text["sound.rootnote"], "", "metadata form: a key the sound lacks starts empty")
        eq(form.changes, [:], "metadata form: nothing edited sends nothing")
        check(form.error(for: "sound.pitch") == nil, "metadata form: an untouched stored fraction is not an error")

        form.text["sound.bpm"] = "121"
        form.text["sound.rootnote"] = "60"
        eq(form.changes, ["sound.bpm": .int(121), "sound.rootnote": .int(60)],
           "metadata form: only edited and newly filled keys are sent")

        form = MetadataEditForm(metadata: original)
        form.text["sound.bpm"] = ""
        eq(form.error(for: "sound.bpm"), "a value is required", "metadata form: a stored number cannot be cleared")
        form = MetadataEditForm(metadata: original)
        form.text["sound.playmode"] = "  "
        eq(form.error(for: "sound.playmode"), "a value is required", "metadata form: a blank mode is refused")
        form.text["sound.playmode"] = "loop"
        eq(form.changes, ["sound.playmode": .string("loop")], "metadata form: a mode is sent as text")
        form = MetadataEditForm(metadata: [:])
        form.text["time.mode"] = ""
        eq(form.changes, [:], "metadata form: an empty field for a missing key sends nothing")
    }

    private static func metadataSaveStepChecks() async {
        let stored: [String: JSONValue] = ["sound.bpm": .int(121)]
        let saved = await saveMetadataSteps(["sound.bpm": .int(121)],
                                            set: { _ in }, get: { stored })
        check(saved.message == nil, "metadata save: a confirmed write reports no error")
        eq(saved.current, stored, "metadata save: the values are read back after a write")

        let refused = await saveMetadataSteps(["sound.bpm": .int(121)], set: { _ in
            throw SessionError.deviceError(.specificError(16), message: nil)
        }, get: { ["sound.bpm": .int(120)] })
        eq(refused.message, "the device refused the metadata write (device answered command-specific error 16)",
           "metadata save: a refusal says so")
        eq(refused.current, ["sound.bpm": .int(120)], "metadata save: a refusal shows what the device holds")

        let lost = await saveMetadataSteps(["sound.bpm": .int(121)], set: { _ in
            throw SessionError.timeout(command: 7, requestID: 1)
        }, get: { stored })
        eq(lost.message, "the device did not confirm the metadata write (device did not answer command 7 in time)",
           "metadata save: a lost reply is not reported as refused")
        eq(lost.current, stored, "metadata save: a lost reply shows what the device holds")

        let unreadable = await saveMetadataSteps(["sound.bpm": .int(121)], set: { _ in
            throw SessionError.timeout(command: 7, requestID: 1)
        }, get: { throw SessionError.timeout(command: 7, requestID: 2) })
        check(unreadable.current == nil, "metadata save: a failed read back shows nothing as current")
        eq(unreadable.message,
           "the device did not confirm the metadata write (device did not answer command 7 in time); "
               + "reading it back failed (device did not answer command 7 in time)",
           "metadata save: a failed read back is reported too")
    }

    private static func metadataVirtualDeviceChecks() async {
        let vep = VirtualEPDevice(name: "kokoko-vep-metadata-\(getpid())")
        do {
            try vep.start()
            defer { vep.stop() }
            try await Task.sleep(for: .milliseconds(300))
            guard let pair = enumerateMIDIPairs().first(where: { $0.name == vep.name }) else {
                check(false, "metadata vep: device enumerated")
                return
            }
            let wire = try CoreMIDIWire(pair: pair)
            let identity = try await identifyDevice(on: wire)
            let files = DeviceFileService(session: SysExSession(wire: wire, identityCode: identity.deviceID))
            try await files.initialize()
            let soundsRoot = try await DeviceLibrary(files: files).resolve("/sounds")
            guard let kick = try await files.list(nodeID: soundsRoot).first(where: { $0.name == "kick" })?.id else {
                check(false, "metadata vep: seeded sound listed")
                return
            }

            var form = MetadataEditForm(metadata: try await files.getMetadata(fileID: kick))
            form.text["sound.bpm"] = "133"
            form.text["sound.playmode"] = "loop"
            let saved = await saveMetadata(files: files, fileID: kick, changes: form.changes ?? [:])
            check(saved.message == nil, "metadata vep: an edit is written")
            eq(saved.current?["sound.bpm"], .int(133), "metadata vep: the edited bpm reads back")
            eq(saved.current?["sound.playmode"], .string("loop"), "metadata vep: the edited mode reads back")
            eq(saved.current?["channels"], .int(1), "metadata vep: keys not edited are kept")

            vep.refuseMetadataSet = true
            let refused = await saveMetadata(files: files, fileID: kick, changes: ["sound.bpm": .int(90)])
            vep.refuseMetadataSet = false
            check(refused.message?.hasPrefix("the device refused") == true, "metadata vep: a refused edit says so")
            eq(refused.current?["sound.bpm"], .int(133), "metadata vep: a refused edit leaves the stored value")
        } catch {
            check(false, "metadata vep: \(error.localizedDescription)")
        }
    }
}
