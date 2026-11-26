import Foundation

/// Reorders incoming Opus frames by sequence number and hands them out strictly
/// in order. Frames that only arrived as a later packet's redundant copy count
/// as "recovered"; a frame still missing once `lossWait` newer packets have
/// arrived is reported as `.conceal` so the decoder can fill the gap.
struct JitterBuffer {
    enum Output: Equatable {
        case frame(Data, recovered: Bool)
        case conceal
    }

    var lossWait: UInt64 = 3
    var resyncGap: UInt64 = 50
    private(set) var playSeq: UInt64?
    private(set) var highestSeq: UInt64 = 0
    private var frames: [UInt64: Data] = [:]
    private var viaRedundancy: Set<UInt64> = []

    mutating func reset() {
        playSeq = nil
        highestSeq = 0
        frames.removeAll()
        viaRedundancy.removeAll()
    }

    /// `frames[0]` is the frame for `seq`, `frames[1]` for `seq - 1`, and so on.
    mutating func insert(seq: UInt64, frames newFrames: [Data]) {
        guard seq > 0, !newFrames.isEmpty else { return }
        if let ps = playSeq, seq > ps + resyncGap { reset() }          // long outage: start over
        if playSeq == nil { playSeq = seq - UInt64(min(newFrames.count - 1, Int(seq) - 1)) }
        highestSeq = max(highestSeq, seq)
        for (i, f) in newFrames.enumerated() where !f.isEmpty && UInt64(i) < seq {
            let s = seq - UInt64(i)
            guard s >= playSeq! else { continue }                     // already played or concealed
            if i == 0 {
                frames[s] = f
                viaRedundancy.remove(s)
            } else if frames[s] == nil {
                frames[s] = f
                viaRedundancy.insert(s)
            }
        }
    }

    mutating func next() -> Output? {
        guard let ps = playSeq else { return nil }
        if let f = frames.removeValue(forKey: ps) {
            playSeq = ps + 1
            return .frame(f, recovered: viaRedundancy.remove(ps) != nil)
        }
        if highestSeq >= ps + lossWait {
            playSeq = ps + 1
            return .conceal
        }
        return nil
    }
}

/// Decoded PCM waiting to be played, with a start-up prebuffer and gentle
/// clock-drift correction.
///
/// Sender and host sound cards never run at exactly the same rate, so the
/// buffer slowly fills or drains. While its smoothed level stays inside
/// [low, high] nothing changes and samples are copied as-is. Outside that
/// band, playback runs 0.1% faster or slower (inaudible) until the level is
/// back at the center; a hard catch-up remains only as a last resort.
struct Playout {
    static let prebuffer = 1_920       // 40 ms before starting
    static let low = 1_440             // 30 ms
    static let center = 2_400          // 50 ms
    static let high = 4_800            // 100 ms
    static let maxBacklog = 9_600      // 200 ms: hard catch-up
    static let catchUpTo = 2_880       // 60 ms
    static let correction = 0.001      // ±0.1%

    private(set) var buffer: [Float] = []
    private(set) var prebuffering = true
    private(set) var rate = 1.0
    private(set) var level = 0.0       // smoothed fill, in frames
    private var position = 0.0         // fractional read offset into `buffer`

    var count: Int { buffer.count }

    mutating func reset() { self = Playout() }

    mutating func append(_ pcm: [Float]) {
        buffer.append(contentsOf: pcm)
        if buffer.count > Self.maxBacklog {
            buffer.removeFirst(buffer.count - Self.catchUpTo)
            position = 0
            level = Double(buffer.count)
        }
    }

    /// Adds `n` samples × `gain` into `out`. Returns false while prebuffering.
    mutating func read(_ n: Int, into out: inout [Float], gain: Float = 1) -> Bool {
        if prebuffering {
            guard buffer.count >= Self.prebuffer else { return false }
            prebuffering = false
            level = Double(buffer.count)
        }
        level = level * 0.995 + Double(buffer.count) * 0.005      // ~2 s time constant at 100 Hz
        adjustRate()

        if rate == 1, position == 0 {
            let m = min(n, buffer.count)
            for i in 0..<m { out[i] += buffer[i] * gain }
            buffer.removeFirst(m)
            if m < n { prebuffering = true }
            return true
        }

        var produced = 0
        while produced < n {
            let idx = Int(position)
            guard idx + 1 < buffer.count else { break }
            let frac = Float(position - Double(idx))
            out[produced] += (buffer[idx] + (buffer[idx + 1] - buffer[idx]) * frac) * gain
            position += rate
            produced += 1
        }
        let consumed = min(Int(position), buffer.count)
        buffer.removeFirst(consumed)
        position -= Double(consumed)
        if produced < n {
            prebuffering = true
            position = 0
        }
        return true
    }

    private mutating func adjustRate() {
        if rate == 1 {
            if level > Double(Self.high) { rate = 1 + Self.correction }
            else if level < Double(Self.low) { rate = 1 - Self.correction }
        } else if (rate > 1 && level <= Double(Self.center)) || (rate < 1 && level >= Double(Self.center)) {
            rate = 1
            // Snap back to whole samples so the steady state is a plain copy again.
            position = position.rounded()
            if position >= 1, buffer.count >= Int(position) {
                buffer.removeFirst(Int(position))
            }
            position = 0
        }
    }
}
