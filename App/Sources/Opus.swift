import AVFoundation

enum Audio {
    static let sampleRate = 48_000.0
    static let frameSize: AVAudioFrameCount = 960   // 20 ms

    static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    static let opusFormat: AVAudioFormat = {
        var d = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                            mBytesPerPacket: 0, mFramesPerPacket: UInt32(frameSize), mBytesPerFrame: 0,
                                            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &d)!
    }()

    static func peak(_ s: UnsafeBufferPointer<Float>) -> Float {
        var p: Float = 0
        for v in s { p = max(p, abs(v)) }
        return p
    }

    /// 0…1 for a level meter, from a linear peak (‑60 dBFS → 0).
    static func meter(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        return max(0, min(1, (20 * log10(peak) + 60) / 60))
    }
}

final class OpusEncoder {
    private let converter: AVAudioConverter

    init?(bitrate: Int = 32_000) {
        guard let c = AVAudioConverter(from: Audio.pcmFormat, to: Audio.opusFormat) else { return nil }
        c.bitRate = bitrate
        converter = c
    }

    /// Encodes one 20 ms frame (960 samples).
    func encode(_ samples: UnsafeBufferPointer<Float>) -> Data? {
        let frame = AVAudioPCMBuffer(pcmFormat: Audio.pcmFormat, frameCapacity: Audio.frameSize)!
        frame.frameLength = Audio.frameSize
        frame.floatChannelData![0].update(from: samples.baseAddress!, count: Int(Audio.frameSize))
        let out = AVAudioCompressedBuffer(format: Audio.opusFormat, packetCapacity: 1, maximumPacketSize: 1500)
        var fed = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return frame
        }
        guard error == nil, out.packetCount > 0, out.byteLength > 0 else { return nil }
        return Data(bytes: out.data, count: Int(out.byteLength))
    }
}

final class OpusDecoder {
    private let converter: AVAudioConverter

    init?() {
        guard let c = AVAudioConverter(from: Audio.opusFormat, to: Audio.pcmFormat) else { return nil }
        converter = c
    }

    /// Synthesizes 20 ms to cover a lost frame (Opus packet-loss concealment).
    func conceal() -> [Float] { decode(Data()) }

    func decode(_ packet: Data) -> [Float] {
        let comp = AVAudioCompressedBuffer(format: Audio.opusFormat, packetCapacity: 1, maximumPacketSize: max(packet.count, 16))
        if !packet.isEmpty {
            packet.withUnsafeBytes { comp.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        }
        comp.byteLength = UInt32(packet.count)
        comp.packetCount = 1
        // An empty packet with the frame count set asks the decoder to conceal.
        comp.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0,
                                                                   mVariableFramesInPacket: packet.isEmpty ? Audio.frameSize : 0,
                                                                   mDataByteSize: UInt32(packet.count))
        let out = AVAudioPCMBuffer(pcmFormat: Audio.pcmFormat, frameCapacity: Audio.frameSize * 2)!
        var fed = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return comp
        }
        guard error == nil else { return [] }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
