import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

enum Role: String { case send, receive }

/// Meters and stats that change ~10× a second. Kept out of `AppModel` on purpose:
/// only the level bars and the menu bar icon observe this, so menus (whose open
/// submenus close when SwiftUI rebuilds them) aren't redrawn by every meter tick.
@MainActor
final class LiveStore: ObservableObject {
    @Published var receiver = ReceiverEngine.Live()
    @Published var sender = SenderEngine.Live()
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var role: Role?
    @Published var receiver = ReceiverEngine.Snapshot()
    @Published var sender = SenderEngine.Snapshot()
    @Published var driver: DriverManager.Status = .notInstalled
    @Published var driverBusy = false
    @Published var driverError: String?
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    @Published var inputs: [(uid: String, name: String)] = []
    @Published var copied = false
    @Published var diagnosticsCopied = false
    @Published var telemicIsDefault = false
    @Published var manualAddress = ""
    @Published var manualError = false
    @Published var shortcuts: [HotkeyCenter.Action: Shortcut] = [:]
    @Published var recording: HotkeyCenter.Action?
    @Published var shortcutError: String?

    let live = LiveStore()
    private var receiverEngine: ReceiverEngine?
    private var senderEngine: SenderEngine?
    private let notifier = PendingNotifier()
    private var keyMonitor: Any?

    init() {
        role = UserDefaults.standard.string(forKey: "role").flatMap(Role.init(rawValue:))
        refreshDefaultInput()
        // Follow changes made in System Settings or by other apps.
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.refreshDefaultInput()
        }
        notifier.onDecision = { [weak self] id, ok in self?.decide(id, approve: ok) }
        loadShortcuts()
        HotkeyCenter.shared.handler = { [weak self] action, pressed in self?.hotkey(action, pressed: pressed) }
        Log.info("Telemic \(Self.version) started, role \(role?.rawValue ?? "none")")
        activate()
        Updates.shared.start()
    }

    static var version: String { AppVersion.current }

    // MARK: Role

    func choose(_ r: Role?) {
        guard r != role else { return }
        role = r
        UserDefaults.standard.set(r?.rawValue, forKey: "role")
        Log.info("role \(r?.rawValue ?? "none")")
        activate()
    }

    private func activate() {
        receiverEngine?.stop(); receiverEngine = nil
        senderEngine?.stop(); senderEngine = nil
        applyShortcuts()
        switch role {
        case .receive:
            refreshDriver()
            let e = ReceiverEngine()
            e.onUpdate = { [weak self] s in if self?.receiver != s { self?.receiver = s } }
            e.onLive = { [weak self] l in if self?.live.receiver != l { self?.live.receiver = l } }
            e.onPending = { [weak self] id, name, fp in self?.notifier.post(id: id, name: name, fingerprint: fp) }
            e.start()
            receiverEngine = e
        case .send:
            refreshInputs()
            let e = SenderEngine()
            e.onUpdate = { [weak self] s in if self?.sender != s { self?.sender = s } }
            e.onLive = { [weak self] l in if self?.live.sender != l { self?.live.sender = l } }
            e.start()
            senderEngine = e
            if sender.target == nil { e.discover() }
        case nil:
            break
        }
    }

    // MARK: Receiver

    var receiverAddress: String {
        let host = Tailnet.ownIPv4() ?? Tailnet.lanIPv4() ?? "127.0.0.1"
        return "\(host):\(receiver.port)"
    }

    var receiverAddressKind: String {
        Tailnet.ownIPv4() != nil ? "Tailnet" : (Tailnet.lanIPv4() != nil ? L("局域网", "LAN") : L("本机", "this Mac"))
    }

    func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(receiverAddress, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.copied = false }
    }

    func decide(_ id: UUID, approve: Bool) { receiverEngine?.decide(id, approve: approve) }
    func forget(_ id: UUID) { receiverEngine?.forget(id) }
    func setMode(_ m: ReceiverEngine.Mode) { receiverEngine?.setMode(m) }
    func select(_ id: UUID) { receiverEngine?.select(id) }
    func setMuted(_ id: UUID, _ on: Bool) { receiverEngine?.setMuted(id, on) }
    func setGain(_ id: UUID, _ g: Float) { receiverEngine?.setGain(id, g) }
    func setTailnetOnly(_ on: Bool) { receiverEngine?.setTailnetOnly(on) }

    /// Asks for a new name in a small dialog; an empty name goes back to the sender's own.
    func rename(_ peer: ReceiverEngine.PeerView) {
        let alert = NSAlert()
        alert.messageText = L("重命名「\(peer.name)」", "Rename “\(peer.name)”")
        alert.informativeText = L("只在这台 Mac 上显示。留空则恢复原名。", "Only shown on this Mac. Leave empty to use its own name.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = peer.alias ?? ""
        field.placeholderString = peer.name
        alert.accessoryView = field
        alert.addButton(withTitle: L("保存", "Save"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            receiverEngine?.rename(peer.id, to: field.stringValue)
        }
    }

    func refreshDriver() { driver = DriverManager.status() }
    func installDriver() { runDriverTask(DriverManager.install) }
    func uninstallDriver() { runDriverTask(DriverManager.uninstall) }

    private func runDriverTask(_ task: @escaping () -> String?) {
        driverBusy = true
        driverError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let err = task()
            DispatchQueue.main.async {
                self.driverBusy = false
                self.driverError = err
                Log.info("driver task finished: \(err ?? "ok")")
                self.refreshDriver()
                self.refreshDefaultInput()
            }
        }
    }

    func refreshDefaultInput() {
        telemicIsDefault = AudioDevices.defaultInputUID() == AudioDevices.telemicUID
    }

    func makeTelemicDefault() {
        AudioDevices.setDefaultInput(uid: AudioDevices.telemicUID)
        refreshDefaultInput()
    }

    // MARK: Sender

    func connectManual() {
        guard let e = Endpoint.parse(manualAddress) else { manualError = true; return }
        manualError = false
        manualAddress = ""
        senderEngine?.setTarget(e)
    }

    func connect(_ e: Endpoint) { senderEngine?.setTarget(e) }
    func disconnect() { senderEngine?.setTarget(nil) }
    func setSending(_ on: Bool) { senderEngine?.setSending(on) }
    func discover() { senderEngine?.discover() }
    func trustNewKey() { senderEngine?.trustNewKey() }
    func removeSaved(_ e: Endpoint) { senderEngine?.removeSaved(e) }
    func setVoiceProcessing(_ on: Bool) { senderEngine?.setVoiceProcessing(on) }
    func setInput(_ uid: String?) { senderEngine?.setInput(uid: uid) }
    func refreshInputs() { inputs = AudioDevices.inputs() }

    // MARK: Shortcuts

    private func loadShortcuts() {
        for a in HotkeyCenter.Action.allCases {
            if let d = UserDefaults.standard.data(forKey: "shortcut.\(a.rawValue)"),
               let s = try? JSONDecoder().decode(Shortcut.self, from: d) {
                shortcuts[a] = s
            }
        }
    }

    /// Shortcuts only control the microphone, so they're active in the sender role only.
    private func applyShortcuts() {
        for a in HotkeyCenter.Action.allCases {
            HotkeyCenter.shared.set(role == .send ? shortcuts[a] : nil, for: a)
        }
    }

    func startRecording(_ a: HotkeyCenter.Action) {
        stopRecording()
        recording = a
        shortcutError = nil
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stopRecording(); return nil }          // Esc cancels
            guard let s = Shortcut(event: event) else {
                self.shortcutError = L("请包含 ⌘ ⌥ ⌃ ⇧ 之一，或使用 F1–F19", "Include ⌘ ⌥ ⌃ or ⇧, or use F1–F19")
                return nil
            }
            self.setShortcut(s, for: a)
            self.stopRecording()
            return nil
        }
    }

    func stopRecording() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        recording = nil
    }

    func setShortcut(_ s: Shortcut?, for a: HotkeyCenter.Action) {
        if let s, shortcuts.contains(where: { $0.key != a && $0.value == s }) {
            shortcutError = L("这个快捷键已经用于另一个操作", "That shortcut is already used for the other action")
            return
        }
        if role == .send, !HotkeyCenter.shared.set(s, for: a) {
            shortcutError = L("\(s?.display ?? "") 已被其他应用占用", "\(s?.display ?? "") is taken by another app")
            HotkeyCenter.shared.set(shortcuts[a], for: a)
            return
        }
        shortcuts[a] = s
        UserDefaults.standard.set(s.flatMap { try? JSONEncoder().encode($0) }, forKey: "shortcut.\(a.rawValue)")
    }

    private func hotkey(_ a: HotkeyCenter.Action, pressed: Bool) {
        guard role == .send else { return }
        switch a {
        case .toggleMic: if pressed { setSending(!sender.switchOn) }
        case .pushToTalk: senderEngine?.setPushToTalk(pressed)
        }
    }

    // MARK: Diagnostics

    func copyDiagnostics() {
        var lines: [String] = []
        // Built from numbers: operatingSystemVersionString is localized.
        let v = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("Telemic \(Self.version) · macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) · \(Identity.name)")
        lines.append("role: \(role?.rawValue ?? "none")")
        lines.append("tailnet ip: \(Tailnet.ownIPv4() ?? "-") · lan ip: \(Tailnet.lanIPv4() ?? "-")")
        lines.append("device fingerprint: \(Crypto.fingerprint(Identity.publicKey))")
        switch role {
        case .receive:
            lines.append("driver: \(driver) · default input is Telemic: \(telemicIsDefault)")
            lines.append("listening: \(receiver.listening) · error: \(receiver.error ?? "-") · mode: \(receiver.mode.rawValue) · tailnet only: \(receiver.tailnetOnly)")
            for p in receiver.peers {
                let l = live.receiver.loss[p.id]
                let loss = l.map { String(format: "%.1f%%", $0.network * 100) } ?? "-"
                let left = l.map { String(format: "%.1f%%", $0.residual * 100) } ?? "-"
                let buffer = live.receiver.bufferMs[p.id].map { "\($0)ms" } ?? "-"
                lines.append("  sender \(p.displayName) [\(p.fingerprint)] \(p.endpoint) approval=\(p.approval?.rawValue ?? "pending") online=\(p.online) audible=\(p.audible) muted=\(p.muted) gain=\(p.gain) buffer=\(buffer) loss=\(loss)→\(left)")
            }
        case .send:
            lines.append("target: \(sender.target?.description ?? "-") (\(sender.receiverName ?? "-")) link=\(sender.link) rtt=\(live.sender.rttMs.map { "\($0)ms" } ?? "-")")
            lines.append("mic on: \(sender.sending) · voice processing: \(sender.voiceProcessing) · input: \(sender.inputUID ?? "default") · mic denied: \(sender.micDenied)")
            lines.append("warning: \(sender.warning ?? "-")")
        case nil:
            break
        }
        lines.append("--- recent log ---")
        lines += Log.recent()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        diagnosticsCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.diagnosticsCopied = false }
    }

    // MARK: Panel

    /// One line in the header that says what's going on.
    var statusTitle: String {
        switch role {
        case nil:
            return L("设置 Telemic", "Set up Telemic")
        case .receive:
            guard case .ready = driver else { return L("需要设置", "Setup needed") }
            let approved = receiver.peers.filter { $0.approval == .approved }
            if approved.isEmpty { return L("等待发送端", "Waiting for a sender") }
            if !approved.contains(where: \.online) { return L("没有在线的发送端", "No sender online") }
            let live = approved.filter { $0.online && $0.audible }.count
            if receiver.mode == .mix, live > 1 { return L("正在接收 \(live) 台", "Receiving \(live) senders") }
            return L("正在接收", "Receiving")
        case .send:
            guard let target = sender.target else { return L("选择接收端", "Choose a receiver") }
            let name = sender.receiverName ?? target.host
            switch sender.link {
            case .connecting, .noTarget: return L("正在连接 \(name)…", "Connecting to \(name)…")
            case .pending: return L("等待 \(name) 允许", "Waiting for \(name) to allow")
            case .standby: return L("\(name) 在听另一台", "\(name) is listening to another Mac")
            case .denied: return L("被 \(name) 拒绝", "Denied by \(name)")
            case .keyChanged: return L("\(name) 的密钥变了", "\(name)'s key changed")
            case .active: return sender.sending ? L("正在发送到 \(name)", "Sending to \(name)") : L("已连接 \(name)", "Connected to \(name)")
            }
        }
    }

    var oppositeRole: Role? {
        switch role {
        case .send: return .receive
        case .receive: return .send
        case nil: return nil
        }
    }

    /// Switching stops whatever this Mac is doing, so ask first.
    func confirmSwitch(to r: Role) {
        let alert = NSAlert()
        if r == .send {
            alert.messageText = L("把这台 Mac 切换为发送端？", "Switch this Mac to Sender?")
            alert.informativeText = L("接收会停止，连到这台 Mac 的发送端将听不到。", "Receiving stops; senders connected to this Mac won't be heard.")
        } else {
            alert.messageText = L("把这台 Mac 切换为接收端？", "Switch this Mac to Receiver?")
            alert.informativeText = L("这台 Mac 会停止发送麦克风。", "This Mac stops sending its microphone.")
        }
        alert.addButton(withTitle: L("切换", "Switch"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { choose(r) }
    }

    private var shortcutsWindow: NSWindow?

    func openShortcuts() {
        if shortcutsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ShortcutsView().environmentObject(self)))
            w.title = L("Telemic 快捷键", "Telemic Shortcuts")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            shortcutsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        shortcutsWindow?.makeKeyAndOrderFront(nil)
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: App

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func quit() {
        receiverEngine?.stop()
        senderEngine?.stop()
        NSApp.terminate(nil)
    }

    /// Menu bar icon; `receiving` comes from the live store (only the label observes it).
    func menuIcon(receiving: Bool) -> String {
        switch role {
        case nil: return "mic.badge.plus"
        case .send:
            if sender.target == nil { return "mic.slash" }
            switch sender.link {
            case .connecting, .denied, .keyChanged, .noTarget: return "exclamationmark.triangle"
            case .pending, .standby: return sender.sending ? "mic" : "mic.slash"
            case .active: return sender.sending ? "mic.fill" : "mic.slash"
            }
        case .receive:
            if receiver.error != nil { return "exclamationmark.triangle" }
            if case .ready = driver {} else { return "exclamationmark.triangle" }
            if receiver.peers.contains(where: { $0.approval == nil && $0.online }) { return "person.crop.circle.badge.questionmark" }
            return receiving ? "waveform" : "ear"
        }
    }
}
