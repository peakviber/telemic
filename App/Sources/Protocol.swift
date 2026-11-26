import CryptoKit
import Foundation
import Security

/// Wire format, all over UDP to the receiver's port (default 47810).
///
///   header      "RMC2" | kind(1)
///   hello       sender → receiver   senderID(16) | publicKey(32) | sessionSalt(16) | name(utf8)
///   status      receiver → sender   publicKey(32) | state(1) | name(utf8)
///   audio       sender → receiver   senderID(16) | seq(8, BE) | ChaCha20-Poly1305(opus) + tag(16)   (v0.2 senders)
///   audioRed    sender → receiver   senderID(16) | seq(8, BE) | ChaCha20-Poly1305(frames) + tag(16)
///               frames = count(1) | { len(2, BE) | opus } × count, for seq, seq-1, seq-2…
///               Carrying the previous frames lets the receiver rebuild short losses exactly.
///   discover    sender → anyone     (empty)
///   announce    receiver → sender   publicKey(32) | name(utf8)
///   version     both ways (v0.6+)   senderID(16, zero from the receiver) | app version(utf8)
///               Unauthenticated and informational only: it drives an "update the other Mac" hint.
///
/// Each sender session picks a fresh random salt; the audio key is
/// HKDF(X25519(sender, receiver), salt), so sequence numbers (the nonce) never
/// repeat under one key. A receiver only accepts audio from public keys the
/// user approved, and only that key's owner can produce audio that decrypts.
enum Wire {
    static let magic = Data("RMC2".utf8)
    static let defaultPort: UInt16 = 47810
    static let driverPort: UInt16 = 47811

    /// ping/pong (v0.4+): sender → receiver → sender, echoing an 8-byte timestamp for round-trip time.
    enum Kind: UInt8 { case hello = 1, status = 2, audio = 3, discover = 4, announce = 5, audioRed = 6, ping = 7, pong = 8, version = 9 }

    static func version(id: UUID, _ v: String) -> Data { header(.version) + id.data + Data(String(v.prefix(24)).utf8) }

    static func parseVersion(_ raw: Data) -> (id: UUID, version: String)? {
        let d = Data(raw)
        guard d.count > 21, d.count <= 21 + 24 else { return nil }
        let v = String(decoding: d.subdata(in: 21..<d.count), as: UTF8.self)
        guard v.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return (UUID(data: d.subdata(in: 5..<21)), v)
    }

    /// What we know about the other side's app version.
    enum PeerVersion: Equatable {
        case unknown            // not heard enough yet
        case legacy             // talks to us but never sent a version: older than 0.6
        case known(String)

        /// A short note when the other side runs a different version, else nil.
        func note(ours: String) -> String? {
            switch self {
            case .unknown: return nil
            case .legacy: return L("旧版本（< 0.6）", "older version (< 0.6)")
            case .known(let v): return v == ours ? nil : L("版本 \(v)", "version \(v)")
            }
        }
    }

    static func ping(_ nanos: UInt64) -> Data { header(.ping) + nanos.bigEndianData }

    /// Turns a ping into its pong, keeping the payload.
    static func pong(for ping: Data) -> Data? {
        let d = Data(ping)
        guard d.count == 13 else { return nil }
        return header(.pong) + d.subdata(in: 5..<13)
    }

    static func pongNanos(_ raw: Data) -> UInt64? {
        let d = Data(raw)
        guard d.count == 13 else { return nil }
        return d.subdata(in: 5..<13).reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Packs the newest frame first, then older ones (redundancy).
    static func packFrames(_ frames: [Data]) -> Data {
        var d = Data([UInt8(frames.count)])
        for f in frames {
            d.append(UInt8(f.count >> 8))
            d.append(UInt8(f.count & 0xFF))
            d.append(f)
        }
        return d
    }

    static func unpackFrames(_ raw: Data) -> [Data]? {
        let d = Data(raw)
        guard let count = d.first, count > 0 else { return nil }
        var frames: [Data] = []
        var i = 1
        for _ in 0..<count {
            guard i + 2 <= d.count else { return nil }
            let len = Int(d[i]) << 8 | Int(d[i + 1])
            i += 2
            guard i + len <= d.count else { return nil }
            frames.append(d.subdata(in: i..<i + len))
            i += len
        }
        return frames
    }

    enum LinkState: UInt8 {
        case pending = 0    // waiting for the receiver's user to approve
        case active = 1     // approved and currently heard
        case standby = 2    // approved, but the receiver is listening to another sender
        case denied = 3
    }

    static func kind(of d: Data) -> Kind? {
        guard d.count >= 5, d.prefix(4) == magic else { return nil }
        return Kind(rawValue: d[d.startIndex + 4])
    }

    static func header(_ k: Kind) -> Data {
        var d = magic
        d.append(k.rawValue)
        return d
    }

    struct Hello {
        var senderID: UUID
        var publicKey: Data
        var salt: Data
        var name: String

        func encode() -> Data {
            var d = header(.hello)
            d.append(senderID.data)
            d.append(publicKey)
            d.append(salt)
            d.append(Data(String(name.prefix(48)).utf8))
            return d
        }

        init(senderID: UUID, publicKey: Data, salt: Data, name: String) {
            self.senderID = senderID; self.publicKey = publicKey; self.salt = salt; self.name = name
        }

        init?(_ raw: Data) {
            let d = Data(raw)
            guard d.count >= 5 + 16 + 32 + 16 else { return nil }
            senderID = UUID(data: d.subdata(in: 5..<21))
            publicKey = d.subdata(in: 21..<53)
            salt = d.subdata(in: 53..<69)
            name = String(decoding: d.subdata(in: 69..<d.count), as: UTF8.self)
        }
    }

    struct Status {
        var publicKey: Data
        var state: LinkState
        var name: String

        func encode() -> Data {
            var d = header(.status)
            d.append(publicKey)
            d.append(state.rawValue)
            d.append(Data(String(name.prefix(48)).utf8))
            return d
        }

        init(publicKey: Data, state: LinkState, name: String) {
            self.publicKey = publicKey; self.state = state; self.name = name
        }

        init?(_ raw: Data) {
            let d = Data(raw)
            guard d.count >= 5 + 32 + 1, let s = LinkState(rawValue: d[37]) else { return nil }
            publicKey = d.subdata(in: 5..<37)
            state = s
            name = String(decoding: d.subdata(in: 38..<d.count), as: UTF8.self)
        }
    }

    struct Announce {
        var publicKey: Data
        var name: String

        func encode() -> Data {
            var d = header(.announce)
            d.append(publicKey)
            d.append(Data(String(name.prefix(48)).utf8))
            return d
        }

        init(publicKey: Data, name: String) { self.publicKey = publicKey; self.name = name }

        init?(_ raw: Data) {
            let d = Data(raw)
            guard d.count >= 5 + 32 else { return nil }
            publicKey = d.subdata(in: 5..<37)
            name = String(decoding: d.subdata(in: 37..<d.count), as: UTF8.self)
        }
    }

    struct Audio {
        var senderID: UUID
        var seq: UInt64
        var sealed: Data

        func encode(kind: Kind = .audioRed) -> Data {
            var d = header(kind)
            d.append(senderID.data)
            d.append(seq.bigEndianData)
            d.append(sealed)
            return d
        }

        init(senderID: UUID, seq: UInt64, sealed: Data) { self.senderID = senderID; self.seq = seq; self.sealed = sealed }

        init?(_ raw: Data) {
            let d = Data(raw)
            guard d.count > 5 + 16 + 8 + 16 else { return nil }
            senderID = UUID(data: d.subdata(in: 5..<21))
            seq = d.subdata(in: 21..<29).reduce(0) { $0 << 8 | UInt64($1) }
            sealed = d.subdata(in: 29..<d.count)
        }
    }

    static func discover() -> Data { header(.discover) }
}

enum Crypto {
    static func sessionKey(peerPublicKey: Data, salt: Data) -> SymmetricKey? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey),
              let secret = try? Identity.privateKey.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                              sharedInfo: Data("RemoteMic v1 audio".utf8), outputByteCount: 32)
    }

    private static func nonce(_ seq: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(count: 4) + seq.bigEndianData)
    }

    static func seal(_ plain: Data, key: SymmetricKey, senderID: UUID, seq: UInt64) -> Data? {
        guard let box = try? ChaChaPoly.seal(plain, using: key, nonce: nonce(seq),
                                             authenticating: senderID.data + seq.bigEndianData) else { return nil }
        return Data(box.ciphertext) + box.tag      // Data(...) so indices start at 0
    }

    static func open(_ sealed: Data, key: SymmetricKey, senderID: UUID, seq: UInt64) -> Data? {
        guard sealed.count > 16,
              let box = try? ChaChaPoly.SealedBox(nonce: nonce(seq), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        else { return nil }
        return try? ChaChaPoly.open(box, using: key, authenticating: senderID.data + seq.bigEndianData)
    }

    /// Short code people can compare on both Macs, e.g. "3F9A-12C0".
    static func fingerprint(_ publicKey: Data) -> String {
        let h = Array(SHA256.hash(data: publicKey).prefix(4))
        let hex = h.map { String(format: "%02X", $0) }.joined()
        return hex.prefix(4) + "-" + hex.suffix(4)
    }

    static func randomSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }
}

/// This Mac's long-lived identity: an X25519 key and a device ID.
enum Identity {
    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteMic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Developer ID builds (stable code signature) keep the key in the Keychain; ad-hoc builds
    /// keep it as a 0600 file in Application Support, because their signature changes with every
    /// build and the Keychain would ask for permission after each update.
    /// An existing file key is moved into the Keychain once; the identity never changes.
    static let privateKey: Curve25519.KeyAgreement.PrivateKey = {
        let url = directory.appendingPathComponent("identity.key")
        let fileKey = (try? Data(contentsOf: url)).flatMap { try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
        if Signing.teamID != nil {
            if let raw = Keychain.read(), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
                if fileKey?.rawRepresentation == raw { try? FileManager.default.removeItem(at: url) }
                return key
            }
            let key = fileKey ?? Curve25519.KeyAgreement.PrivateKey()
            if Keychain.write(key.rawRepresentation) {
                try? FileManager.default.removeItem(at: url)
                Log.info("identity key stored in the Keychain")
                return key
            }
            if fileKey != nil { return key }
            // Keychain unavailable: fall through to the file so the key still persists.
            FileManager.default.createFile(atPath: url.path, contents: key.rawRepresentation,
                                           attributes: [.posixPermissions: 0o600])
            return key
        }
        if let key = fileKey { return key }
        // A Developer ID build may have moved the key into the Keychain; reuse it rather than
        // silently becoming a new device (macOS may ask once to allow this build).
        if let raw = Keychain.read(), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        FileManager.default.createFile(atPath: url.path, contents: key.rawRepresentation,
                                       attributes: [.posixPermissions: 0o600])
        return key
    }()

    static var publicKey: Data { privateKey.publicKey.rawRepresentation }

    static let deviceID: UUID = {
        if let s = UserDefaults.standard.string(forKey: "deviceID"), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "deviceID")
        return id
    }()

    static let name: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
}

extension UUID {
    var data: Data { withUnsafeBytes(of: uuid) { Data($0) } }
    init(data: Data) {
        var u: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &u) { $0.copyBytes(from: data.prefix(16)) }
        self.init(uuid: u)
    }
}

extension UInt64 {
    var bigEndianData: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}

/// The running app's code signature.
enum Signing {
    /// Team identifier of a Developer ID (or other team) signature; nil for ad-hoc builds.
    static let teamID: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()
}

/// The identity key's Keychain item (login keychain, this Mac only).
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.remotemic.identity",
        kSecAttrAccount as String: "x25519",
    ]

    static func read() -> Data? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func write(_ data: Data) -> Bool {
        var q = base
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "RemoteMic device key"
        let status = SecItemAdd(q as CFDictionary, nil)
        return status == errSecSuccess || (status == errSecDuplicateItem && read() == data)
    }
}
