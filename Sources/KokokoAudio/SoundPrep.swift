import AVFoundation
import Foundation
import KokokoCore

public let deviceSampleRate = 46875
public let maxSampleSeconds: Double = 40

public struct PreparedSound: Sendable {
    /// Raw s16 PCM (interleaved) ready for PUT.
    public var pcm: [UInt8]
    public var channels: Int
    public var sampleRate: Int
    /// Metadata keys the device expects on the sound node.
    public var metadata: [String: JSONValue]

    public init(pcm: [UInt8], channels: Int, sampleRate: Int, metadata: [String: JSONValue]) {
        self.pcm = pcm
        self.channels = channels
        self.sampleRate = sampleRate
        self.metadata = metadata
    }
}

public enum SoundPrepError: Error {
    case tooLong(Double)
    case unreadable(String)
    case tooManyChannels(Int)
}

extension SoundPrepError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tooLong(let seconds):
            // Rounded up so a sound just over the limit never reads as exactly the limit.
            "sound is \(String(format: "%.1f", (seconds * 10).rounded(.up) / 10)) s long, the limit is \(Int(maxSampleSeconds)) s"
        case .unreadable(let detail):
            "cannot read audio: \(detail)"
        case .tooManyChannels(let count):
            "sound has \(count) channels, the device takes mono or stereo"
        }
    }
}

/// Prepare an audio file for upload: WAV already in device format is passed
/// through raw (fast path from the original tool); anything else is decoded
/// and resampled to 46875 Hz s16 via AVFoundation.
public func prepareForUpload(fileData: Data, fileName: String) throws -> PreparedSound {
    if fileName.lowercased().hasSuffix(".wav"),
       let info = try? parseWAV(Array(fileData)),
       info.bitsPerSample == 16, info.sampleRate == deviceSampleRate,
       info.channels == 1 || info.channels == 2 {
        let pcm = Array(fileData[info.dataRange])
        return PreparedSound(pcm: pcm, channels: info.channels, sampleRate: deviceSampleRate,
                             metadata: uploadMetadata(info: info, sourceRate: deviceSampleRate))
    }

    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + "-" + fileName)
    do {
        try fileData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try convertWithAVFoundation(url: tempURL)
    } catch let error as SoundPrepError {
        throw error
    } catch {
        throw SoundPrepError.unreadable(error.localizedDescription)
    }
}

private func convertWithAVFoundation(url: URL) throws -> PreparedSound {
    let source = try AVAudioFile(forReading: url)
    let sourceFormat = source.processingFormat
    let length = Double(source.length) / sourceFormat.sampleRate
    guard length <= maxSampleSeconds else { throw SoundPrepError.tooLong(length) }

    let channels = Int(sourceFormat.channelCount)
    // Refused rather than downmixed: a correct downmix depends on the channel layout,
    // and a wrong one would silently drop content.
    guard channels <= 2 else { throw SoundPrepError.tooManyChannels(channels) }
    guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                           sampleRate: Double(deviceSampleRate),
                                           channels: AVAudioChannelCount(channels),
                                           interleaved: true) else {
        throw SoundPrepError.unreadable("no device format")
    }
    let frameCapacity = AVAudioFrameCount(source.length)
    guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCapacity) else {
        throw SoundPrepError.unreadable("no audio buffer")
    }
    try source.read(into: sourceBuffer)

    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        throw SoundPrepError.unreadable("no converter")
    }
    let ratio = Double(deviceSampleRate) / sourceFormat.sampleRate
    let outCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio + 64)
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
        throw SoundPrepError.unreadable("no audio buffer")
    }
    var error: NSError?
    var consumed = false
    converter.convert(to: outBuffer, error: &error) { _, status in
        if consumed {
            status.pointee = .endOfStream
            return nil
        }
        consumed = true
        status.pointee = .haveData
        return sourceBuffer
    }
    if let error { throw SoundPrepError.unreadable(error.localizedDescription) }

    let byteCount = Int(outBuffer.frameLength) * 2 * channels
    let pcm: [UInt8]
    if let int16 = outBuffer.int16ChannelData {
        pcm = Array(UnsafeRawBufferPointer(start: int16, count: byteCount))
    } else {
        pcm = []
    }

    var metadata: [String: JSONValue] = ["channels": .int(channels), "samplerate": .int(deviceSampleRate)]
    if let info = try? parseWAV(Array(try Data(contentsOf: url))) {
        let scale = Double(deviceSampleRate) / Double(info.sampleRate)
        if let start = info.loopStart, let end = info.loopEnd {
            metadata["sound.loopstart"] = .int(Int(Double(start) * scale))
            metadata["sound.loopend"] = .int(Int(Double(end) * scale))
        }
        if let root = info.midiRootNote {
            metadata["sound.rootnote"] = .int(root)
        }
    }
    return PreparedSound(pcm: pcm, channels: channels, sampleRate: deviceSampleRate, metadata: metadata)
}

private func uploadMetadata(info: WAVInfo, sourceRate: Int) -> [String: JSONValue] {
    var metadata: [String: JSONValue] = ["channels": .int(info.channels), "samplerate": .int(info.sampleRate)]
    if let start = info.loopStart, let end = info.loopEnd {
        metadata["sound.loopstart"] = .int(Int(start))
        metadata["sound.loopend"] = .int(Int(end))
    }
    if let root = info.midiRootNote {
        metadata["sound.rootnote"] = .int(root)
    }
    return metadata
}
