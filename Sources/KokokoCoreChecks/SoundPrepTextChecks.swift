import AVFoundation
import Foundation
import KokokoAudio

extension KokokoCoreChecks {
    static func soundPrepTextChecks() {
        // Measured: an empty file gives 'wht?', which says nothing more specific.
        let unspecified = NSError(domain: "com.apple.coreaudio.avfaudio", code: Int(kAudioFileUnspecifiedError))
        eq(readableReason(unspecified), unspecified.localizedDescription,
           "sound prep: any other audio file code keeps its own text")
        let full = CocoaError(.fileWriteOutOfSpace)
        eq(readableReason(full), full.localizedDescription, "sound prep: an error from outside the audio reader keeps its own text")

        do {
            _ = try prepareForUpload(fileData: Data("not audio".utf8), fileName: "junk-take.mp3")
            check(false, "sound prep: a file that is not audio is refused")
        } catch let error as SoundPrepError {
            let text = error.localizedDescription
            check(text.hasPrefix("cannot read audio: "), "sound prep: unreadable audio says so — got \(text)")
            check(!text.contains("junk-take"), "sound prep: the error leaves naming the file to the caller — got \(text)")
        } catch {
            check(false, "sound prep: a file that is not audio gives a sound prep error — got \(error)")
        }

        // Codes measured with AVAudioFile on macOS: text named .mp3 gives 'dta?',
        // text named .wav gives 'typ?'.
        let cases: [(String, String)] = [("junk.mp3", "cannot read audio: not a readable audio file"),
                                         ("junk.wav", "cannot read audio: not a readable audio file")]
        for (name, want) in cases {
            do {
                _ = try prepareForUpload(fileData: Data("not audio at all here".utf8), fileName: name)
                check(false, "sound prep: \(name) is refused")
            } catch {
                eq(error.localizedDescription, want, "sound prep: \(name) gets a readable reason")
            }
        }

        // The temporary copy must not depend on the name being a valid file name.
        do {
            _ = try prepareForUpload(fileData: Data("not audio at all here".utf8), fileName: "take 1/junk.mp3")
            check(false, "sound prep: a name with a slash is still refused as non-audio")
        } catch {
            eq(error.localizedDescription, "cannot read audio: not a readable audio file",
               "sound prep: a name with a slash still reaches the audio reader")
        }
    }
}
