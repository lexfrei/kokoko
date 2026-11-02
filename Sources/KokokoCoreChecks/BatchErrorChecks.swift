import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func batchErrorChecks() {
        check(batchFailureText("upload", failures: [], total: 3) == nil, "batch errors: none is nil")
        eq(batchFailureText("upload", failures: ["kick.wav: bad header"], total: 1),
           "upload kick.wav: bad header", "batch errors: single item reads like before")
        eq(batchFailureText("upload", failures: ["a.wav: x", "b.wav: y"], total: 5),
           "upload 2/5 failed: a.wav: x; b.wav: y", "batch errors: every failure is kept")
    }
}
