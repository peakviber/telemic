import AppKit
import ServiceManagement

/// One-time move from the app's old name, RemoteMic (com.remotemic.app), to Telemic.
/// Carries the settings over (role, approved senders, pinned receivers, device ID, shortcuts),
/// quits a still-running RemoteMic so the port is free, moves the old app to the Trash, and
/// keeps "Open at login". The identity key and the driver are handled by `Identity` and
/// `DriverManager`.
enum LegacyMigration {
    static let legacyBundleID = "com.remotemic.app"
    private static let doneKey = "migratedFromRemoteMic"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard let old = defaults.persistentDomain(forName: legacyBundleID), !old.isEmpty else { return }

        // Settings: only if this is a fresh Telemic (never overwrite its own choices).
        if defaults.string(forKey: "deviceID") == nil {
            // Sparkle's own bookkeeping (SU…) starts fresh for the new app.
            for (k, v) in old where !k.hasPrefix("SU") && !k.hasPrefix("NS") { defaults.set(v, forKey: k) }
            Log.info("settings carried over from RemoteMic")
        }

        // A running RemoteMic holds the UDP port and the driver socket; ask it to quit.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID)
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline { usleep(100_000) }

        // The old app would otherwise start at login too and fight over the port.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: legacyBundleID),
           url.path != Bundle.main.bundlePath {
            NSWorkspace.shared.recycle([url]) { _, err in
                Log.info(err == nil ? "moved RemoteMic.app to the Trash" : "couldn't trash RemoteMic.app: \(err!.localizedDescription)")
            }
        }

        // RemoteMic most likely opened at login (it's a menu bar app); keep that behaviour.
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
    }
}
