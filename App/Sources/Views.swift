import SwiftUI

// Layout rule: the panel shows state plus the one main action. Settings live in the ⋯ menu,
// and diagnostics or warnings appear only when something actually needs attention.

struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderBar()
            switch model.role {
            case nil: RolePicker()
            case .send: SenderView()
            case .receive: ReceiverView()
            }
            if let err = model.loginError { Text(err).font(.caption).foregroundStyle(.red) }
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - Header

struct HeaderBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.role == .send ? "mic.fill" : (model.role == .receive ? "ear" : "mic.badge.plus"))
                .font(.system(size: 15))
                .frame(width: 18)
            // Long Mac names wrap onto a second line instead of being cut off.
            Text(model.statusTitle).font(.headline).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(model.statusTitle)
            Spacer()
            MoreMenu()
        }
    }
}

struct MoreMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            switch model.role {
            case .receive: receiverItems
            case .send: senderItems
            case nil: EmptyView()
            }
            Toggle(L("开机自动打开", "Open at login"),
                   isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            if let other = model.oppositeRole {
                Button(other == .send ? L("切换为发送端…", "Switch to Sender…") : L("切换为接收端…", "Switch to Receiver…")) {
                    model.confirmSwitch(to: other)
                }
            }
            Divider()
            Button(L("复制诊断信息", "Copy diagnostics")) { model.copyDiagnostics() }
            if Updates.shared.available {
                Button(L("检查更新…", "Check for Updates…")) { Updates.shared.checkNow() }
                Toggle(L("自动检查更新", "Check for Updates Automatically"),
                       isOn: Binding(get: { Updates.shared.automaticallyChecks },
                                     set: { Updates.shared.automaticallyChecks = $0 }))
            }
            Text("Telemic \(AppModel.version)")
            Divider()
            Button(L("退出", "Quit")) { model.quit() }.keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("更多", "More"))
    }

    @ViewBuilder private var receiverItems: some View {
        Button(L("复制本机地址（\(model.receiverAddress)）", "Copy address (\(model.receiverAddress))")) { model.copyAddress() }
        Toggle(L("只接受 Tailnet 上的设备", "Only accept devices on the Tailnet"),
               isOn: Binding(get: { model.receiver.tailnetOnly }, set: { model.setTailnetOnly($0) }))
        if case .ready(let v) = model.driver {
            Menu(L("驱动", "Driver")) {
                Text(L("Telemic 驱动 \(v)", "Telemic driver \(v)"))
                Button(L("重新安装", "Reinstall")) { model.installDriver() }
                Button(L("卸载", "Uninstall")) { model.uninstallDriver() }
            }
        }
        Divider()
    }

    @ViewBuilder private var senderItems: some View {
        if model.sender.target != nil {
            Menu(L("接收端", "Receiver")) {
                ForEach(model.sender.saved) { s in
                    Button((s.endpoint == model.sender.target ? "✓ " : "") + "\(s.name) · \(s.endpoint.description)") {
                        model.connect(s.endpoint)
                    }
                }
                Divider()
                Button(L("连接其他接收端…", "Connect to another…")) { model.disconnect() }
            }
        }
        Picker(L("输入设备", "Input"), selection: Binding(get: { model.sender.inputUID ?? "" },
                                                          set: { model.setInput($0.isEmpty ? nil : $0) })) {
            Text(L("系统默认", "System default")).tag("")
            ForEach(model.inputs, id: \.uid) { Text($0.name).tag($0.uid) }
        }
        Toggle(L("语音增强（降噪 / 回声消除）", "Voice enhancement (noise / echo)"),
               isOn: Binding(get: { model.sender.voiceProcessing }, set: { model.setVoiceProcessing($0) }))
        Button(L("快捷键…", "Shortcuts…")) { model.openShortcuts() }
        Divider()
    }
}

// MARK: - Role picker (first run)

struct RolePicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoleButton(icon: "mic.fill", title: L("发送", "Send"),
                       detail: L("把这台 Mac 的麦克风送到另一台 Mac", "Send this Mac's microphone to another Mac")) { model.choose(.send) }
            RoleButton(icon: "ear", title: L("接收", "Receive"),
                       detail: L("把收到的声音变成这台 Mac 的 Telemic 麦克风", "Turn incoming audio into this Mac's Telemic microphone")) { model.choose(.receive) }
        }
    }
}

struct RoleButton: View {
    let icon: String, title: String, detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title2).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Receiver

struct ReceiverView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let approved = model.receiver.peers.filter { $0.approval == .approved }
        let online = approved.filter(\.online)
        let offline = approved.filter { !$0.online }
        let pending = model.receiver.peers.filter { $0.approval == nil && $0.online }

        VStack(alignment: .leading, spacing: 10) {
            // Things that need the user, each with its fix.
            DriverSection()
            if case .ready = model.driver, !model.telemicIsDefault {
                Notice(icon: "exclamationmark.triangle.fill", text: L("Telemic 不是系统默认输入", "Telemic isn't the default input"),
                       button: L("修复", "Fix")) { model.makeTelemicDefault() }
            }
            if let err = model.receiver.error {
                Notice(icon: "exclamationmark.triangle.fill", text: err)
            }
            ForEach(pending) { p in PendingCard(peer: p) }

            if approved.isEmpty {
                EmptyReceiver()
            } else {
                if approved.count >= 2 {
                    Picker("", selection: Binding(get: { model.receiver.mode }, set: { model.setMode($0) })) {
                        Text(L("只听一台", "One")).tag(ReceiverEngine.Mode.single)
                        Text(L("混合全部", "Mix all")).tag(ReceiverEngine.Mode.mix)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                VStack(spacing: 2) {
                    ForEach(online) { p in SenderRow(peer: p, count: approved.count) }
                    ForEach(offline) { p in OfflineRow(peer: p) }
                }
            }
        }
    }
}

struct EmptyReceiver: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("在另一台 Mac 上选择「发送」并选中这台 Mac，或输入：",
                   "On your other Mac, choose Send and pick this Mac, or enter:"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(model.receiverAddress).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button(model.copied ? L("已复制", "Copied") : L("复制", "Copy")) { model.copyAddress() }
            }
        }
    }
}

struct DriverSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.driver {
        case .ready:
            EmptyView()
        case .notInstalled:
            DriverPrompt(text: L("需要安装 Telemic 虚拟麦克风驱动（会请求管理员密码）。",
                                 "Telemic needs its virtual microphone driver (asks for an administrator password)."),
                         button: L("安装驱动", "Install driver"))
        case .outdated(let installed, let bundled):
            DriverPrompt(text: L("驱动需要更新（\(installed) → \(bundled)）。", "Driver update available (\(installed) → \(bundled))."),
                         button: L("更新驱动", "Update driver"))
        case .installedButNotLoaded:
            DriverPrompt(text: L("驱动已安装但没有加载。重新安装会重启声音服务。",
                                 "The driver is installed but not loaded. Reinstalling restarts the audio service."),
                         button: L("重新安装", "Reinstall"))
        }
    }
}

struct DriverPrompt: View {
    @EnvironmentObject var model: AppModel
    let text: String, button: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.caption)
            HStack {
                Button(button) { model.installDriver() }.disabled(model.driverBusy)
                if model.driverBusy { ProgressView().controlSize(.small) }
            }
            if let err = model.driverError { Text(err).font(.caption).foregroundStyle(.red) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
    }
}

/// A one-line warning with an optional fix button.
struct Notice: View {
    let icon: String
    let text: String
    var button: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(text).font(.caption)
            Spacer()
            if let button { Button(button, action: action).controlSize(.small) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

struct PendingCard: View {
    @EnvironmentObject var model: AppModel
    let peer: ReceiverEngine.PeerView

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("\(peer.displayName) 请求连接", "\(peer.displayName) wants to connect")).font(.callout.weight(.medium))
            Text(L("指纹 \(peer.fingerprint)", "Fingerprint \(peer.fingerprint)")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("允许", "Allow")) { model.decide(peer.id, approve: true) }.keyboardShortcut(.defaultAction)
                Button(L("拒绝", "Deny")) { model.decide(peer.id, approve: false) }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
    }
}

struct SenderRow: View {
    @EnvironmentObject var model: AppModel
    let peer: ReceiverEngine.PeerView
    let count: Int          // approved senders, online or not

    private var choosing: Bool { count >= 2 && model.receiver.mode == .single }
    private var selected: Bool { model.receiver.selected == peer.id }
    /// Muting matters when mixing, or when there's only one sender to silence.
    private var showsMute: Bool { model.receiver.mode == .mix || count == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if choosing {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .opacity(selected ? 1 : 0)
                        .frame(width: 14)
                }
                Text(peer.displayName)
                    .lineLimit(1)
                    .foregroundStyle(peer.audible || choosing ? Color.primary : Color.secondary)
                if let note = peer.version.note(ours: AppModel.version) {
                    VersionBadge(note: note)
                }
                Spacer()
                if choosing, selected {
                    Text(L("正在收听", "listening")).font(.caption).foregroundStyle(.secondary)
                }
                if showsMute {
                    Button {
                        model.setMuted(peer.id, !peer.muted)
                    } label: {
                        Image(systemName: peer.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(peer.muted ? Color.secondary : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(peer.muted ? L("取消静音", "Unmute") : L("静音", "Mute"))
                }
            }
            // Non-selected senders still show their level, so you can see who's talking.
            PeerMeter(id: peer.id, active: peer.audible)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(choosing && selected ? Color.primary.opacity(0.06) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { if choosing { model.select(peer.id) } }
        .help(choosing && !selected ? L("点击改为收听这一台", "Click to listen to this one") : "")
        .contextMenu { SenderContextMenu(peer: peer) }
    }
}

struct OfflineRow: View {
    let peer: ReceiverEngine.PeerView

    var body: some View {
        HStack {
            Text(peer.displayName).lineLimit(1)
            Spacer()
            Text(L("离线", "offline")).font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .contextMenu { SenderContextMenu(peer: peer) }
    }
}

struct SenderContextMenu: View {
    @EnvironmentObject var model: AppModel
    let peer: ReceiverEngine.PeerView

    var body: some View {
        Picker(L("音量", "Volume"), selection: Binding(get: { Int((peer.gain * 100).rounded()) },
                                                       set: { model.setGain(peer.id, Float($0) / 100) })) {
            ForEach([50, 75, 100, 125, 150, 200], id: \.self) { Text("\($0)%").tag($0) }
        }
        Button(L("重命名…", "Rename…")) { model.rename(peer) }
        Divider()
        Text(L("指纹 \(peer.fingerprint)", "Fingerprint \(peer.fingerprint)"))
        Text(peer.endpoint)
        if peer.alias != nil { Text(L("原名：\(peer.name)", "Own name: \(peer.name)")) }
        Divider()
        Button(L("移除并撤销授权", "Remove and revoke")) { model.forget(peer.id) }
    }
}

// MARK: - Sender

struct SenderView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.sender.target != nil {
                ConnectedSection()
            } else {
                ReceiverPicker()
            }
        }
    }
}

struct ConnectedSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Problems first, each with its fix.
            switch model.sender.link {
            case .keyChanged:
                Notice(icon: "exclamationmark.shield.fill",
                       text: L("接收端的密钥变了。刚重装过接收端才可信任。", "The receiver's key changed. Trust it only if you just reinstalled it."),
                       button: L("信任", "Trust")) { model.trustNewKey() }
            case .denied:
                Notice(icon: "xmark.octagon.fill", text: L("接收端拒绝了这台 Mac", "The receiver denied this Mac"))
            default:
                EmptyView()
            }
            if model.sender.micDenied {
                Notice(icon: "mic.slash.fill",
                       text: L("没有麦克风权限", "No microphone access"),
                       button: L("打开设置", "Open Settings")) { model.openMicrophoneSettings() }
            }
            if let w = model.sender.warning { Notice(icon: "exclamationmark.triangle.fill", text: w) }

            Button {
                model.setSending(!model.sender.switchOn)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.sender.switchOn ? "mic.fill" : "mic.slash")
                    Text(model.sender.switchOn ? L("麦克风已开启", "Microphone on") : L("麦克风已关闭", "Microphone off"))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(model.sender.switchOn ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))

            SenderMeter(on: model.sender.sending, active: model.sender.link == .active)
            if let note = model.sender.receiverVersion.note(ours: AppModel.version) {
                HStack(spacing: 4) {
                    VersionBadge(note: note)
                    Text(L("· 本机 \(AppModel.version)", "· this Mac \(AppModel.version)"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ReceiverPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let found = model.sender.discovered.filter { d in !model.sender.saved.contains { $0.endpoint == d.endpoint } }
            if !model.sender.saved.isEmpty {
                TitledSection(title: L("最近连接", "Recent")) {
                    ForEach(model.sender.saved) { s in
                        ReceiverButton(name: s.name, endpoint: s.endpoint)
                            .contextMenu { Button(L("从列表移除", "Remove from list")) { model.removeSaved(s.endpoint) } }
                    }
                }
            }
            TitledSection(title: L("附近的接收端", "Nearby receivers"), trailing: AnyView(
                HStack(spacing: 6) {
                    if model.sender.discovering { ProgressView().controlSize(.small) }
                    Button { model.discover() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help(L("重新搜索", "Search again"))
                })) {
                if found.isEmpty && !model.sender.discovering {
                    Text(L("没有找到。确认接收端已打开，或在下面输入地址。", "None found. Make sure a receiver is running, or enter its address below."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(found) { d in ReceiverButton(name: d.name, endpoint: d.endpoint) }
            }
            HStack {
                TextField("100.64.0.10:47810", text: $model.manualAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.connectManual() }
                Button(L("连接", "Connect")) { model.connectManual() }
            }
            if model.manualError { Text(L("地址格式不对", "That address doesn't look right")).font(.caption).foregroundStyle(.red) }
        }
    }
}

struct TitledSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let trailing { trailing }
            }
            content
        }
    }
}

struct ReceiverButton: View {
    @EnvironmentObject var model: AppModel
    let name: String
    let endpoint: Endpoint

    var body: some View {
        Button {
            model.connect(endpoint)
        } label: {
            HStack {
                Text(name)
                Spacer()
                Text(endpoint.host).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Shortcuts window

struct ShortcutsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShortcutRow(action: .toggleMic, title: L("开关麦克风", "Toggle microphone"))
            ShortcutRow(action: .pushToTalk, title: L("按住说话", "Hold to talk"))
            if let e = model.shortcutError { Text(e).font(.caption).foregroundStyle(.red) }
            Text(L("快捷键在这台 Mac 作为发送端时全局生效。", "Shortcuts work everywhere while this Mac is a sender."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 340)
    }
}

struct ShortcutRow: View {
    @EnvironmentObject var model: AppModel
    let action: HotkeyCenter.Action
    let title: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if model.recording == action {
                Text(L("按下组合键…（Esc 取消）", "Press keys… (Esc cancels)")).foregroundStyle(.secondary)
            } else {
                Button(model.shortcuts[action]?.display ?? L("设置", "Set")) { model.startRecording(action) }
                if model.shortcuts[action] != nil {
                    Button {
                        model.setShortcut(nil, for: action)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("清除", "Clear"))
                }
            }
        }
    }
}

// MARK: - Live meters
//
// These are the only views that observe `LiveStore` (10 updates a second). Everything
// else, menus included, observes `AppModel`, which changes only on real events.

struct PeerMeter: View {
    @EnvironmentObject var live: LiveStore
    let id: UUID
    let active: Bool

    var body: some View {
        LevelBar(level: live.receiver.levels[id] ?? 0, active: active)
        if let left = live.receiver.loss[id]?.residual, left > 0.02 {
            Text(L(String(format: "声音断续：补偿后仍丢失 %.0f%%", left * 100),
                   String(format: "Choppy audio: %.0f%% still lost after recovery", left * 100)))
                .font(.caption2).foregroundStyle(.orange)
        }
    }
}

struct SenderMeter: View {
    @EnvironmentObject var live: LiveStore
    let on: Bool
    let active: Bool

    var body: some View {
        LevelBar(level: on ? live.sender.level : 0, active: active)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveStore

    var body: some View {
        Image(systemName: model.menuIcon(receiving: live.receiver.receiving))
    }
}

// MARK: - Shared

struct LevelBar: View {
    let level: Float
    var active = true

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(active ? (level > 0.85 ? Color.orange : Color.green) : Color.secondary.opacity(0.5))
                    .frame(width: g.size.width * CGFloat(level))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.1), value: level)
    }
}

/// Shown next to the other Mac when its Telemic version differs from ours.
struct VersionBadge: View {
    let note: String
    var body: some View {
        Label(note, systemImage: "arrow.triangle.2.circlepath")
            .font(.caption2)
            .foregroundStyle(.orange)
            .help(L("两台 Mac 的 Telemic 版本不同，建议都更新到最新版", "The two Macs run different Telemic versions; update both to the latest"))
    }
}
