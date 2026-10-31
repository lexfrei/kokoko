import Foundation
import KokokoAudio
import KokokoMIDI

extension KokokoCoreChecks {
    static func errorDescriptionChecks() {
        eq(CoreMIDIError.osStatus("MIDIClientCreate", -10830).localizedDescription,
           "MIDIClientCreate failed with OSStatus -10830", "error text: CoreMIDI call")

        eq(SessionError.timeout(command: 6, requestID: 12).localizedDescription,
           "device did not answer command 6 in time", "error text: session timeout")
        eq(SessionError.deviceError(.commandNotFound, message: nil).localizedDescription,
           "device answered command not found", "error text: device status")
        eq(SessionError.deviceError(.badRequest, message: "").localizedDescription,
           "device answered bad request", "error text: device status with an empty message")
        eq(SessionError.deviceError(.specificError(16), message: "no such file").localizedDescription,
           "device answered command-specific error 16: no such file", "error text: device status with message")
        eq(SessionError.deviceError(.error, message: nil).localizedDescription,
           "device answered error", "error text: generic error names no status number")
        eq(SessionError.notAGreetReply.localizedDescription,
           "device sent an unreadable greet reply", "error text: greet reply")

        eq(SettingsError.invalidJSON("{x").localizedDescription,
           "device sent invalid settings JSON: {x", "error text: settings JSON")
        eq(SettingsError.invalidJSON(String(repeating: "x", count: 300)).localizedDescription,
           "device sent invalid settings JSON: " + String(repeating: "x", count: 200),
           "error text: settings JSON is cut to 200 characters")

        eq(SoundPrepError.tooLong(41.25).localizedDescription,
           "sound is 41.3 s long, the limit is 40 s", "error text: sound too long")
        eq(SoundPrepError.tooLong(40.02).localizedDescription,
           "sound is 40.1 s long, the limit is 40 s", "error text: a length just over the limit rounds up")
        eq(SoundPrepError.unreadable("kick.wav").localizedDescription,
           "cannot read audio: kick.wav", "error text: unreadable audio")

        eq(WAVError.notRIFF.localizedDescription, "not a RIFF file", "error text: WAV not RIFF")
        eq(WAVError.notWAVE.localizedDescription, "RIFF file is not WAVE", "error text: WAV not WAVE")
        eq(WAVError.missingFormat.localizedDescription, "WAV file has no usable format chunk",
           "error text: WAV format chunk")
        eq(WAVError.missingData.localizedDescription, "WAV file has no data chunk", "error text: WAV data chunk")
    }
}
