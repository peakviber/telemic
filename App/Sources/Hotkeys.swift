import AppKit
import Carbon.HIToolbox
import UserNotifications

/// A global keyboard shortcut (Carbon hot keys: no Accessibility permission needed).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32      // Carbon modifier flags
    var display: String

    /// Builds a shortcut from a key press; needs at least one modifier unless it's a function key.
    init?(event: NSEvent) {
        let f = event.modifierFlags
        var m: UInt32 = 0
        var label = ""
        if f.contains(.control) { m |= UInt32(controlKey); label += "⌃" }
        if f.contains(.option) { m |= UInt32(optionKey); label += "⌥" }
        if f.contains(.shift) { m |= UInt32(shiftKey); label += "⇧" }
        if f.contains(.command) { m |= UInt32(cmdKey); label += "⌘" }
        let code = Int(event.keyCode)
        let functionKeys: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
            kVK_F19: "F19",
        ]
        let named: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        if let fk = functionKeys[code] {
            label += fk
        } else {
            guard m != 0 else { return nil }
            label += named[code] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
        keyCode = UInt32(code)
        modifiers = m
        display = label
    }
}

final class HotkeyCenter {
    enum Action: UInt32, CaseIterable { case toggleMic = 1, pushToTalk = 2 }

    static let shared = HotkeyCenter()
    /// (action, pressed): pressed is false when the key is released.
    var handler: ((Action, Bool) -> Void)?
    private var refs: [Action: EventHotKeyRef] = [:]
    private var installed = false

    /// Registers `shortcut` for `action`, replacing any previous one. Returns false if
    /// another app already owns that combination.
    @discardableResult
    func set(_ shortcut: Shortcut?, for action: Action) -> Bool {
        if let r = refs.removeValue(forKey: action) { UnregisterEventHotKey(r) }
        guard let s = shortcut else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x524D_4943), id: action.rawValue)   // 'RMIC'
        let err = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard err == noErr, let ref else { return false }
        refs[action] = ref
        return true
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            if let a = HotkeyCenter.Action(rawValue: hk.id) {
                DispatchQueue.main.async { HotkeyCenter.shared.handler?(a, pressed) }
            }
            return noErr
        }, types.count, &types, nil, nil)
    }
}

/// "Sender X wants to connect" with Allow / Deny right in the notification.
final class PendingNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let category = "remotemic.pending"
    var onDecision: ((UUID, Bool) -> Void)?
    private var authorized = false

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: "allow", title: L("允许", "Allow"), options: [])
        let deny = UNNotificationAction(identifier: "deny", title: L("拒绝", "Deny"), options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [allow, deny],
                                                                 intentIdentifiers: [], options: [])])
    }

    func post(id: UUID, name: String, fingerprint: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = L("\(name) 请求连接", "\(name) wants to connect")
            c.body = L("指纹 \(fingerprint)。允许后它的声音会进入 RemoteMic。",
                       "Fingerprint \(fingerprint). If allowed, its audio goes into RemoteMic.")
            c.sound = .default
            c.categoryIdentifier = Self.category
            c.userInfo = ["id": id.uuidString]
            center.add(UNNotificationRequest(identifier: id.uuidString, content: c, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        defer { done() }
        guard let s = response.notification.request.content.userInfo["id"] as? String, let id = UUID(uuidString: s) else { return }
        switch response.actionIdentifier {
        case "allow": DispatchQueue.main.async { self.onDecision?(id, true) }
        case "deny": DispatchQueue.main.async { self.onDecision?(id, false) }
        default: break      // clicked the banner: the menu shows the request
        }
    }
}
