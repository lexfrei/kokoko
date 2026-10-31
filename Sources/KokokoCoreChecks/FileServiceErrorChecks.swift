import Foundation
import KokokoMIDI

extension KokokoCoreChecks {
    static func fileServiceErrorChecks() {
        let missing = FileServiceError.pathNotFound("/sounds/x").localizedDescription
        check(missing.contains("/sounds/x"), "path-not-found text names the path — got \(missing)")
        let short = FileServiceError.truncated(fileID: 7, expected: 100, got: 64).localizedDescription
        check(short.contains("64") && short.contains("100"), "truncated text names both sizes — got \(short)")
        eq(FileServiceError.unserializableMetadata.localizedDescription,
           "metadata has a value JSON cannot carry", "unserializable metadata text")
    }
}
