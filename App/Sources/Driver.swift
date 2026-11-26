import CoreAudio
import Foundation

enum AudioDevices {
    static let telemicUID = "Telemic_Device_UID"
    static let legacyUID = "RemoteMic_Device_UID"

    static func deviceID(uid: String) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &dev)
        }
        return err == noErr && dev != kAudioObjectUnknown ? dev : nil
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    /// Input-capable devices as (uid, name), excluding Telemic itself.
    static func inputs() -> [(uid: String, name: String)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids.compactMap { id in
            var cfg = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &cfg, 0, nil, &s) == noErr, s > 0 else { return nil }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(s), alignment: 16)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &cfg, 0, nil, &s, raw) == noErr else { return nil }
            let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            guard abl.reduce(0, { $0 + Int($1.mNumberChannels) }) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), uid != telemicUID, uid != legacyUID,
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return (uid, name)
        }
    }

    static func defaultInputUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr
        else { return nil }
        return string(dev, kAudioDevicePropertyDeviceUID)
    }

    static func setDefaultInput(uid: String) {
        guard var dev = deviceID(uid: uid) else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &dev)
    }
}

/// Installs the Telemic HAL plug-in bundled inside the app.
enum DriverManager {
    enum Status: Equatable {
        case notInstalled
        case outdated(installed: String, bundled: String)
        case installedButNotLoaded
        case ready(version: String)
    }

    static let installPath = "/Library/Audio/Plug-Ins/HAL/Telemic.driver"
    /// The driver from the RemoteMic days; replaced (removed) when Telemic's is installed.
    static let legacyPath = "/Library/Audio/Plug-Ins/HAL/RemoteMic.driver"
    static var bundledURL: URL? { Bundle.main.url(forResource: "Telemic", withExtension: "driver") }

    static func version(at url: URL) -> String? {
        (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    static func status() -> Status {
        guard let installed = version(at: URL(fileURLWithPath: installPath)) else { return .notInstalled }
        if let bundled = bundledURL.flatMap(version(at:)), bundled != installed {
            return .outdated(installed: installed, bundled: bundled)
        }
        return AudioDevices.deviceID(uid: AudioDevices.telemicUID) == nil ? .installedButNotLoaded : .ready(version: installed)
    }

    /// Asks for an administrator password, copies the plug-in, restarts Core Audio,
    /// waits for the device, and puts the user's default input back. Returns an error message.
    static func install() -> String? {
        guard let src = bundledURL else { return "应用里没有找到驱动" }
        let previousInput = AudioDevices.defaultInputUID()
        let cmd = "rm -rf \(q(installPath)) \(q(legacyPath)) && cp -R \(q(src.path)) \(q(installPath)) && chown -R root:wheel \(q(installPath)) && killall coreaudiod"
        if let err = runAsAdmin(cmd) { return err }
        for _ in 0..<40 {   // up to 10 s
            if AudioDevices.deviceID(uid: AudioDevices.telemicUID) != nil { break }
            usleep(250_000)
        }
        guard AudioDevices.deviceID(uid: AudioDevices.telemicUID) != nil else { return "驱动已安装，但 Telemic 设备没有出现" }
        // Core Audio may make a newly added device the default input; undo that.
        if previousInput == AudioDevices.legacyUID {
            // RemoteMic was the default input; Telemic takes its place.
            AudioDevices.setDefaultInput(uid: AudioDevices.telemicUID)
        } else if let prev = previousInput, prev != AudioDevices.telemicUID, AudioDevices.defaultInputUID() != prev {
            AudioDevices.setDefaultInput(uid: prev)
        }
        return nil
    }

    static func uninstall() -> String? {
        runAsAdmin("rm -rf \(q(installPath)) \(q(legacyPath)) && killall coreaudiod")
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func runAsAdmin(_ shell: String) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return error.localizedDescription }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return msg.contains("-128") ? "已取消" : (msg.isEmpty ? "安装失败" : msg)
        }
        return nil
    }
}
