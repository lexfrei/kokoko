import Foundation

/// One error line for a batch, keeping every failed item instead of only the
/// last one. Nil when nothing failed.
public func batchFailureText(_ operation: String, failures: [String], total: Int) -> String? {
    if failures.isEmpty { return nil }
    if total == 1 { return "\(operation) \(failures[0])" }
    return "\(operation) \(failures.count)/\(total) failed: " + failures.joined(separator: "; ")
}

/// What a message on the error line is about, for taking it back once that
/// works again. Matching on the kind, not on the text, means no other
/// message is taken back because its text happens to start the same way.
public enum ErrorKind: Sendable {
    case projects, settings, deviceWatch
}

/// The error line the app shows, one message per entry. The first error an
/// operation reports replaces the line's messages, so an earlier operation's
/// error does not linger next to it, while pinned messages stay; the
/// operation's later errors, notes, and anything reported while no operation
/// runs join the line. A successful operation leaves the line as it was.
public struct ErrorLine: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var text: String
        var kind: ErrorKind?
    }

    private var pinned: [Entry] = []
    private var messages: [Entry]
    private var operationHasWritten = true

    public init(_ messages: [String] = []) {
        self.messages = messages.map { Entry(text: $0) }
    }

    public var text: String? {
        let all = pinned + messages
        return all.isEmpty ? nil : all.map(\.text).joined(separator: "; ")
    }

    public mutating func start() {
        operationHasWritten = false
    }

    public mutating func finish() {
        operationHasWritten = true
    }

    /// `deviceIsCurrent` is false when the device the message is about has
    /// left since the operation started: the message is dropped, so the
    /// disconnect reason is not followed by errors about a device that is
    /// gone, and a dropped message is not the operation's first.
    public mutating func report(_ message: String, kind: ErrorKind? = nil, deviceIsCurrent: Bool) {
        guard deviceIsCurrent else { return }
        if !operationHasWritten { messages = [] }
        add(Entry(text: message, kind: kind))
        operationHasWritten = true
    }

    /// A message that belongs to no operation, such as a refusal: it joins the
    /// line and leaves the running operation's first error to replace it.
    public mutating func note(_ message: String) {
        add(Entry(text: message))
    }

    /// A message that stays true until `unpin` takes its kind back, such as
    /// hotplug not working: it leads the line, and no clear, withdrawal or
    /// later error removes it.
    public mutating func pin(_ message: String, kind: ErrorKind) {
        if !pinned.contains(where: { $0.text == message }) { pinned.append(Entry(text: message, kind: kind)) }
    }

    public mutating func unpin(_ kind: ErrorKind) {
        pinned.removeAll { $0.kind == kind }
    }

    /// Removes the messages of one kind, for when what failed has since worked.
    public mutating func withdraw(_ kind: ErrorKind) {
        messages.removeAll { $0.kind == kind }
    }

    public mutating func clear() {
        messages = []
    }

    /// A message already pinned or ending the line is not repeated, so a
    /// failure reported again on every visit does not grow the line.
    private mutating func add(_ entry: Entry) {
        if messages.last?.text != entry.text, !pinned.contains(where: { $0.text == entry.text }) {
            messages.append(entry)
        }
    }
}
