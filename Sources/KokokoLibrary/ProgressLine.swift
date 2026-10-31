import Foundation

/// The footer progress text, tracked per operation. Operations can overlap,
/// and transfer callbacks report through hops that can land after their
/// operation ended, so each report names its operation and only lands while
/// that operation is live. The footer shows the newest live operation that
/// has text.
public struct ProgressLine: Sendable {
    public struct Operation: Hashable, Sendable {
        fileprivate let id: Int
    }

    private var live: [(operation: Operation, text: String?)] = []
    private var nextID = 0

    public init() {}

    public var text: String? {
        live.last(where: { $0.text != nil })?.text
    }

    public mutating func begin(_ text: String? = nil) -> Operation {
        let operation = Operation(id: nextID)
        nextID += 1
        live.append((operation, text))
        return operation
    }

    public mutating func update(_ operation: Operation, _ text: String?) {
        guard let index = live.firstIndex(where: { $0.operation == operation }) else { return }
        live[index].text = text
    }

    public mutating func end(_ operation: Operation) {
        live.removeAll { $0.operation == operation }
    }
}
