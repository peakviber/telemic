import CryptoKit
import Foundation
import IOKit.pwr_mgt

/// Host side: accepts senders, decrypts and decodes their audio, mixes the
/// selected ones, and hands PCM to the RemoteMic driver over loopback.
final class ReceiverEngine {
    enum Approval: String, Codable { case approved, denied }
    enum Mode: String, Codable { case single, mix }

    struct PeerView: Identifiable, Equatable {
        let id: UUID
        var name: String             // what the sender calls itself
        var alias: String?           // what the user renamed it to
        var displayName: String { alias ?? name }
        var fingerprint: String
        var endpoint: String
        var approval: Approval?      // nil = waiting for the user
        var online: Bool
        var audible: Bool
        var muted: Bool
        var gain: Float              // 0…2, 1 = unchanged
        var version: Wire.PeerVersion = .unknown
    }

    /// Structural state: changes only when something actually happens (a sender comes
    /// online, an approval, a setting). Views that hold menus observe only this.
    struct Snapshot: Equatable {
        var listening = false
        var error: String?
        var port: UInt16 = Wire.defaultPort
        var mode: Mode = .single
        var selected: UUID?
        var tailnetOnly = false
        var peers: [PeerView] = []
    }

    struct Loss: Equatable {
        var network: Double          // fraction of frames that didn't arrive on time
        var residual: Double         // fraction still missing after recovery (concealed)
    }

    /// Fast-changing numbers (10 updates a second): meters and stats only.
    struct Live: Equatable {
        var levels: [UUID: Float] = [:]
        var bufferMs: [UUID: Int] = [:]
        var loss: [UUID: Loss] = [:]
        var receiving = false
    }

    var onUpdate: ((Snapshot) -> Void)?
    var onLive: ((Live) -> Void)?
    /// Called once per new sender that asks to connect (for a notification).
    var onPending: ((UUID, String, String) -> Void)?

    private final class Peer {
        let id: UUID
        var name = ""
        var publicKey = Data()
        var salt = Data()
        var key: SymmetricKey?
        var decoder = OpusDecoder()
        var endpoint: sockaddr_in
        var lastSeen = Date.distantPast
        var lastAudio = Date.distantPast
        var peak: Float = 0
        var jitter = JitterBuffer()
        var playout = Playout()
        var notified = false
        var version: String?
        var hellos = 0

        // Loss statistics for the current 10 s window, and the last finished window.
        var played = 0, recovered = 0, concealed = 0
        var windowStart = Date()
        var lastWindow: (played: Int, recovered: Int, concealed: Int)?

        init(id: UUID, endpoint: sockaddr_in) { self.id = id; self.endpoint = endpoint }

        func resetStream() {
            jitter.reset()
            playout.reset()
        }
    }

    private let port: UInt16
    private let autoApprove: Bool
    private let feedsDriver: Bool
    private let defaults: UserDefaults
    private let q = DispatchQueue(label: "remotemic.receiver", qos: .userInteractive)
    private var socket: UDPSocket?
    private let driverSocket = UDPSocket()
    private let driverAddr = Endpoint(host: "127.0.0.1", port: Wire.driverPort).resolve()!
    private var peers: [UUID: Peer] = [:]
    private var mixTimer: DispatchSourceTimer?
    private var uiTimer: DispatchSourceTimer?
    private var clockStart: UInt64 = 0
    private var startedAt = Date()
    private var produced: Int64 = 0
    private var sleepAssertion: IOPMAssertionID = 0
    private var bindError: String?
    private var helloLimiter = RateLimiter(perSecond: 5, burst: 10)
    private var discoverLimiter = RateLimiter(perSecond: 2, burst: 4)
    private static let maxPending = 10

    // Persisted settings.
    private var approvals: [String: Approval]           // by base64 public key
    private var muted: Set<UUID>
    private var gains: [UUID: Float]
    private var aliases: [UUID: String]
    private var mode: Mode
    private var selected: UUID?
    private var tailnetOnly: Bool

    /// `autoApprove` is the self-test mode: it starts from clean settings and keeps
    /// audio away from the real RemoteMic driver, so a test never disturbs a live microphone.
    init(port: UInt16 = Wire.defaultPort, autoApprove: Bool = false) {
        self.port = port
        self.autoApprove = autoApprove
        feedsDriver = !autoApprove
        if autoApprove {
            UserDefaults.standard.removePersistentDomain(forName: "com.remotemic.selftest")
            defaults = UserDefaults(suiteName: "com.remotemic.selftest")!
        } else {
            defaults = .standard
        }
        let d = defaults
        approvals = (d.dictionary(forKey: "receiver.approvals") as? [String: String] ?? [:])
            .compactMapValues(Approval.init(rawValue:))
        muted = Set((d.stringArray(forKey: "receiver.muted") ?? []).compactMap(UUID.init(uuidString:)))
        gains = Dictionary(uniqueKeysWithValues: (d.dictionary(forKey: "receiver.gains") as? [String: Double] ?? [:])
            .compactMap { k, v in UUID(uuidString: k).map { ($0, Float(v)) } })
        aliases = Dictionary(uniqueKeysWithValues: (d.dictionary(forKey: "receiver.aliases") as? [String: String] ?? [:])
            .compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        mode = Mode(rawValue: d.string(forKey: "receiver.mode") ?? "") ?? .single
        selected = d.string(forKey: "receiver.selected").flatMap(UUID.init(uuidString:))
        tailnetOnly = d.bool(forKey: "receiver.tailnetOnly")
    }

    // MARK: Lifecycle

    func start() {
        q.async { [self] in
            let s = UDPSocket()
            if let err = s.bind(port: port) {
                bindError = L("端口 \(port) 无法监听：\(err)", "Can't listen on port \(port): \(err)")
                Log.info("receiver bind failed: \(err)")
                s.close()
            } else {
                socket = s
                s.startReceiving { [weak self] data, from in self?.q.async { self?.handle(data, from) } }
                Log.info("receiver listening on \(port)")
            }

            clockStart = DispatchTime.now().uptimeNanoseconds
            startedAt = Date()
            produced = 0
            let mix = DispatchSource.makeTimerSource(flags: .strict, queue: q)
            mix.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
            mix.setEventHandler { [weak self] in self?.mixTick() }
            mix.resume()
            mixTimer = mix

            let ui = DispatchSource.makeTimerSource(queue: q)
            ui.schedule(deadline: .now(), repeating: .milliseconds(100))
            ui.setEventHandler { [weak self] in self?.publish() }
            ui.resume()
            uiTimer = ui

            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "RemoteMic is receiving audio" as CFString, &sleepAssertion)
        }
    }

    func stop() {
        q.sync {
            mixTimer?.cancel(); mixTimer = nil
            uiTimer?.cancel(); uiTimer = nil
            socket?.close(); socket = nil
            if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
        }
    }

    // MARK: User actions

    func decide(_ id: UUID, approve: Bool) {
        q.async { [self] in
            guard let p = peers[id] else { return }
            approvals[p.publicKey.base64EncodedString()] = approve ? .approved : .denied
            saveApprovals()
            Log.info("\(approve ? "approved" : "denied") \(p.name) (\(Crypto.fingerprint(p.publicKey)))")
            if approve, mode == .single, selected == nil { setSelected(id) }
            reply(to: p)
        }
    }

    /// Removes a sender and its approval; it will have to ask again.
    func forget(_ id: UUID) {
        q.async { [self] in
            guard let p = peers[id] else { return }
            approvals[p.publicKey.base64EncodedString()] = nil
            saveApprovals()
            peers[id] = nil
            aliases[id] = nil
            gains[id] = nil
            saveAliases(); saveGains()
            if selected == id { setSelected(nil) }
            Log.info("forgot \(p.name)")
        }
    }

    func setMode(_ m: Mode) {
        q.async { [self] in
            mode = m
            defaults.set(m.rawValue, forKey: "receiver.mode")
            peers.values.forEach { reply(to: $0) }
        }
    }

    func select(_ id: UUID) {
        q.async { [self] in
            setSelected(id)
            peers.values.forEach { reply(to: $0) }
        }
    }

    func setMuted(_ id: UUID, _ on: Bool) {
        q.async { [self] in
            if on { muted.insert(id) } else { muted.remove(id) }
            defaults.set(muted.map(\.uuidString), forKey: "receiver.muted")
            if let p = peers[id] { reply(to: p) }
        }
    }

    func setGain(_ id: UUID, _ g: Float) {
        q.async { [self] in
            gains[id] = abs(g - 1) < 0.01 ? nil : max(0, min(2, g))
            saveGains()
        }
    }

    func rename(_ id: UUID, to name: String?) {
        q.async { [self] in
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            aliases[id] = (trimmed?.isEmpty ?? true) ? nil : trimmed
            saveAliases()
        }
    }

    func setTailnetOnly(_ on: Bool) {
        q.async { [self] in
            tailnetOnly = on
            defaults.set(on, forKey: "receiver.tailnetOnly")
        }
    }

    // MARK: Packets

    private func handle(_ data: Data, _ from: sockaddr_in) {
        if tailnetOnly, !from.isTailnetOrLoopback { return }
        switch Wire.kind(of: data) {
        case .hello: if let h = Wire.Hello(data) { handleHello(h, from) }
        case .audio: if let a = Wire.Audio(data) { handleAudio(a, from, redundant: false) }
        case .audioRed: if let a = Wire.Audio(data) { handleAudio(a, from, redundant: true) }
        case .ping:
            guard isKnownApproved(from) || helloLimiter.allow(from.ipv4), let pong = Wire.pong(for: data) else { return }
            socket?.send(pong, to: from)
        case .version:
            // Only senders that already said hello get an answer, so this can't be used to probe.
            guard let v = Wire.parseVersion(data), let p = peers[v.id],
                  p.endpoint.sin_addr.s_addr == from.sin_addr.s_addr else { return }
            p.version = v.version
            socket?.send(Wire.version(id: UUID(uuid: UUID_NULL), AppVersion.current), to: from)
        case .discover:
            guard discoverLimiter.allow(from.ipv4) else { return }
            socket?.send(Wire.Announce(publicKey: Identity.publicKey, name: Identity.name).encode(), to: from)
        default: break
        }
    }

    private func handleHello(_ h: Wire.Hello, _ from: sockaddr_in) {
        guard h.publicKey.count == 32, h.salt.count == 16 else { return }
        let known = approvals[h.publicKey.base64EncodedString()] == .approved
        // Unknown, pending or denied senders are rate-limited, and the pending list is capped.
        if !known {
            guard helloLimiter.allow(from.ipv4) else { return }
            if peers[h.senderID] == nil, peers.values.filter({ approval(of: $0) == nil }).count >= Self.maxPending { return }
        }
        let p = peers[h.senderID] ?? Peer(id: h.senderID, endpoint: from)
        peers[h.senderID] = p
        if p.publicKey != h.publicKey || p.salt != h.salt {
            // New session: fresh key, decoder and sequence space.
            p.publicKey = h.publicKey
            p.salt = h.salt
            p.key = Crypto.sessionKey(peerPublicKey: h.publicKey, salt: h.salt)
            p.decoder = OpusDecoder()
            p.resetStream()
            Log.info("session from \(h.name) at \(Endpoint(from))")
        }
        p.name = h.name
        p.hellos += 1
        p.endpoint = from
        p.lastSeen = Date()
        if autoApprove, approval(of: p) == nil {
            approvals[p.publicKey.base64EncodedString()] = .approved
        }
        if approval(of: p) == nil, !p.notified {
            p.notified = true
            Log.info("\(h.name) asks to connect")
            let cb = onPending, id = p.id, name = h.name, fp = Crypto.fingerprint(h.publicKey)
            DispatchQueue.main.async { cb?(id, name, fp) }
        }
        if mode == .single, selected == nil, approval(of: p) == .approved { setSelected(p.id) }
        reply(to: p)
    }

    /// `redundant`: packet carries the frames for seq, seq-1, seq-2… (v0.3+ senders).
    private func handleAudio(_ a: Wire.Audio, _ from: sockaddr_in, redundant: Bool) {
        guard let p = peers[a.senderID], approval(of: p) == .approved, let key = p.key,
              let plain = Crypto.open(a.sealed, key: key, senderID: a.senderID, seq: a.seq)
        else { return }
        let opusFrames = redundant ? (Wire.unpackFrames(plain) ?? []) : [plain]
        guard !opusFrames.isEmpty else { return }
        p.lastSeen = Date()
        p.lastAudio = Date()
        p.endpoint = from
        p.jitter.insert(seq: a.seq, frames: opusFrames)
        drain(p)
    }

    /// Decodes frames in order. A missing frame is concealed once three newer
    /// packets have arrived without a copy of it (60 ms of waiting at most).
    private func drain(_ p: Peer) {
        while let out = p.jitter.next() {
            let pcm: [Float]
            switch out {
            case .frame(let f, let recovered):
                pcm = p.decoder?.decode(f) ?? []
                if recovered { p.recovered += 1 }
            case .conceal:
                pcm = p.decoder?.conceal() ?? []
                p.concealed += 1
            }
            p.played += 1
            guard !pcm.isEmpty else { continue }
            pcm.withUnsafeBufferPointer { p.peak = max(p.peak, Audio.peak($0)) }
            guard isAudible(p) else { continue }
            p.playout.append(pcm)
        }
        rollStats(p)
    }

    private func reply(to p: Peer) {
        let state: Wire.LinkState
        switch approval(of: p) {
        case nil: state = .pending
        case .denied: state = .denied
        case .approved: state = isAudible(p) ? .active : .standby
        }
        socket?.send(Wire.Status(publicKey: Identity.publicKey, state: state, name: Identity.name).encode(), to: p.endpoint)
    }

    // MARK: Mixing

    private func mixTick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let due = Int64(Double(now - clockStart) / 1e9 * Audio.sampleRate)
        var n = Int(due - produced)
        guard n > 0 else { return }
        if n > 4_800 { n = 960; produced = due - 960 }     // we were stalled; don't burst
        produced += Int64(n)

        var mix = [Float](repeating: 0, count: n)
        var sources = 0
        var boosted = false
        for p in peers.values where isAudible(p) && isOnline(p) {
            let g = gains[p.id] ?? 1
            if p.playout.read(n, into: &mix, gain: g) {
                sources += 1
                if g > 1 { boosted = true }
            }
        }
        guard sources > 0, feedsDriver else { return }
        // A single sender at normal volume passes through untouched.
        if sources > 1 || boosted { Self.softLimit(&mix) }
        var offset = 0
        while offset < n {
            let count = min(4_000, n - offset)
            var pkt = Data("RMIC".utf8) + Data([1, 0, 0, 0])
            mix[offset..<offset + count].withUnsafeBytes { pkt.append(contentsOf: $0) }
            driverSocket.send(pkt, to: driverAddr)
            offset += count
        }
    }

    /// Leaves |x| ≤ 0.8 alone and bends louder peaks smoothly toward 1 (continuous, no jump).
    static func softLimit(_ x: inout [Float]) {
        let t: Float = 0.8
        for i in x.indices where abs(x[i]) > t {
            let over = (abs(x[i]) - t) / (1 - t)
            x[i] = (x[i] < 0 ? -1 : 1) * (t + (1 - t) * tanh(over))
        }
    }

    // MARK: Stats

    private func rollStats(_ p: Peer) {
        guard Date().timeIntervalSince(p.windowStart) >= 10 else { return }
        p.lastWindow = (p.played, p.recovered, p.concealed)
        p.played = 0; p.recovered = 0; p.concealed = 0
        p.windowStart = Date()
    }

    private func lossStats(_ p: Peer) -> (Double, Double)? {
        // Use the last full window, or the current one once it has a few seconds of audio.
        let w = p.lastWindow ?? (p.played >= 150 ? (p.played, p.recovered, p.concealed) : nil)
        guard let w, w.played > 0 else { return nil }
        return (Double(w.recovered + w.concealed) / Double(w.played), Double(w.concealed) / Double(w.played))
    }

    // MARK: Helpers

    private func approval(of p: Peer) -> Approval? { approvals[p.publicKey.base64EncodedString()] }
    private func isOnline(_ p: Peer) -> Bool { Date().timeIntervalSince(p.lastSeen) < 3 }

    private func isKnownApproved(_ from: sockaddr_in) -> Bool {
        peers.values.contains { $0.endpoint.ipv4 == from.ipv4 && $0.endpoint.sin_port == from.sin_port && approval(of: $0) == .approved }
    }

    private func isAudible(_ p: Peer) -> Bool {
        guard approval(of: p) == .approved, !muted.contains(p.id) else { return false }
        return mode == .mix || selected == p.id
    }

    private func setSelected(_ id: UUID?) {
        selected = id
        defaults.set(id?.uuidString, forKey: "receiver.selected")
    }

    private func saveApprovals() { defaults.set(approvals.mapValues(\.rawValue), forKey: "receiver.approvals") }
    private func saveGains() {
        defaults.set(Dictionary(uniqueKeysWithValues: gains.map { ($0.key.uuidString, Double($0.value)) }), forKey: "receiver.gains")
    }
    private func saveAliases() {
        defaults.set(Dictionary(uniqueKeysWithValues: aliases.map { ($0.key.uuidString, $0.value) }), forKey: "receiver.aliases")
    }

    /// Single mode: if the selected sender has been gone for a few seconds and another
    /// approved, unmuted sender is online, listen to that one instead, so the microphone
    /// doesn't go silent when you move to another Mac. No switching back when the old one
    /// returns; the user can still pick any sender by hand.
    private func failOver() {
        guard mode == .single else { return }
        let goneSince = selected.flatMap { peers[$0] }.map { max($0.lastSeen, startedAt) } ?? startedAt
        guard Date().timeIntervalSince(goneSince) > Self.failOverAfter else { return }
        let candidates = peers.values.filter { approval(of: $0) == .approved && !muted.contains($0.id) && isOnline($0) && $0.id != selected }
        guard let next = candidates.max(by: { ($0.lastAudio, $0.lastSeen) < ($1.lastAudio, $1.lastSeen) }) else { return }
        Log.info("selected sender gone; switching to \(next.name)")
        setSelected(next.id)
        peers.values.forEach { reply(to: $0) }
    }
    static let failOverAfter: TimeInterval = 5

    private func publish() {
        failOver()
        // Drop senders that have been gone for a minute and were never approved.
        peers = peers.filter { approval(of: $0.value) != nil || Date().timeIntervalSince($0.value.lastSeen) < 60 }
        var s = Snapshot()
        s.listening = socket != nil
        s.error = bindError
        s.port = port
        s.mode = mode
        s.selected = selected
        s.tailnetOnly = tailnetOnly
        s.peers = peers.values
            .map { p in
                PeerView(id: p.id, name: p.name, alias: aliases[p.id], fingerprint: Crypto.fingerprint(p.publicKey),
                         endpoint: Endpoint(p.endpoint).description, approval: approval(of: p),
                         online: isOnline(p), audible: isAudible(p), muted: muted.contains(p.id),
                         gain: gains[p.id] ?? 1,
                         version: p.version.map { .known($0) } ?? (p.hellos >= 3 ? .legacy : .unknown))
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        var live = Live()
        for p in peers.values {
            live.levels[p.id] = Audio.meter(p.peak)
            if isAudible(p), isOnline(p), !p.playout.prebuffering { live.bufferMs[p.id] = p.playout.count / 48 }
            if let l = lossStats(p) { live.loss[p.id] = Loss(network: l.0, residual: l.1) }
            p.peak = 0
        }
        live.receiving = peers.values.contains { isAudible($0) && Date().timeIntervalSince($0.lastAudio) < 0.5 }

        // The endpoint string changes when a sender's port changes; that's rare, fine to publish.
        let cb = onUpdate, liveCb = onLive
        DispatchQueue.main.async {
            cb?(s)
            liveCb?(live)
        }
    }
}
