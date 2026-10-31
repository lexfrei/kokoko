import Foundation
import KokokoLibrary
import KokokoMIDI

extension KokokoCoreChecks {
    private actor Deleted {
        var ids: [UInt16] = []
        func add(_ id: UInt16) { ids.append(id) }
    }

    private struct Refused: LocalizedError { var errorDescription: String? { "refused" } }

    static func uploadStepsChecks() async {
        // A transfer cut short after init: the named node is removed.
        let deleted = Deleted()
        do {
            _ = try await uploadSoundSteps(
                put: { throw FileServiceError.putIncomplete(fileID: 7, underlying: "timeout") },
                setMetadata: { _ in }, delete: { await deleted.add($0) })
            check(false, "upload steps: a cut-short put fails")
        } catch let error as UploadSoundError {
            check(await deleted.ids == [7], "upload steps: the node a cut-short put names is deleted")
            let text = error.localizedDescription
            check(text.contains("007") && text.contains("removed"),
                  "upload steps: a removed partial sound is named — got \(text)")
        } catch {
            check(false, "upload steps: a cut-short put reports an upload error — got \(error)")
        }

        // The removal fails too.
        do {
            _ = try await uploadSoundSteps(
                put: { throw FileServiceError.putIncomplete(fileID: 7, underlying: "timeout") },
                setMetadata: { _ in }, delete: { _ in throw Refused() })
            check(false, "upload steps: a cut-short put fails when its removal fails")
        } catch let error as UploadSoundError {
            let text = error.localizedDescription
            check(text.contains("007") && text.contains("may remain"),
                  "upload steps: a partial sound that could not be removed is named — got \(text)")
        } catch {
            check(false, "upload steps: a failed removal reports an upload error — got \(error)")
        }

        // Init itself refused: no node id, nothing is deleted, the error is passed on.
        let untouched = Deleted()
        do {
            _ = try await uploadSoundSteps(put: { throw Refused() }, setMetadata: { _ in },
                                           delete: { await untouched.add($0) })
            check(false, "upload steps: a refused init fails")
        } catch is Refused {
            check(await untouched.ids.isEmpty, "upload steps: a refused init deletes nothing")
        } catch {
            check(false, "upload steps: a refused init passes its error on — got \(error)")
        }

        // Metadata refused and the removal fails.
        do {
            _ = try await uploadSoundSteps(put: { 9 }, setMetadata: { _ in throw Refused() },
                                           delete: { _ in throw Refused() })
            check(false, "upload steps: refused metadata fails")
        } catch let error as UploadSoundError {
            let text = error.localizedDescription
            check(text.contains("009") && text.contains("still holds"),
                  "upload steps: a sound left without metadata is named — got \(text)")
        } catch {
            check(false, "upload steps: refused metadata reports an upload error — got \(error)")
        }
    }
}
