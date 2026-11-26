import Foundation

struct TailnetPeer {
    var hostName: String
    var dnsName: String
    var ip: String
    var os: String
    var online: Bool
}

enum Tailnet {
    /// This Mac's Tailscale IPv4 (100.64.0.0/10), read from the network interfaces.
    static func ownIPv4() -> String? {
        interfaceIPv4s().first { isTailscale($0.ip) }?.ip
    }

    /// Best LAN IPv4 (en* first), skipping Tailscale, link-local and proxy fake-IP ranges.
    static func lanIPv4() -> String? {
        let candidates = interfaceIPv4s().filter {
            !isTailscale($0.ip) && !$0.ip.hasPrefix("169.254.") && !$0.ip.hasPrefix("127.") && !$0.ip.hasPrefix("198.18.") && !$0.ip.hasPrefix("198.19.")
        }
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.ip
    }

    /// Peers from the Tailscale LocalAPI (open-source tailscaled socket) or the Tailscale CLI.
    static func peers() -> [TailnetPeer] {
        guard let json = localAPIStatus() ?? cliStatus(),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let peerMap = root["Peer"] as? [String: [String: Any]] else { return [] }
        return peerMap.values.compactMap { p in
            guard let ips = p["TailscaleIPs"] as? [String], let v4 = ips.first(where: { !$0.contains(":") }) else { return nil }
            let dns = (p["DNSName"] as? String ?? "").split(separator: ".").first.map(String.init) ?? ""
            return TailnetPeer(hostName: p["HostName"] as? String ?? dns, dnsName: dns, ip: v4,
                               os: p["OS"] as? String ?? "", online: p["Online"] as? Bool ?? false)
        }
    }

    // MARK: - Private

    private static func isTailscale(_ ip: String) -> Bool {
        var a = in_addr()
        guard inet_pton(AF_INET, ip, &a) == 1 else { return false }
        return (UInt32(bigEndian: a.s_addr) & 0xFFC0_0000) == 0x6440_0000
    }

    private static func interfaceIPv4s() -> [(name: String, ip: String)] {
        var result: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var p = head
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            result.append((String(cString: ifa.pointee.ifa_name), String(cString: buf)))
        }
        return result
    }

    /// Open-source tailscaled sockets (the CLI package uses .sock, a plain `tailscaled` uses .socket).
    private static let socketPaths = ["/var/run/tailscaled.sock", "/var/run/tailscaled.socket"]

    private static func localAPIStatus() -> Data? {
        for path in socketPaths where FileManager.default.fileExists(atPath: path) {
            if let d = localAPIStatus(path: path) { return d }
        }
        return nil
    }

    private static func localAPIStatus(path: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strncpy($0, path, 103) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        let req = "GET /localapi/v0/status HTTP/1.0\r\nHost: local-tailscaled.sock\r\n\r\n"
        _ = req.withCString { write(fd, $0, strlen($0)) }
        var resp = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            resp.append(contentsOf: buf[0..<n])
        }
        guard let sep = resp.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return resp.subdata(in: sep.upperBound..<resp.count)
    }

    /// Standalone and App Store Tailscale apps ship their CLI inside the bundle; Homebrew and
    /// the "Tailscale CLI" package install it elsewhere.
    private static func cliStatus() -> Data? {
        var candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        let cliRoot = "/Library/Application Support/Tailscale CLI/bin"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: cliRoot) {
            candidates += versions.sorted(by: >).map { "\(cliRoot)/\($0)/tailscale" }
        }
        for exe in candidates where FileManager.default.isExecutableFile(atPath: exe) {
            if let d = runCLI(exe) { return d }
        }
        return nil
    }

    private static func runCLI(_ exe: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["status", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        // Error text instead of JSON (daemon not running, wrong socket): try the next candidate.
        return data.first == UInt8(ascii: "{") ? data : nil
    }
}
