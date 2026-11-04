#if os(macOS) && DEBUG
import AppKit
import UniformTypeIdentifiers
import KokokoLibrary

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
        print("drag provider: string=\(NSPasteboard.PasteboardType.string.rawValue)")
        for type in [
            NSPasteboard.PasteboardType.string,
            NSPasteboard.PasteboardType(UTType.plainText.identifier),
            NSPasteboard.PasteboardType(UTType.soundRowMove.identifier)
        ] {
            let data = item.data(forType: type)
            print("drag provider: type=\(type.rawValue) bytes=\(data?.count.description ?? "nil") matches=\(data == bytes)")
        }
        let moveType = NSPasteboard.PasteboardType(UTType.soundRowMove.identifier)
        check(item.data(forType: .string) == nil, "drag provider: local identity is not exported as arbitrary text")
        check(item.data(forType: moveType) == bytes, "drag provider: exact custom data carries the token")
        check(delegate.writes == 0, "drag provider: local reads do not fulfill the WAV promise")
        provider = nil
        print("drag provider: writer retained after local release=\(releasedProvider != nil)")
        check(item.data(forType: moveType) == bytes, "drag provider: materialized token survives local writer release")
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
