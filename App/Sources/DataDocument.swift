import SwiftUI
import UniformTypeIdentifiers

/// File exporter document for WAV data.
struct DataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav, UTType(filenameExtension: "tar") ?? .data, .data] }
    var data: Data
    var contentType: UTType = .wav

    init(data: Data, contentType: UTType = .wav) {
        self.data = data
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
