import Foundation
import KokokoCore

public enum SettingsError: Error {
    case invalidJSON(String)
}

extension SettingsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let text): "device sent invalid settings JSON: \(text.prefix(200))"
        }
    }
}

/// Device settings over command 6: paged JSON dump and per-id writes.
/// Read path only until verified against real hardware.
public actor SettingsService {
    private let session: SysExSession
    private var pageSize: UInt16 = 512

    public init(session: SysExSession) {
        self.session = session
    }

    @discardableResult
    public func initialize() async throws -> Bool {
        let payload: [UInt8] = [1, UInt8(pageSize >> 8), UInt8(pageSize & 0xFF)]
        _ = try await session.call(command: 6, payload: payload)
        return true
    }

    /// Full settings JSON, assembled from pages.
    public func getAll() async throws -> [String: JSONValue] {
        var text = ""
        var page: UInt16 = 0
        while true {
            let reply = try await session.call(command: 6,
                                               payload: [2, UInt8(page >> 8), UInt8(page & 0xFF)])
            let data = reply.payload
            // Text starts at byte 2; ends at a zero byte; empty text ends paging.
            guard data.count > 2 else { break }
            var end = 2
            while end < data.count && data[end] != 0 { end += 1 }
            let fragment = String(decoding: data[2..<end], as: UTF8.self)
            if fragment.isEmpty { break }
            text += fragment
            page += 1
        }
        guard let raw = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw),
              let dict = object as? [String: Any] else {
            throw SettingsError.invalidJSON(text)
        }
        return dict.compactMapValues { JSONValue(any: $0) }
    }

    /// Set one setting by numeric id. Enable only after the schema is verified.
    public func set(id: UInt16, value: JSONValue) async throws {
        let json = try JSONSerialization.data(withJSONObject: value.anyValue)
        var payload: [UInt8] = [3, UInt8(id >> 8), UInt8(id & 0xFF)]
        payload.append(contentsOf: json)
        payload.append(0)
        _ = try await session.call(command: 6, payload: payload)
    }
}
