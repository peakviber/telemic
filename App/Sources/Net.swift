import Foundation

struct Endpoint: Hashable, Codable, CustomStringConvertible {
    var host: String
    var port: UInt16

    var description: String { "\(host):\(port)" }

    init(host: String, port: UInt16) { self.host = host; self.port = port }

    init(_ a: sockaddr_in) {
        var addr = a.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
        host = String(cString: buf)
        port = UInt16(bigEndian: a.sin_port)
    }

    /// "100.64.0.10:47810", "100.64.0.10" or "mac-mini:47810".
    static func parse(_ text: String) -> Endpoint? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let i = s.lastIndex(of: ":"), let p = UInt16(s[s.index(after: i)...]) {
            let h = String(s[..<i])
            return h.isEmpty ? nil : Endpoint(host: h, port: p)
        }
        return Endpoint(host: s, port: Wire.defaultPort)
    }

    /// Resolves to IPv4. Returns nil if the host can't be resolved.
    func resolve() -> sockaddr_in? {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &a.sin_addr) == 1 { return a }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        return ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }

    /// Proxy apps in fake-IP mode (Clash, Surge…) resolve names to 198.18.0.0/15.
    static func isFakeProxyIP(_ a: sockaddr_in) -> Bool {
        (UInt32(bigEndian: a.sin_addr.s_addr) & 0xFFFE_0000) == 0xC612_0000
    }
}

final class UDPSocket {
    let fd: Int32
    private var closed = false

    init() {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Returns an error message, or nil on success.
    func bind(port: UInt16) -> String? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0 ? nil : String(cString: strerror(errno))
    }

    func send(_ data: Data, to addr: sockaddr_in) {
        var a = addr
        _ = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Calls `handler` on a background thread for every datagram until `close()`.
    func startReceiving(_ handler: @escaping (Data, sockaddr_in) -> Void) {
        let t = Thread { [self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while !closed {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = buf.withUnsafeMutableBytes { b in
                    withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &len) }
                    }
                }
                if n <= 0 { if closed { break } else { continue } }
                handler(Data(buf[0..<n]), from)
            }
        }
        t.qualityOfService = .userInteractive
        t.start()
    }

    func close() {
        closed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
