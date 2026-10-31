import Foundation

/// One error line for a batch, keeping every failed item instead of only the
/// last one. Nil when nothing failed.
public func batchFailureText(_ operation: String, failures: [String], total: Int) -> String? {
    if failures.isEmpty { return nil }
    if total == 1 { return "\(operation) \(failures[0])" }
    return "\(operation) \(failures.count)/\(total) failed: " + failures.joined(separator: "; ")
}

/// Adds `text` to an error line that may already hold another failure, such
/// as a reload that failed after the batch.
public func appendingError(_ existing: String?, _ text: String) -> String {
    [existing, text].compactMap { $0 }.joined(separator: "; ")
}
