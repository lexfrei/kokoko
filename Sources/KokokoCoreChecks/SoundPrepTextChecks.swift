import Foundation
import KokokoAudio

extension KokokoCoreChecks {
    static func soundPrepTextChecks() {
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
    }
}
