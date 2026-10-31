import Foundation

/// Collects files handed over by drag-and-drop item providers.
///
/// Provider callbacks run concurrently on arbitrary queues, and the URL they
/// receive may be a temporary copy that is deleted as soon as the callback
/// returns. `stage(_:at:)` copies the file synchronously from inside the
/// callback into a private directory, so the result outlives the provider.
public final class DropStaging: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var slots: [URL?]
    private var errors: [String] = []

    /// `count` is the number of providers; each one stages into its own index
    /// so the drop order survives concurrent completion.
    public init(count: Int, root: URL = FileManager.default.temporaryDirectory) throws {
        directory = root.appendingPathComponent("kokoko-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        slots = Array(repeating: nil, count: count)
    }

    /// Safe to call from any thread. A per-index subdirectory keeps the
    /// original file name (upload derives the device name from it) without
    /// collisions between same-named files from different folders.
    public func stage(_ source: URL, at index: Int) {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let dir = directory.appendingPathComponent(String(index))
        let target = dir.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
            lock.withLock { slots[index] = target }
        } catch {
            let reason = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)
                .map { $0.localizedFailureReason ?? $0.localizedDescription } ?? error.localizedDescription
            lock.withLock { errors.append("\(source.lastPathComponent): \(reason)") }
        }
    }

    /// Records an item that never reached `stage(_:at:)`, under the name
    /// the user will recognise in the error line.
    public func fail(name: String, reason: String) {
        lock.withLock { errors.append("\(name): \(reason)") }
    }

    /// Staged copies in drop order.
    public var urls: [URL] {
        lock.withLock { slots.compactMap { $0 } }
    }

    public var failures: [String] {
        lock.withLock { errors }
    }

    public func discard() {
        try? FileManager.default.removeItem(at: directory)
    }
}
