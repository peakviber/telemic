import AppKit
import Sparkle

/// Sparkle auto-update. Only signed releases update themselves: an ad-hoc (self-built)
/// copy is left alone, so a developer's build is never replaced by a download.
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?

    var available: Bool { controller != nil }

    func start() {
        guard controller == nil, Signing.teamID != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// The user's "check automatically" choice (stored by Sparkle in our defaults; the
    /// Info.plist only sets the default, on).
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)   // menu bar app: bring Sparkle's window forward
        controller?.checkForUpdates(nil)
    }

    // A menu bar app has no window of its own to interrupt; let Sparkle show scheduled
    // updates gently instead of warning about background apps.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
