import Foundation

public enum TE {
    public static let manufacturerID: [UInt8] = [0x00, 0x20, 0x76]
    public static let sysexStart: UInt8 = 0xF0
    public static let sysexEnd: UInt8 = 0xF7
    /// Byte 5 marker for regular TE protocol frames.
    public static let protocolMarker: UInt8 = 0x40
    /// Byte 5 marker for device debug-log frames.
    public static let logMarker: UInt8 = 0x33

    static let bitIsRequest: UInt8 = 0x40
    static let bitRequestIDAvailable: UInt8 = 0x20
}

public enum TECommand {
    public static let greet: UInt8 = 1
    public static let echo: UInt8 = 2
    public static let dfu: UInt8 = 3
    public static let file: UInt8 = 5
    public static let productSpecific: UInt8 = 127
}

public enum TEStatus: Equatable, Sendable {
    case ok
    case error
    case commandNotFound
    case badRequest
    case specificError(UInt8)
    case specificSuccess(UInt8)

    public init?(_ byte: UInt8) {
        switch byte {
        case 0: self = .ok
        case 1: self = .error
        case 2: self = .commandNotFound
        case 3: self = .badRequest
        case 16...63: self = .specificError(byte)
        case 64...127: self = .specificSuccess(byte)
        default: return nil
        }
    }

    public var isTerminalSuccess: Bool { self == .ok }
}

public struct TEFrame: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case request
        case response
        case deviceLog
    }

    public var kind: Kind
    public var identityCode: UInt8
    public var requestID: UInt16
    public var hasRequestID: Bool
    public var command: UInt8
    public var status: TEStatus?
    public var payload: [UInt8]

    public init(identityCode: UInt8, requestID: UInt16, command: UInt8, payload: [UInt8]) {
        self.init(kind: .request, identityCode: identityCode, requestID: requestID,
                  hasRequestID: true, command: command, status: nil, payload: payload)
    }

    public init(kind: Kind, identityCode: UInt8, requestID: UInt16, hasRequestID: Bool,
                command: UInt8, status: TEStatus?, payload: [UInt8]) {
        self.kind = kind
        self.identityCode = identityCode
        self.requestID = requestID
        self.hasRequestID = hasRequestID
        self.command = command
        self.status = status
        self.payload = payload
    }

    /// Serialized request frame. Payload is 7-bit packed.
    public var bytes: [UInt8] {
        let packed = SevenBitCoding.pack(payload)
        var out = [UInt8](repeating: 0, count: 10 + packed.count)
        out[0] = TE.sysexStart
        out[1] = TE.manufacturerID[0]
        out[2] = TE.manufacturerID[1]
        out[3] = TE.manufacturerID[2]
        out[4] = identityCode
        out[5] = TE.protocolMarker
        out[6] = TE.bitIsRequest | TE.bitRequestIDAvailable | UInt8((requestID >> 7) & 31)
        out[7] = UInt8(requestID & 127)
        out[8] = command
        out[9..<(9 + packed.count)] = packed[...]
        out[out.count - 1] = TE.sysexEnd
        return out
    }

    /// Parse a frame from the device. Returns nil for foreign or malformed frames.
    public static func parse(_ raw: [UInt8]) -> TEFrame? {
        guard raw.count >= 9,
              raw[0] == TE.sysexStart,
              raw[1] == TE.manufacturerID[0],
              raw[2] == TE.manufacturerID[1],
              raw[3] == TE.manufacturerID[2],
              raw[raw.count - 1] == TE.sysexEnd
        else { return nil }

        if raw[5] == TE.logMarker {
            let payload = SevenBitCoding.unpack(Array(raw[6..<(raw.count - 1)]))
            return TEFrame(kind: .deviceLog, identityCode: raw[4], requestID: 0,
                           hasRequestID: false, command: 0, status: nil, payload: payload)
        }

        guard raw[5] == TE.protocolMarker else { return nil }

        let isRequest = (raw[6] & TE.bitIsRequest) != 0
        var frame = TEFrame(kind: isRequest ? .request : .response,
                            identityCode: raw[4], requestID: 0,
                            hasRequestID: false, command: raw[8], status: nil, payload: [])
        var offset = 9
        if (raw[6] & TE.bitRequestIDAvailable) != 0 {
            frame.hasRequestID = true
            frame.requestID = (UInt16(raw[6] & 31) << 7) | UInt16(raw[7] & 127)
        }
        if frame.kind == .response {
            guard raw.count > offset else { return nil }
            frame.status = TEStatus(raw[offset])
            offset += 1
        }
        frame.payload = SevenBitCoding.unpack(Array(raw[offset..<(raw.count - 1)]))
        return frame
    }
}

public enum Identity {
    public static let requestBytes: [UInt8] = [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]

    public struct Reply: Equatable, Sendable {
        public var deviceID: UInt8
        public var sku: String
    }

    public static func parseReply(_ raw: [UInt8]) -> Reply? {
        guard raw.count == 17,
              raw[0] == 0xF0, raw[1] == 0x7E,
              raw[5] == TE.manufacturerID[0],
              raw[6] == TE.manufacturerID[1],
              raw[7] == TE.manufacturerID[2]
        else { return nil }
        let family = Int(raw[8]) | (Int(raw[9]) << 7)
        let model = Int(raw[10]) | (Int(raw[11]) << 7)
        let sku = String(format: "TE%03dAS%03d", family, model)
        return Reply(deviceID: raw[2], sku: sku)
    }
}

public struct GreetMetadata: Equatable, Sendable {
    public init() {}
    public var chipID = ""
    public var mode = ""
    public var osVersion = ""
    public var product = ""
    public var serial = ""
    public var sku = ""
    public var swVersion = ""
    public var baseSKU = ""

    public static func parse(_ s: String) -> GreetMetadata {
        var m = GreetMetadata()
        for pair in s.split(separator: ";") {
            let kv = pair.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]), value = String(kv[1])
            switch key {
            case "chip_id": m.chipID = value
            case "mode": m.mode = value
            case "os_version": m.osVersion = value
            case "product": m.product = value
            case "serial": m.serial = value
            case "sku": m.sku = value
            case "sw_version": m.swVersion = value
            case "base_sku": m.baseSKU = value
            default: break
            }
        }
        return m
    }
}
