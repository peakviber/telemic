// remotemic-feed — proof-of-concept tool for the RemoteMic driver.
//
// Sends audio to the driver over 127.0.0.1:47811 without ever playing it
// through Core Audio, and can meter what apps receive from the RemoteMic device.
//
//   remotemic-feed tone on|off        built-in 440 Hz tone inside the driver
//   remotemic-feed sine [seconds]     stream a generated 440 Hz sine
//   remotemic-feed say "text" [voice] synthesize speech to a file, then stream it
//   remotemic-feed file <path>        stream any audio file (converted to 48 kHz mono)
//   remotemic-feed meter [seconds]    record from RemoteMic and print the level

import AVFoundation
import CoreAudio
import Foundation

let sampleRate = 48_000.0
let framesPerPacket = 960   // 20 ms

// MARK: - Loopback sender

final class Sender {
    private let fd: Int32
    private var addr = sockaddr_in()

    init() {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(47811).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    }

    func send(type: UInt8, samples: ArraySlice<Float> = []) {
        var pkt = [UInt8]("RMIC".utf8) + [type, 0, 0, 0]
        samples.withUnsafeBytes { pkt.append(contentsOf: $0) }
        _ = pkt.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Streams samples in real time, 20 ms per packet, with a small head start.
    func stream(_ samples: [Float]) {
        let start = DispatchTime.now().uptimeNanoseconds
        let packetNs = UInt64(Double(framesPerPacket) / sampleRate * 1e9)
        var index = 0, packet: UInt64 = 0
        while index < samples.count {
            let end = min(index + framesPerPacket, samples.count)
            send(type: 1, samples: samples[index..<end])
            index = end
            packet += 1
            // Run ~60 ms ahead of real time so the driver's 40 ms prebuffer fills.
            let due = start + packet * packetNs
            let now = DispatchTime.now().uptimeNanoseconds
            if due > now + 60_000_000 { usleep(useconds_t((due - now - 60_000_000) / 1000)) }
        }
    }
}

// MARK: - Audio helpers

func sine(seconds: Double) -> [Float] {
    let n = Int(seconds * sampleRate)
    return (0..<n).map { 0.2 * Float(sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
}

func loadMono48k(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
        throw NSError(domain: "remotemic", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot convert \(file.processingFormat)"])
    }
    let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: inBuf)
    let ratio = sampleRate / file.processingFormat.sampleRate
    let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 4096)!
    var fed = false
    var error: NSError?
    converter.convert(to: outBuf, error: &error) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return inBuf
    }
    if let error { throw error }
    return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
}

func synthesize(_ text: String, voice: String?) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("remotemic-say-\(getpid()).aiff")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = (voice.map { ["-v", $0] } ?? []) + ["-o", url.path, text]   // -o: write a file, never play
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: "remotemic", code: 2, userInfo: [NSLocalizedDescriptionKey: "say failed"]) }
    return url
}

// MARK: - Meter (records from the RemoteMic device; never plays anything)

func findDevice(uid: String) -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = withUnsafeMutablePointer(to: &cfUID) { q in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   UInt32(MemoryLayout<CFString>.size), q, &size, &device)
    }
    return (err == noErr && device != kAudioObjectUnknown) ? device : nil
}

func meter(seconds: Double) {
    guard let device = findDevice(uid: "RemoteMic_Device_UID") else {
        print("RemoteMic device not found — is the driver installed and coreaudiod restarted?")
        exit(1)
    }
    let lock = NSLock()
    var sumSquares = 0.0, count = 0, peak: Float = 0
    var procID: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, inData, _, _, _ in
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let buf = list.first, let p = buf.mData?.assumingMemoryBound(to: Float.self) else { return }
        let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        var s = 0.0, pk: Float = 0
        for i in 0..<n { s += Double(p[i] * p[i]); pk = max(pk, abs(p[i])) }
        lock.lock(); sumSquares += s; count += n; peak = max(peak, pk); lock.unlock()
    }
    guard status == noErr, let procID else { print("cannot open RemoteMic (status \(status))"); exit(1) }
    AudioDeviceStart(device, procID)
    print("Recording from RemoteMic for \(Int(seconds)) s (Ctrl-C to stop)…")
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        usleep(250_000)
        lock.lock()
        let rms = count > 0 ? sqrt(sumSquares / Double(count)) : 0
        let pk = peak
        sumSquares = 0; count = 0; peak = 0
        lock.unlock()
        let db = rms > 0 ? 20 * log10(rms) : -120
        let bar = String(repeating: "█", count: max(0, min(40, Int((db + 60) / 1.5))))
        print(String(format: "%7.1f dBFS  peak %.3f  %@", db, pk, bar))
    }
    AudioDeviceStop(device, procID)
    AudioDeviceDestroyIOProcID(device, procID)
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
let sender = Sender()
do {
    switch args.first {
    case "tone":
        let on = args.dropFirst().first != "off"
        sender.send(type: on ? 2 : 3)
        print("driver test tone \(on ? "on" : "off")")
    case "sine":
        let secs = args.count > 1 ? Double(args[1]) ?? 5 : 5
        print("streaming 440 Hz sine for \(secs) s")
        sender.stream(sine(seconds: secs))
    case "say":
        guard args.count > 1 else { throw NSError(domain: "remotemic", code: 3, userInfo: [NSLocalizedDescriptionKey: "usage: say \"text\" [voice]"]) }
        let url = try synthesize(args[1], voice: args.count > 2 ? args[2] : nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try loadMono48k(url)
        print(String(format: "streaming speech (%.1f s)", Double(samples.count) / sampleRate))
        sender.stream(samples)
    case "file":
        guard args.count > 1 else { throw NSError(domain: "remotemic", code: 3, userInfo: [NSLocalizedDescriptionKey: "usage: file <path>"]) }
        let samples = try loadMono48k(URL(fileURLWithPath: args[1]))
        print(String(format: "streaming file (%.1f s)", Double(samples.count) / sampleRate))
        sender.stream(samples)
    case "meter":
        meter(seconds: args.count > 1 ? Double(args[1]) ?? 10 : 10)
    default:
        print("""
        usage:
          remotemic-feed tone on|off
          remotemic-feed sine [seconds]
          remotemic-feed say "text" [voice]
          remotemic-feed file <path>
          remotemic-feed meter [seconds]
        """)
    }
} catch {
    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
