import Foundation
import KokokoCore

/// One logical MIDI device connection: raw bytes out, complete SysEx messages in.
public protocol MIDIWire: Sendable {
    func send(_ bytes: [UInt8]) async throws
    /// Install the handler for complete inbound messages (SysEx reassembled).
    func setMessageHandler(_ handler: (@Sendable ([UInt8]) -> Void)?)
}

public enum WireError: LocalizedError {
    case noDevice
    case timeout

    public var errorDescription: String? {
        switch self {
        case .noDevice: "no device is connected"
        case .timeout: "device did not answer in time"
        }
    }
}
