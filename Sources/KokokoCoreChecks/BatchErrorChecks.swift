import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func batchErrorChecks() {
        check(batchFailureText("upload", failures: [], total: 3) == nil, "batch errors: none is nil")
        eq(batchFailureText("upload", failures: ["kick.wav: bad header"], total: 1),
           "upload kick.wav: bad header", "batch errors: single item reads like before")
        eq(batchFailureText("upload", failures: ["a.wav: x", "b.wav: y"], total: 5),
           "upload 2/5 failed: a.wav: x; b.wav: y", "batch errors: every failure is kept")
        eq(appendingError(nil, "upload a.wav: x"), "upload a.wav: x", "batch errors: nothing to keep")
        eq(appendingError("list failed: timeout", "upload a.wav: x"), "list failed: timeout; upload a.wav: x",
           "batch errors: a reload failure stays next to the batch failure")

        eq(nextError(nil, adding: "bin: unreadable", deviceIsCurrent: true), "bin: unreadable",
           "next error: the first error is the line")
        eq(nextError("restore kick: timeout", adding: "bin: unreadable", deviceIsCurrent: true),
           "restore kick: timeout; bin: unreadable", "next error: a new error goes after the ones already shown")
        eq(nextError("EP-133 disconnected", adding: "delete: timeout", deviceIsCurrent: false),
           "EP-133 disconnected", "next error: an error about a device that left is dropped")
        eq(nextError(nil, adding: "delete: timeout", deviceIsCurrent: false), nil,
           "next error: a dropped error leaves an empty line empty")
        eq(nextError("x; bin: unreadable", adding: "bin: unreadable", deviceIsCurrent: true), "x; bin: unreadable",
           "next error: the same error reported again is not repeated")
        eq(nextError("bin: unreadable", adding: "bin: unreadable", deviceIsCurrent: true), "bin: unreadable",
           "next error: the same error alone is not repeated")
        eq(nextError("bin: unreadable; x", adding: "bin: unreadable", deviceIsCurrent: true),
           "bin: unreadable; x; bin: unreadable", "next error: an error seen earlier is added again after a newer one")
        eq(nextError("xbin: unreadable", adding: "bin: unreadable", deviceIsCurrent: true),
           "xbin: unreadable; bin: unreadable", "next error: only a whole error at the end counts as a repeat")
    }
}
