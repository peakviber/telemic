import SwiftUI

@main
struct TelemicApp: App {
    @StateObject private var model: AppModel

    init() {
        if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
        LegacyMigration.run()
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(model.live)
        } label: {
            MenuBarLabel(model: model, live: model.live)
        }
        .menuBarExtraStyle(.window)
    }
}

/// `Telemic --selftest`: a receiver and a sender in one process, talking over
/// loopback with encryption, feeding a tone into the real Telemic driver.
enum SelfTest {
    static func run() -> Int32 {
        func say(_ s: String) { print(s); fflush(stdout) }
        let port: UInt16 = 47_890
        // Leave the real app's settings exactly as they were.
        let domain = Bundle.main.bundleIdentifier ?? "com.peakviber.telemic"
        let savedDefaults = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        defer { UserDefaults.standard.setPersistentDomain(savedDefaults, forName: domain) }

        // Crypto round trip.
        let key = Crypto.sessionKey(peerPublicKey: Identity.publicKey, salt: Crypto.randomSalt())!
        let msg = Data("hello".utf8)
        let sealed = Crypto.seal(msg, key: key, senderID: Identity.deviceID, seq: 7)!
        guard Crypto.open(sealed, key: key, senderID: Identity.deviceID, seq: 7) == msg,
              Crypto.open(sealed, key: key, senderID: Identity.deviceID, seq: 8) == nil else {
            say("FAIL crypto"); return 1
        }
        say("ok   crypto round trip, wrong nonce rejected")

        let receiver = ReceiverEngine(port: port, autoApprove: true)
        var last = ReceiverEngine.Snapshot()
        var lastLive = ReceiverEngine.Live()
        var snapshotChanges = 0
        receiver.onUpdate = { if $0 != last { snapshotChanges += 1 }; last = $0 }
        receiver.onLive = { lastLive = $0 }
        receiver.start()

        let sender = SenderEngine()
        var lastSender = SenderEngine.Snapshot()
        sender.onUpdate = { lastSender = $0 }
        sender.setTarget(Endpoint(host: "127.0.0.1", port: port))
        sender.start()

        // Wait for the handshake.
        let deadline = Date().addingTimeInterval(5)
        while sender.currentLink != .active && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        guard sender.currentLink == .active else { say("FAIL handshake: \(sender.currentLink)"); return 1 }
        say("ok   handshake, link active")
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        guard let rtt = sender.currentRTT else { say("FAIL no round-trip time"); return 1 }
        say("ok   round-trip time measured (\(rtt) ms)")
        guard last.peers.first?.version == .known(AppVersion.current),
              lastSender.receiverVersion == .known(AppVersion.current) else {
            say("FAIL version exchange: \(String(describing: last.peers.first?.version)) / \(lastSender.receiverVersion)"); return 1
        }
        say("ok   versions exchanged both ways (\(AppVersion.current), no mismatch note)")

        // Stream 2 s of 440 Hz in real time.
        snapshotChanges = 0
        var phase = 0.0
        for _ in 0..<100 {
            let chunk = (0..<960).map { _ -> Float in
                phase += 2 * .pi * 440 / Audio.sampleRate
                return 0.3 * Float(sin(phase))
            }
            sender.pushAsync(chunk)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let peer = last.peers.first
        say("info peer=\(peer?.name ?? "-") online=\(peer?.online ?? false) audible=\(peer?.audible ?? false)")
        guard peer?.audible == true else { say("FAIL receiver did not hear the sender"); return 1 }
        say("ok   receiver decrypted and decoded audio")
        // Meters change constantly while audio flows; the structural snapshot (what menus
        // observe) must not, or open submenus get rebuilt and close.
        guard (lastLive.levels[peer!.id] ?? 0) > 0 || lastLive.receiving else { say("FAIL no live levels"); return 1 }
        guard snapshotChanges <= 1 else { say("FAIL snapshot changed \(snapshotChanges)× while streaming"); return 1 }
        say("ok   structural snapshot stayed stable while streaming (\(snapshotChanges) change)")

        // 12 s with 10% random packet loss: redundancy should rebuild almost all of it.
        sender.dropRate = 0.10
        for _ in 0..<600 {
            let chunk = (0..<960).map { _ -> Float in
                phase += 2 * .pi * 440 / Audio.sampleRate
                return 0.3 * Float(sin(phase))
            }
            sender.pushAsync(chunk)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        sender.dropRate = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let loss = last.peers.first.flatMap({ lastLive.loss[$0.id] }) else {
            say("FAIL no loss statistics"); return 1
        }
        let net = loss.network, left = loss.residual
        say(String(format: "info simulated loss: network %.1f%%, after recovery %.2f%%", net * 100, left * 100))
        // The stats window also covers the loss-free warm-up, so `net` lands somewhere in 3–10%.
        guard net > 0.03, left < 0.02 else { say("FAIL loss recovery out of range"); return 1 }
        say("ok   redundancy recovered lost frames")

        sender.setTarget(nil)
        // Clean up the selftest's approval so it doesn't show in the real receiver list.
        if let id = peer?.id { receiver.forget(id) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        receiver.stop()
        sender.stop()
        say("PASS")
        return 0
    }
}
