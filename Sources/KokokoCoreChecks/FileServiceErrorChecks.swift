import Foundation
import KokokoLibrary
import KokokoMIDI

extension KokokoCoreChecks {
    static func fileServiceErrorChecks() {
        let missing = FileServiceError.pathNotFound("/sounds/x").localizedDescription
        check(missing.contains("/sounds/x"), "path-not-found text names the path — got \(missing)")
        let short = FileServiceError.truncated(fileID: 7, expected: 100, got: 64).localizedDescription
        check(short.contains("64") && short.contains("100"), "truncated text names both sizes — got \(short)")
        eq(FileServiceError.unserializableMetadata.localizedDescription,
           "metadata has a value JSON cannot carry", "unserializable metadata text")

        func truncation(_ count: Int, announced: Int) -> (expected: Int, got: Int)? {
            do {
                _ = try wholeData(Array(repeating: 0, count: count), announced: announced, fileID: 7)
                return nil
            } catch FileServiceError.truncated(7, let expected, let got) {
                return (expected, got)
            } catch {
                return nil
            }
        }
        check((try? wholeData([1, 2, 3], announced: 3, fileID: 7)) == [1, 2, 3], "whole read: data of the announced size is kept")
        check(truncation(64, announced: 100).map { $0 == (100, 64) } == true, "whole read: a short read is truncated")
        check(truncation(0, announced: 100).map { $0 == (100, 0) } == true, "whole read: an empty read of a non-empty file is truncated")
        check(truncation(120, announced: 100) != nil, "whole read: more bytes than announced is not taken as whole")
    }
}
