#if os(macOS) && DEBUG
import AppKit
import KokokoLibrary
import UniformTypeIdentifiers

@MainActor
enum RowDragProviderChecks {
    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "ok  " : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        let token = RowDragToken(id: 42)
        let bytes = Data(token.payload.utf8)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let delegate = PromiseDelegate()
        var provider: RowPromise? = RowPromise(fileType: UTType.wav.identifier, delegate: delegate)
        provider?.token = token
        weak let releasedProvider = provider
        check(pasteboard.writeObjects([provider!]), "drag provider: actual writer reaches a unique pasteboard")
        guard let item = pasteboard.pasteboardItems?.first else {
            print("FAIL drag provider: no pasteboard item")
            return 1
        }
        print("drag provider: types=\(item.types.map(\.rawValue))")
        let requested = NSPasteboard.PasteboardType(rowMoveTextType.identifier)
        print("drag provider: consumer=\(requested.rawValue)")
        for type in [
            NSPasteboard.PasteboardType.string,
            NSPasteboard.PasteboardType(UTType.plainText.identifier),
            NSPasteboard.PasteboardType(UTType.soundRowMove.identifier)
        ] {
            let data = item.data(forType: type)
            print("drag provider: type=\(type.rawValue) bytes=\(data?.count.description ?? "nil") matches=\(data == bytes)")
        }
        check(item.data(forType: .string) == bytes, "drag provider: exact UTF-8 text carries the token")
        check(item.data(forType: requested) == bytes, "drag provider: consumer's exact type reads the native token")
        check(
            item.data(forType: NSPasteboard.PasteboardType(UTType.soundRowMove.identifier)) == Data(),
            "drag provider: private upload-exclusion marker is empty data, not a failed read")
        check(delegate.writes == 0, "drag provider: local reads do not fulfill the WAV promise")
        provider = nil
        print("drag provider: writer retained after local release=\(releasedProvider != nil)")
        check(item.data(forType: requested) == bytes, "drag provider: consumer token survives local writer release")
        check(delegate.writes == 0, "drag provider: writer release does not fulfill the WAV promise")
        check(NSApplication.shared.windows.isEmpty, "drag provider: no windows created")
        print(failures == 0 ? "drag provider: all checks passed" : "drag provider: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    private final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
        var writes = 0

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            "sound.wav"
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) {
            writes += 1
            completionHandler(CocoaError(.featureUnsupported))
        }
    }
}
#endif
