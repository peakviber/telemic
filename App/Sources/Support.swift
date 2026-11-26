import Foundation
import os

/// UI language: Chinese when the user's first preferred language is Chinese, English otherwise.
let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
func L(_ zh: String, _ en: String) -> String { isChinese ? zh : en }

/// Unified logging plus the last 200 lines in memory for "Copy diagnostics".
enum Log {
    private static let logger = Logger(subsystem: "com.remotemic.app", category: "app")
    private static let lock = NSLock()
    private static var lines: [String] = []
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let line = "\(clock.string(from: Date())) \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        lock.unlock()
    }

    static func recent() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}

/// Token bucket per source IPv4 address.
struct RateLimiter {
    let perSecond: Double
    let burst: Double
    private var buckets: [UInt32: (tokens: Double, at: TimeInterval)] = [:]

    init(perSecond: Double, burst: Double) {
        self.perSecond = perSecond
        self.burst = burst
    }

    mutating func allow(_ ip: UInt32, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if buckets.count > 1_000 { buckets = buckets.filter { now - $0.value.at < 60 } }
        var b = buckets[ip] ?? (burst, now)
        b.tokens = min(burst, b.tokens + (now - b.at) * perSecond)
        b.at = now
        let ok = b.tokens >= 1
        if ok { b.tokens -= 1 }
        buckets[ip] = b
        return ok
    }
}

extension sockaddr_in {
    var ipv4: UInt32 { UInt32(bigEndian: sin_addr.s_addr) }
    /// Tailscale's 100.64.0.0/10, or loopback.
    var isTailnetOrLoopback: Bool { (ipv4 & 0xFFC0_0000) == 0x6440_0000 || (ipv4 >> 24) == 127 }
}

enum AppVersion {
    /// The running app's version; "0.0" outside a bundle (unit tests), which no release uses.
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
}
