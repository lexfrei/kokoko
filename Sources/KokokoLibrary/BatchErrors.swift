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

/// The error line after `text` arrives. `deviceIsCurrent` is false when the
/// device `text` is about has left since the operation started; the line then
/// stays as it is, so the disconnect reason is not followed by errors about a
/// device that is gone. A text already at the end of the line is not repeated,
/// so a failure reported again on every visit does not grow the line.
public func nextError(_ existing: String?, adding text: String, deviceIsCurrent: Bool) -> String? {
    guard deviceIsCurrent else { return existing }
    if let existing, existing == text || existing.hasSuffix("; " + text) { return existing }
    return appendingError(existing, text)
}

/// The error line the app shows. The first error an operation reports
/// replaces the line, so an earlier operation's error does not linger next
/// to it; the operation's later errors, notes, and anything reported while
/// no operation runs join the line through `nextError`. A successful
/// operation leaves the line as it was.
public struct ErrorLine: Equatable, Sendable {
    public private(set) var text: String?
    private var operationHasWritten = true

    public init(text: String? = nil) {
        self.text = text
    }

    public mutating func start() {
        operationHasWritten = false
    }

    public mutating func finish() {
        operationHasWritten = true
    }

    /// `deviceIsCurrent` as in `nextError`: false drops the message, and a
    /// dropped message is not the operation's first.
    public mutating func report(_ message: String, deviceIsCurrent: Bool) {
        guard deviceIsCurrent else { return }
        text = nextError(operationHasWritten ? text : nil, adding: message, deviceIsCurrent: true)
        operationHasWritten = true
    }

    /// A message that belongs to no operation, such as a refusal: it joins the
    /// line and leaves the running operation's first error to replace it.
    public mutating func note(_ message: String) {
        text = nextError(text, adding: message, deviceIsCurrent: true)
    }

    public mutating func clear() {
        text = nil
    }
}
