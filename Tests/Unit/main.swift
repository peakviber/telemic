// Unit tests for Telemic's core logic. Run with ./test.sh
// (a plain executable: swift-testing/XCTest need Xcode, which this project doesn't require).

import Foundation

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
var passes = 0

func check(_ cond: @autoclosure () -> Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if cond() { passes += 1 } else { failures += 1; print("FAIL \(name) (line \(line))") }
}

func test(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print(failures == before ? "ok   \(name)" : "FAIL \(name)")
}

func frame(_ n: UInt8) -> Data { Data([n, n, n]) }

// MARK: - Wire

test("wire: pack/unpack frames") {
    let frames = [Data([1, 2, 3]), Data(), Data(repeating: 9, count: 300)]
    check(Wire.unpackFrames(Wire.packFrames(frames)) == frames, "round trip")
    check(Wire.unpackFrames(Data()) == nil, "empty")
    check(Wire.unpackFrames(Data([2, 0, 5, 1])) == nil, "truncated")
}

test("wire: hello/status/announce/audio round trip") {
    let id = UUID()
    let h = Wire.Hello(senderID: id, publicKey: Data(repeating: 7, count: 32), salt: Data(repeating: 3, count: 16), name: "Mac 你好")
    let h2 = Wire.Hello(h.encode())
    check(h2?.senderID == id && h2?.name == "Mac 你好" && h2?.salt == h.salt, "hello")
    check(Wire.kind(of: h.encode()) == .hello, "hello kind")

    let s = Wire.Status(publicKey: Data(repeating: 1, count: 32), state: .standby, name: "Host")
    let s2 = Wire.Status(s.encode())
    check(s2?.state == .standby && s2?.name == "Host", "status")

    let a = Wire.Audio(senderID: id, seq: 0x0102_0304_0506_0708, sealed: Data(repeating: 5, count: 40))
    let a2 = Wire.Audio(a.encode())
    check(a2?.seq == a.seq && a2?.sealed == a.sealed && a2?.senderID == id, "audio")
    check(Wire.kind(of: a.encode()) == .audioRed, "audio defaults to redundant kind")

    let an = Wire.Announce(publicKey: Data(repeating: 2, count: 32), name: "R")
    check(Wire.Announce(an.encode())?.name == "R", "announce")
}

test("wire: ping/pong") {
    let ping = Wire.ping(123_456_789)
    check(Wire.kind(of: ping) == .ping, "ping kind")
    let pong = Wire.pong(for: ping)!
    check(Wire.kind(of: pong) == .pong, "pong kind")
    check(Wire.pongNanos(pong) == 123_456_789, "echoed timestamp")
    check(Wire.pong(for: Data([1, 2])) == nil, "short ping rejected")
}

test("wire: version") {
    let id = UUID()
    let v = Wire.parseVersion(Wire.version(id: id, "0.6.0"))
    check(v?.id == id && v?.version == "0.6.0", "round trip")
    check(Wire.kind(of: Wire.version(id: id, "1.2")) == .version, "kind")
    check(Wire.parseVersion(Wire.header(.version) + id.data) == nil, "empty version rejected")
    check(Wire.parseVersion(Wire.header(.version) + id.data + Data("0.6<script>".utf8)) == nil, "non-numeric rejected")
    check(Wire.PeerVersion.known("0.6.0").note(ours: "0.6.0") == nil, "same version: no note")
    check(Wire.PeerVersion.known("0.5.1").note(ours: "0.6.0") != nil, "different version: note")
    check(Wire.PeerVersion.legacy.note(ours: "0.6.0") != nil, "legacy: note")
    check(Wire.PeerVersion.unknown.note(ours: "0.6.0") == nil, "unknown: no note")
}

test("wire: rejects garbage") {
    check(Wire.kind(of: Data("XXXX\u{1}".utf8)) == nil, "bad magic")
    check(Wire.Hello(Wire.header(.hello)) == nil, "short hello")
    check(Wire.Audio(Wire.header(.audioRed)) == nil, "short audio")
}

// MARK: - Crypto

test("crypto: seal/open, nonce and key binding") {
    let salt = Crypto.randomSalt()
    let key = Crypto.sessionKey(peerPublicKey: Identity.publicKey, salt: salt)!
    let other = Crypto.sessionKey(peerPublicKey: Identity.publicKey, salt: Crypto.randomSalt())!
    let id = UUID()
    let msg = Data("opus".utf8)
    let sealed = Crypto.seal(msg, key: key, senderID: id, seq: 42)!
    check(Crypto.open(sealed, key: key, senderID: id, seq: 42) == msg, "opens")
    check(Crypto.open(sealed, key: key, senderID: id, seq: 43) == nil, "wrong seq")
    check(Crypto.open(sealed, key: key, senderID: UUID(), seq: 42) == nil, "wrong sender")
    check(Crypto.open(sealed, key: other, senderID: id, seq: 42) == nil, "wrong key")
    var tampered = sealed
    tampered[0] ^= 1
    check(Crypto.open(tampered, key: key, senderID: id, seq: 42) == nil, "tampered")
    check(Crypto.fingerprint(Identity.publicKey).count == 9, "fingerprint format")
}

// MARK: - Endpoint

test("endpoint: parse and proxy detection") {
    check(Endpoint.parse("100.64.0.10:47810") == Endpoint(host: "100.64.0.10", port: 47810), "ip:port")
    check(Endpoint.parse(" 100.64.0.10 ") == Endpoint(host: "100.64.0.10", port: Wire.defaultPort), "ip only")
    check(Endpoint.parse("mac-mini:9") == Endpoint(host: "mac-mini", port: 9), "name:port")
    check(Endpoint.parse("") == nil && Endpoint.parse(":80") == nil, "invalid")
    let fake = Endpoint(host: "198.18.1.40", port: 1).resolve()!
    let real = Endpoint(host: "100.64.0.10", port: 1).resolve()!
    check(Endpoint.isFakeProxyIP(fake) && !Endpoint.isFakeProxyIP(real), "fake-ip range")
    check(real.isTailnetOrLoopback && !fake.isTailnetOrLoopback, "tailnet range")
}

// MARK: - Jitter buffer

func drain(_ jb: inout JitterBuffer) -> [JitterBuffer.Output] {
    var out: [JitterBuffer.Output] = []
    while let o = jb.next() { out.append(o) }
    return out
}

/// Sends seq 1...n with two redundant frames, skipping `lost`.
func run(_ n: UInt64, lost: Set<UInt64>, reorder: Bool = false) -> [JitterBuffer.Output] {
    var jb = JitterBuffer()
    var out: [JitterBuffer.Output] = []
    var seqs = Array(1...n)
    if reorder { seqs.swapAt(3, 4) }
    for s in seqs where !lost.contains(s) {
        let frames = (0..<3).compactMap { i -> Data? in s > UInt64(i) ? frame(UInt8(s - UInt64(i))) : nil }
        jb.insert(seq: s, frames: frames)
        out += drain(&jb)
    }
    return out
}

test("jitter: in order, nothing lost") {
    let out = run(10, lost: [])
    check(out == (1...10).map { .frame(frame(UInt8($0)), recovered: false) }, "all frames in order")
}

test("jitter: one or two lost are rebuilt from redundancy") {
    let one = run(10, lost: [4])
    check(one.count == 10 && one[3] == .frame(frame(4), recovered: true), "single loss recovered")
    let two = run(10, lost: [4, 5])
    check(two[3] == .frame(frame(4), recovered: true) && two[4] == .frame(frame(5), recovered: true), "burst of 2 recovered")
}

test("jitter: three lost in a row are concealed, then playback continues") {
    let out = run(12, lost: [4, 5, 6])
    check(out[3] == .conceal, "frame 4 concealed (no copy survived)")
    check(out[4] == .frame(frame(5), recovered: true) && out[5] == .frame(frame(6), recovered: true), "5 and 6 rebuilt from 7")
    check(out.count == 12 && out[11] == .frame(frame(12), recovered: false), "continues to the end")
}

test("jitter: reordered packets still play in order") {
    let out = run(10, lost: [], reorder: true)
    check(out.count == 10, "count")
    check(out.map { o -> UInt8 in if case .frame(let d, _) = o { return d[0] } else { return 0 } } == Array(1...10), "order")
}

test("jitter: duplicates and stale packets are ignored; big jumps resync") {
    var jb = JitterBuffer()
    jb.insert(seq: 1, frames: [frame(1)])
    jb.insert(seq: 1, frames: [frame(1)])
    check(drain(&jb).count == 1, "duplicate played once")
    jb.insert(seq: 1, frames: [frame(1)])
    check(drain(&jb).isEmpty, "stale ignored")
    jb.insert(seq: 500, frames: [frame(9)])
    check(jb.playSeq == 500 && drain(&jb) == [.frame(frame(9), recovered: false)], "resync after a long gap")
}

// MARK: - Playout / drift

test("playout: prebuffers, then copies samples exactly") {
    var p = Playout()
    var out = [Float](repeating: 0, count: 480)
    p.append((0..<960).map { Float($0) })
    check(!p.read(480, into: &out), "waits for 40 ms")
    p.append((960..<2400).map { Float($0) })
    check(p.read(480, into: &out), "starts")
    check(out == (0..<480).map { Float($0) }, "bit-exact copy at normal rate")
    check(p.rate == 1, "no correction needed")
}

test("playout: underrun goes back to prebuffering") {
    var p = Playout()
    var out = [Float](repeating: 0, count: 2_000)
    p.append([Float](repeating: 0.5, count: 1_920))
    check(p.read(2_000, into: &out), "plays what it has")
    check(p.prebuffering && out[1_919] == 0.5 && out[1_919 + 1] == 0, "rest is silence, rebuffering")
}

/// Simulates `minutes` of a sender whose clock runs at `ratio` × the host's.
func simulateDrift(ratio: Double, minutes: Double) -> (maxLevel: Int, minLevelAfterStart: Int, underruns: Int, catchUps: Int, corrected: Bool) {
    var p = Playout()
    var incoming = 0.0
    var maxLevel = 0, minLevel = Int.max, underruns = 0, catchUps = 0
    var corrected = false
    var out = [Float](repeating: 0, count: 480)
    let ticks = Int(minutes * 60 * 100)          // 10 ms ticks
    for t in 0..<ticks {
        // Network delivers 20 ms frames, scaled by the clock ratio.
        incoming += 480 * ratio
        while incoming >= 960 {
            let before = p.count
            p.append([Float](repeating: 0.1, count: 960))
            if p.count < before + 960 { catchUps += 1 }
            incoming -= 960
        }
        for i in out.indices { out[i] = 0 }
        let wasPlaying = !p.prebuffering
        _ = p.read(480, into: &out)
        if wasPlaying && p.prebuffering { underruns += 1 }
        if p.rate != 1 { corrected = true }
        if t > 500 { maxLevel = max(maxLevel, p.count); minLevel = min(minLevel, p.count) }
    }
    return (maxLevel, minLevel, underruns, catchUps, corrected)
}

test("drift: sender 0.05% fast stays bounded without hard catch-up") {
    let r = simulateDrift(ratio: 1.0005, minutes: 30)
    check(r.corrected, "correction engaged")
    check(r.catchUps == 0, "no hard catch-up (was one every ~10 min before)")
    check(r.maxLevel < Playout.maxBacklog, "latency stays below 200 ms")
}

test("drift: sender 0.05% slow stays bounded without underruns") {
    let r = simulateDrift(ratio: 0.9995, minutes: 30)
    check(r.corrected, "correction engaged")
    check(r.underruns == 0, "no rebuffering gaps")
}

test("drift: matched clocks are never touched") {
    let r = simulateDrift(ratio: 1.0, minutes: 10)
    check(!r.corrected && r.underruns == 0 && r.catchUps == 0, "plain copy throughout")
}

// MARK: - Limiter and rate limiter

test("soft limiter: transparent below 0.8, continuous, bounded") {
    var x: [Float] = [0, 0.5, -0.8, 0.8, 0.8001, 1.5, -3, 10]
    ReceiverEngine.softLimit(&x)
    check(x[0] == 0 && x[1] == 0.5 && x[2] == -0.8 && x[3] == 0.8, "unchanged below threshold")
    check(abs(x[4] - 0.8001) < 0.001, "no jump at the knee")
    check(x[5] < 1 && x[5] > 0.8 && x[6] >= -1 && x[7] <= 1, "peaks bounded to ±1")
}

test("rate limiter: burst then steady rate, per address") {
    var r = RateLimiter(perSecond: 5, burst: 10)
    let allowed = (0..<20).filter { _ in r.allow(1, now: 100) }.count
    check(allowed == 10, "burst of 10")
    check(r.allow(2, now: 100), "other address unaffected")
    check(r.allow(1, now: 100.2) && !r.allow(1, now: 100.2), "refills at 5/s")
}

print("\n\(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
