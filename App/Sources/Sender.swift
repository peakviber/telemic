import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Network

/// Client side: captures a microphone, encrypts Opus frames, and sends them to one receiver.
final class SenderEngine {
    enum Link: Equatable {
        case noTarget
        case connecting          // no answer yet
        case pending             // receiver's user hasn't approved us
        case active              // being heard
        case standby             // approved, receiver is listening to another Mac
        case denied
        case keyChanged          // receiver's key differs from the one we trusted
    }

    struct Discovered: Identifiable, Hashable {
        var endpoint: Endpoint
        var name: String
        var id: String { endpoint.description }
    }

    struct Saved: Identifiable, Hashable, Codable {
        var endpoint: Endpoint
        var name: String
        var id: String { endpoint.description }
    }

    struct Snapshot: Equatable {
        var target: Endpoint?
        var receiverName: String?
        var receiverVersion: Wire.PeerVersion = .unknown
        var fingerprint: String?
        var link: Link = .noTarget
        var sending = false          // microphone on (switch or push-to-talk)
        var switchOn = false         // the persistent switch only
        var pushToTalk = false
        var warning: String?
        var micDenied = false
        var inputUID: String?
        var voiceProcessing = false
        var discovered: [Discovered] = []
        var discovering = false
        var saved: [Saved] = []
    }

    /// Fast-changing numbers (10 updates a second), kept apart from `Snapshot` so views
    /// holding menus aren't rebuilt by every meter tick.
    struct Live: Equatable {
        var level: Float = 0
        var rttMs: Int?
    }

    var onUpdate: ((Snapshot) -> Void)?
    var onLive: ((Live) -> Void)?

    private let q = DispatchQueue(label: "telemic.sender", qos: .userInteractive)
    private let socket = UDPSocket()
    private var target: Endpoint?
    private var targetAddr: sockaddr_in?
    private var salt = Crypto.randomSalt()
    private var key: SymmetricKey?
    private var receiverKey: Data?
    private var receiverName: String?
    private var receiverVersion: String?
    private var statuses = 0
    private var link: Link = .noTarget
    private var lastStatus = Date.distantPast
    private var lastResolve = Date.distantPast
    private var rttMs: Int?
    private var seq: UInt64 = 0
    private var history: [Data] = []           // previous Opus frames, newest first
    private static let redundancy = 2
    /// Self-test hook: fraction of audio packets to drop on purpose.
    var dropRate = 0.0
    private let encoder = OpusEncoder()
    private var pending: [Float] = []
    private var peak: Float = 0
    private var warning: String?
    private var micDenied = false
    private var discovered: [String: Discovered] = [:]
    private var discovering = false
    private var heartbeat: DispatchSourceTimer?
    private var ui: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?
    private var wakeObserver: NSObjectProtocol?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var switchOn = false
    private var pttActive = false
    private var lastCaptureRestart = Date.distantPast
    private var configObserver: NSObjectProtocol?

    // Persisted settings.
    private var inputUID: String?
    private var voiceProcessing: Bool
    private var saved: [Saved]
    /// Receiver public keys we trust, by endpoint (trust on first use).
    private var pins: [String: String]

    private var wantsCapture: Bool { switchOn || pttActive }

    init() {
        let d = UserDefaults.standard
        pins = d.dictionary(forKey: "sender.pins") as? [String: String] ?? [:]
        inputUID = d.string(forKey: "sender.inputUID")
        switchOn = d.bool(forKey: "sender.sending")
        voiceProcessing = d.bool(forKey: "sender.voiceProcessing")
        saved = (d.data(forKey: "sender.saved")).flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
        if let t = d.string(forKey: "sender.target").flatMap(Endpoint.parse) { setTargetLocked(t) }
    }

    func start() {
        socket.startReceiving { [weak self] data, from in self?.q.async { self?.handle(data, from) } }
        q.async { [self] in
            let hb = DispatchSource.makeTimerSource(queue: q)
            hb.schedule(deadline: .now(), repeating: .seconds(1))
            hb.setEventHandler { [weak self] in self?.tick() }
            hb.resume()
            heartbeat = hb
            let u = DispatchSource.makeTimerSource(queue: q)
            u.schedule(deadline: .now(), repeating: .milliseconds(100))
            u.setEventHandler { [weak self] in self?.publish() }
            u.resume()
            ui = u
            if wantsCapture { startCapture() }

            // Network changes (Wi-Fi switch, VPN up/down): resolve again and say hello right away.
            // The monitor also fires on routine route refreshes (seen every ~10 min with VPNs),
            // so only react when the status or the set of interfaces really changed.
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] path in
                let signature = "\(path.status)|" + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
                self?.q.async {
                    guard let self else { return }
                    defer { self.pathSignature = signature }
                    guard let previous = self.pathSignature, previous != signature else { return }
                    self.reconnectNow(reason: "network changed")
                }
            }
            m.start(queue: q)
            pathMonitor = m
        }
        // After sleep the audio engine and the route may be stale.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.q.async {
                guard let self else { return }
                self.reconnectNow(reason: "woke from sleep")
                if self.wantsCapture { self.stopCapture(); self.startCapture() }
            }
        }
    }

    func stop() {
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
        q.sync {
            pathMonitor?.cancel(); pathMonitor = nil
            heartbeat?.cancel(); heartbeat = nil
            ui?.cancel(); ui = nil
            stopCapture()
            socket.close()
        }
    }

    // MARK: User actions

    func setTarget(_ e: Endpoint?) {
        q.async { [self] in
            setTargetLocked(e)
            UserDefaults.standard.set(e?.description, forKey: "sender.target")
            Log.info("target \(e?.description ?? "none")")
            tick()
        }
    }

    func setSending(_ on: Bool) {
        q.async { [self] in
            switchOn = on
            UserDefaults.standard.set(on, forKey: "sender.sending")
            updateCapture()
        }
    }

    /// Hold-to-talk: the microphone is on only while `down` is true (unless the switch is on).
    func setPushToTalk(_ down: Bool) {
        q.async { [self] in
            pttActive = down
            updateCapture()
        }
    }

    func setInput(uid: String?) {
        q.async { [self] in
            inputUID = uid
            UserDefaults.standard.set(uid, forKey: "sender.inputUID")
            if engine != nil { stopCapture(); startCapture() }
        }
    }

    func setVoiceProcessing(_ on: Bool) {
        q.async { [self] in
            voiceProcessing = on
            UserDefaults.standard.set(on, forKey: "sender.voiceProcessing")
            if engine != nil { stopCapture(); startCapture() }
        }
    }

    func removeSaved(_ e: Endpoint) {
        q.async { [self] in
            saved.removeAll { $0.endpoint == e }
            saveSaved()
        }
    }

    /// The receiver's key changed (reinstalled, or someone else answering). Accept the new one.
    func trustNewKey() {
        q.async { [self] in
            guard let t = target else { return }
            pins[t.description] = nil
            UserDefaults.standard.set(pins, forKey: "sender.pins")
            receiverKey = nil
            key = nil
            link = .connecting
            Log.info("trusting new receiver key for \(t)")
            tick()
        }
    }

    /// Looks for receivers on the Tailnet and the local network.
    func discover() {
        q.async { [self] in
            discovering = true
            discovered.removeAll()
            let peers = Tailnet.peers().filter { $0.online && $0.os == "macOS" }
            for p in peers {
                if let a = Endpoint(host: p.ip, port: Wire.defaultPort).resolve() { socket.send(Wire.discover(), to: a) }
            }
            if let b = Endpoint(host: "255.255.255.255", port: Wire.defaultPort).resolve() {
                socket.send(Wire.discover(), to: b)
            }
            q.asyncAfter(deadline: .now() + 2) { [weak self] in self?.discovering = false }
        }
    }

    // MARK: Network

    private func setTargetLocked(_ e: Endpoint?) {
        target = e
        targetAddr = nil
        warning = nil
        salt = Crypto.randomSalt()     // new session
        key = nil
        receiverKey = nil
        receiverName = nil
        receiverVersion = nil
        statuses = 0
        rttMs = nil
        seq = 0
        history.removeAll()
        lastStatus = .distantPast
        link = e == nil ? .noTarget : .connecting
    }

    private func reconnectNow(reason: String) {
        guard target != nil else { return }
        Log.info("reconnect: \(reason)")
        targetAddr = nil
        tick()
    }

    private func tick() {
        guard let t = target else { return }
        let silent = Date().timeIntervalSince(lastStatus) > 3
        // While we get no answer, look the name up again every 5 s (address may have changed).
        if targetAddr == nil || (silent && Date().timeIntervalSince(lastResolve) > 5) {
            lastResolve = Date()
            guard let a = t.resolve() else {
                warning = L("无法解析 \(t.host)", "Can't resolve \(t.host)")
                return
            }
            warning = Endpoint.isFakeProxyIP(a)
                ? L("\(t.host) 被代理解析成了 \(Endpoint(a).host)，请改用 Tailnet IP（100.x.x.x）",
                    "A proxy resolved \(t.host) to \(Endpoint(a).host); use the Tailnet IP (100.x.x.x) instead")
                : nil
            targetAddr = a
        }
        let hello = Wire.Hello(senderID: Identity.deviceID, publicKey: Identity.publicKey, salt: salt, name: Identity.name)
        socket.send(hello.encode(), to: targetAddr!)
        if receiverVersion == nil { socket.send(Wire.version(id: Identity.deviceID, AppVersion.current), to: targetAddr!) }
        socket.send(Wire.ping(DispatchTime.now().uptimeNanoseconds), to: targetAddr!)
        if silent, link != .keyChanged, link != .connecting {
            link = .connecting
            rttMs = nil
            Log.info("lost contact with \(t)")
        }
        // The audio engine sometimes stops on its own (device unplugged, sleep): restart it.
        if wantsCapture, let e = engine, !e.isRunning, Date().timeIntervalSince(lastCaptureRestart) > 5 {
            Log.info("audio engine stopped, restarting")
            stopCapture()
            startCapture()
        }
    }

    private func handle(_ data: Data, _ from: sockaddr_in) {
        switch Wire.kind(of: data) {
        case .status:
            guard let s = Wire.Status(data), let t = target, let a = targetAddr,
                  from.sin_addr.s_addr == a.sin_addr.s_addr, from.sin_port == a.sin_port else { return }
            let b64 = s.publicKey.base64EncodedString()
            if let pinned = pins[t.description], pinned != b64 {
                if link != .keyChanged { Log.info("receiver key changed for \(t)") }
                link = .keyChanged
                key = nil
                return
            }
            if pins[t.description] == nil {
                pins[t.description] = b64
                UserDefaults.standard.set(pins, forKey: "sender.pins")
            }
            if receiverKey != s.publicKey {
                receiverKey = s.publicKey
                key = Crypto.sessionKey(peerPublicKey: s.publicKey, salt: salt)
            }
            if receiverName != s.name || !saved.contains(where: { $0.endpoint == t }) {
                saved.removeAll { $0.endpoint == t }
                saved.insert(Saved(endpoint: t, name: s.name), at: 0)
                saveSaved()
            }
            receiverName = s.name
            statuses += 1
            lastStatus = Date()
            let newLink: Link
            switch s.state {
            case .pending: newLink = .pending
            case .active: newLink = .active
            case .standby: newLink = .standby
            case .denied: newLink = .denied
            }
            if newLink != link { Log.info("link \(t): \(newLink)") }
            link = newLink
        case .pong:
            guard let sent = Wire.pongNanos(data) else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if now > sent { rttMs = Int((now - sent) / 1_000_000) }
        case .version:
            guard let v = Wire.parseVersion(data), let a = targetAddr,
                  from.sin_addr.s_addr == a.sin_addr.s_addr, from.sin_port == a.sin_port else { return }
            receiverVersion = v.version
        case .announce:
            guard let a = Wire.Announce(data) else { return }
            let e = Endpoint(from)
            discovered[e.description] = Discovered(endpoint: e, name: a.name)
        default: break
        }
    }

    private func saveSaved() {
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "sender.saved")
    }

    // MARK: Capture

    private func updateCapture() {
        if wantsCapture { startCapture() } else { stopCapture() }
    }

    private func startCapture() {
        guard engine == nil else { return }
        lastCaptureRestart = Date()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.q.async {
                    guard let self else { return }
                    self.micDenied = !granted
                    if granted, self.wantsCapture { self.startCapture() }
                }
            }
            return
        case .denied, .restricted:
            micDenied = true
            return
        default:
            micDenied = false
        }

        if voiceProcessing, startEngine(voiceProcessing: true) { return }
        if voiceProcessing {
            warning = L("语音增强无法启用，已改用原始麦克风", "Voice enhancement unavailable; using the raw microphone")
        }
        _ = startEngine(voiceProcessing: false)
    }

    /// Returns true when the engine is running.
    private func startEngine(voiceProcessing vp: Bool) -> Bool {
        let e = AVAudioEngine()
        let input = e.inputNode
        if let uid = inputUID, let dev = AudioDevices.deviceID(uid: uid), let unit = input.audioUnit {
            var id = dev
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioObjectID>.size))
        }
        if vp {
            // Apple's voice processing: noise suppression, echo cancellation, automatic gain.
            do { try input.setVoiceProcessingEnabled(true) } catch { Log.info("voice processing: \(error)"); return false }
            if #available(macOS 14.0, *) {
                // Don't turn down other apps' audio while we capture.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
        }
        let hw = input.inputFormat(forBus: 0)
        guard hw.channelCount > 0, hw.sampleRate > 0, let conv = AVAudioConverter(from: hw, to: Audio.pcmFormat) else {
            warning = L("找不到可用的麦克风", "No usable microphone found")
            return false
        }
        if hw.channelCount > 1 { conv.channelMap = [0] }
        converter = conv

        input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buffer, _ in
            guard let self, let conv = self.converter else { return }
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * Audio.sampleRate / hw.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: Audio.pcmFormat, frameCapacity: cap) else { return }
            var fed = false
            var error: NSError?
            conv.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
            self.q.async { self.push(samples) }
        }

        do {
            try e.start()
        } catch {
            input.removeTap(onBus: 0)
            converter = nil
            warning = L("无法启动麦克风：", "Can't start the microphone: ") + error.localizedDescription
            Log.info("engine start failed (vp=\(vp)): \(error)")
            return false
        }
        engine = e
        if vp == voiceProcessing { warning = nil }     // keep the "fell back" warning otherwise
        Log.info("capture started (\(hw.sampleRate) Hz, \(hw.channelCount) ch, voice processing \(vp))")
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { [weak self] _ in
            // Device added/removed or format changed: rebuild the chain.
            self?.q.async {
                guard let self, self.wantsCapture else { return }
                Log.info("audio configuration changed, restarting capture")
                self.stopCapture()
                self.startCapture()
            }
        }
        return true
    }

    private func stopCapture() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        pending.removeAll()
        history.removeAll()      // after a pause, old frames are no longer adjacent
        peak = 0
    }

    /// Feeds 48 kHz mono samples; sends each full 20 ms frame. Also used by the self-test.
    func push(_ samples: [Float]) {
        dispatchPrecondition(condition: .onQueue(q))
        samples.withUnsafeBufferPointer { peak = max(peak, Audio.peak($0)) }
        pending.append(contentsOf: samples)
        let size = Int(Audio.frameSize)
        while pending.count >= size {
            defer { pending.removeFirst(size) }
            guard link == .active, let key, let addr = targetAddr, let encoder else { continue }
            guard let opus = pending.withUnsafeBufferPointer({ encoder.encode(UnsafeBufferPointer(rebasing: $0[0..<size])) })
            else { continue }
            seq += 1
            // Newest frame first, then up to two previous ones for loss recovery.
            let frames = [opus] + history
            history = Array(frames.prefix(Self.redundancy))
            guard let sealed = Crypto.seal(Wire.packFrames(frames), key: key, senderID: Identity.deviceID, seq: seq)
            else { continue }
            if dropRate > 0, Double.random(in: 0..<1) < dropRate { continue }     // self-test only
            socket.send(Wire.Audio(senderID: Identity.deviceID, seq: seq, sealed: sealed).encode(), to: addr)
        }
    }

    /// Self-test hook: push samples from outside the engine queue.
    func pushAsync(_ samples: [Float]) { q.async { self.push(samples) } }
    var currentLink: Link { q.sync { link } }
    var currentRTT: Int? { q.sync { rttMs } }

    private func publish() {
        var s = Snapshot()
        s.target = target
        s.receiverName = receiverName
        s.receiverVersion = receiverVersion.map { .known($0) } ?? (statuses >= 3 ? .legacy : .unknown)
        s.fingerprint = receiverKey.map(Crypto.fingerprint)
        s.link = link
        s.sending = wantsCapture
        s.switchOn = switchOn
        s.pushToTalk = pttActive
        s.warning = warning
        s.micDenied = micDenied
        s.inputUID = inputUID
        s.voiceProcessing = voiceProcessing
        s.discovered = discovered.values.sorted { $0.name < $1.name }
        s.discovering = discovering
        s.saved = saved
        let live = Live(level: Audio.meter(peak), rttMs: link == .connecting ? nil : rttMs)
        peak = 0
        let cb = onUpdate, liveCb = onLive
        DispatchQueue.main.async {
            cb?(s)
            liveCb?(live)
        }
    }
}
