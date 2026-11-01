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
        // The app names the file itself; the read error's own text names it again.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-take-\(UUID().uuidString).wav")
        do {
            _ = try Data(contentsOf: missing)
            check(false, "upload: a missing file cannot be read")
        } catch {
            let text = readFailureText(error)
            check(!text.contains("missing-take") && !text.isEmpty,
                  "upload: a failed read is described without the file name — got \(text)")
        }
        eq(readFailureText(Refused()), "refused", "upload: an error without a failure reason keeps its full text")

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

        // Init answered with a refusal: the refusal is passed on as it is.
        let refusedByDevice = Deleted()
        do {
            _ = try await uploadSoundSteps(put: { throw SessionError.deviceError(.badRequest, message: nil) },
                                           setMetadata: { _ in }, delete: { await refusedByDevice.add($0) })
            check(false, "upload steps: an init the device refuses fails")
        } catch SessionError.deviceError {
            check(await refusedByDevice.ids.isEmpty, "upload steps: an init the device refuses deletes nothing")
        } catch {
            check(false, "upload steps: an init the device refuses passes the refusal on — got \(error)")
        }

        // Init sent but its reply lost or unreadable: a node may exist under an
        // id nobody knows, so nothing is deleted and the user is told.
        let lostReplies: [(String, any Error)] = [
            ("lost", SessionError.timeout(command: 2, requestID: 1)),
            ("lost on the wire", WireError.timeout),
            ("unreadable", FileServiceError.missingResponse),
        ]
        for (label, failure) in lostReplies {
            let unknown = Deleted()
            do {
                _ = try await uploadSoundSteps(put: { throw failure }, setMetadata: { _ in },
                                               delete: { await unknown.add($0) })
                check(false, "upload steps: an init whose reply is \(label) fails")
            } catch let error as UploadSoundError {
                check(await unknown.ids.isEmpty, "upload steps: an init whose reply is \(label) deletes nothing")
                eq(error.localizedDescription,
                   "upload failed (\(failure.localizedDescription)), a partial sound may remain on the device",
                   "upload steps: an init whose reply is \(label) says a partial sound may remain")
            } catch {
                check(false, "upload steps: an init whose reply is \(label) reports an upload error — got \(error)")
            }
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
