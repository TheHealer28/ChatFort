//
//  MeshCrypto.swift
//  ChatFort — Crowd mesh
//
//  Wire v2 crypto (P-256 ECDSA/ECDH, HKDF-SHA256, AES-256-GCM, HMAC-SHA256), byte-compatible
//  with Android and checked against mesh-v2-vectors.txt. Foundation + CryptoKit only.
//

import CryptoKit
import Foundation
import Security

/// A mesh identity: one P-256 key that both signs and receives DIRECT messages. Fresh at every
/// start and rotated every 15 minutes; never linked to the ChatFort profile.
struct MeshIdentity {
    let signingKey: P256.Signing.PrivateKey

    init() { signingKey = P256.Signing.PrivateKey() }
    init(rawScalar: Data) throws { signingKey = try P256.Signing.PrivateKey(rawRepresentation: rawScalar) }

    /// 65-byte X9.63 public key.
    var publicKey: Data { signingKey.publicKey.x963Representation }
    var peerId: Data { MeshCrypto.origin(of: publicKey) }
    var agreementKey: P256.KeyAgreement.PrivateKey {
        // Same scalar: the key signs and does ECDH, like Android.
        try! P256.KeyAgreement.PrivateKey(rawRepresentation: signingKey.rawRepresentation)
    }
}

enum MeshCrypto {
    static let sealedInfoDirect = "chatfort-mesh-direct-v2"
    static let channelRatchetInfo = "chatfort-mesh-channel-ratchet-v2"
    static let channelMessageInfo = "chatfort-mesh-channel-msg-v2"
    static let channelTagInfo = "chatfort-mesh-channel-tag-v2"
    static let teamCodePrefix = "CFTEAM2"
    static let dayMs: UInt64 = 86_400_000
    static let hourMs: UInt64 = 3_600_000

    // MARK: primitives

    static func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

    /// origin / peer ID = SHA-256(public key)[0..8].
    static func origin(of publicKey: Data) -> Data { sha256(publicKey).prefix(8) }

    static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        let status = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return d
    }

    static func randomUInt32() -> UInt32 { randomBytes(4).reduce(0) { ($0 << 8) | UInt32($1) } }

    /// ECDSA-P256-SHA256, DER.
    static func sign(_ data: Data, with key: P256.Signing.PrivateKey) -> Data {
        (try? key.signature(for: data).derRepresentation) ?? Data()
    }

    /// Accepts DER signatures with low or high S (Android's Java signer produces both).
    static func verify(signature: Data, data: Data, publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature)
        else { return false }
        return key.isValidSignature(sig, for: data)
    }

    static func isValidPublicKey(_ key: Data) -> Bool {
        key.count == 65 && (try? P256.Signing.PublicKey(x963Representation: key)) != nil
    }

    /// HKDF-SHA256, 32 bytes. No salt = empty salt (same as 32 zero bytes).
    static func hkdf(_ ikm: Data, salt: Data? = nil, info: String) -> Data {
        let k = SymmetricKey(data: ikm)
        let i = Data(info.utf8)
        let out = salt.map { HKDF<SHA256>.deriveKey(inputKeyMaterial: k, salt: $0, info: i, outputByteCount: 32) }
            ?? HKDF<SHA256>.deriveKey(inputKeyMaterial: k, info: i, outputByteCount: 32)
        return out.withUnsafeBytes { Data($0) }
    }

    /// A random nonce unless `nonce` (12 bytes) is given.
    static func aesSeal(_ plaintext: Data, key: Data, aad: Data, nonce: Data? = nil) -> (nonce: Data, ciphertextAndTag: Data)? {
        let n: AES.GCM.Nonce
        if let nonce {
            guard let given = try? AES.GCM.Nonce(data: nonce) else { return nil }
            n = given
        } else {
            n = AES.GCM.Nonce()
        }
        guard let box = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: n, authenticating: aad)
        else { return nil }
        return (Data(box.nonce), box.ciphertext + box.tag)
    }

    static func aesOpen(_ ciphertextAndTag: Data, nonce: Data, key: Data, aad: Data) -> Data? {
        guard ciphertextAndTag.count >= 16,
              let n = try? AES.GCM.Nonce(data: nonce),
              let box = try? AES.GCM.SealedBox(nonce: n, ciphertext: ciphertextAndTag.dropLast(16), tag: ciphertextAndTag.suffix(16))
        else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    // MARK: sealed body

    static func sealedBody(kind: MeshSealedKind, content: Data, sender: MeshIdentity, type: MeshPacketType,
                           messageId: Data, timestamp: UInt64, target: Data, recipientKey: Data) -> MeshSealedBody {
        let signed = MeshSealedBody.signedBytes(type: type.rawValue, messageId: messageId, timestamp: timestamp,
                                                target: target, recipientKey: recipientKey, kind: kind.rawValue, content: content)
        return MeshSealedBody(kind: kind.rawValue, senderKey: sender.publicKey,
                              signature: sign(signed, with: sender.signingKey), content: content)
    }

    /// Parses and verifies the inner signature; nil unless it checks out.
    static func verifiedSealedBody(_ plain: Data, _ p: MeshPacket, recipientKey: Data) -> MeshSealedBody? {
        guard let body = MeshSealedBody.decode(plain), body.sealedKind != nil,
              isValidPublicKey(body.senderKey)
        else { return nil }
        let signed = MeshSealedBody.signedBytes(type: p.type, messageId: p.messageId, timestamp: p.timestamp,
                                                target: p.target, recipientKey: recipientKey, kind: body.kind, content: body.content)
        return verify(signature: body.signature, data: signed, publicKey: body.senderKey) ? body : nil
    }

    // MARK: DIRECT (sealed sender): target = 0, payload = ephPub(65) | nonce(12) | AES-GCM(body)

    static func directKey(shared: Data, ephemeralPublicKey: Data, recipientKey: Data) -> Data {
        hkdf(shared, salt: ephemeralPublicKey + recipientKey, info: sealedInfoDirect)
    }

    /// New packet signed by a fresh one-time key, encrypted to `recipientKey` with a fresh ephemeral key.
    static func sealDirect(kind: MeshSealedKind, content: Data, sender: MeshIdentity, recipientKey: Data,
                           timestamp: UInt64, messageId: Data = randomBytes(16)) -> MeshPacket? {
        guard let recipient = try? P256.KeyAgreement.PublicKey(x963Representation: recipientKey) else { return nil }
        let outer = P256.Signing.PrivateKey()
        let eph = P256.KeyAgreement.PrivateKey()
        let ephPub = eph.publicKey.x963Representation
        guard let shared = try? eph.sharedSecretFromKeyAgreement(with: recipient).withUnsafeBytes({ Data($0) }) else { return nil }
        let target = Data(count: 8)
        let body = sealedBody(kind: kind, content: content, sender: sender, type: .direct,
                              messageId: messageId, timestamp: timestamp, target: target, recipientKey: recipientKey)
        let originKey = outer.publicKey.x963Representation
        var p = MeshPacket(type: MeshPacketType.direct.rawValue, ttl: MeshWire.messageMaxTtl, maxTtl: MeshWire.messageMaxTtl,
                           messageId: messageId, origin: origin(of: originKey), timestamp: timestamp,
                           target: target, originKey: originKey, payload: Data(), signature: Data())
        guard let sealed = aesSeal(body.encoded(), key: directKey(shared: shared, ephemeralPublicKey: ephPub, recipientKey: recipientKey), aad: p.aad)
        else { return nil }
        p.payload = ephPub + sealed.nonce + sealed.ciphertextAndTag
        p.signature = sign(p.signedBytes, with: outer)
        return p
    }

    /// Nil unless `recipient` can decrypt it and the inner signature binds `recipient`.
    static func openDirect(_ p: MeshPacket, recipient: MeshIdentity) -> MeshSealedBody? {
        guard p.type == MeshPacketType.direct.rawValue, p.payload.count > 65 + 12 + 16 else { return nil }
        let base = p.payload.startIndex
        let ephPub = p.payload[base..<(base + 65)]
        let nonce = p.payload[(base + 65)..<(base + 77)]
        let ct = p.payload[(base + 77)...]
        guard let eph = try? P256.KeyAgreement.PublicKey(x963Representation: ephPub),
              let shared = try? recipient.agreementKey.sharedSecretFromKeyAgreement(with: eph).withUnsafeBytes({ Data($0) }),
              let plain = aesOpen(Data(ct), nonce: Data(nonce),
                                  key: directKey(shared: shared, ephemeralPublicKey: Data(ephPub), recipientKey: recipient.publicKey),
                                  aad: p.aad)
        else { return nil }
        return verifiedSealedBody(plain, p, recipientKey: recipient.publicKey)
    }

    // MARK: CHANNEL (teams): daily key chain, hourly tag as target

    static func day(of timestamp: UInt64) -> UInt64 { timestamp / dayMs }
    static func ratchet(_ dayKey: Data) -> Data { hkdf(dayKey, info: channelRatchetInfo) }
    static func channelMessageKey(_ dayKey: Data) -> Data { hkdf(dayKey, info: channelMessageInfo) }

    /// HMAC-SHA256(HKDF(key(d), tag info), hour as u64 BE)[0..8].
    static func channelTag(dayKey: Data, timestamp: UInt64) -> Data {
        hourTag(dayKey: dayKey, timestamp: timestamp, info: channelTagInfo)
    }

    /// HMAC-SHA256(HKDF(dayKey, info), timestamp / 1 h as u64 BE)[0..8]: teams (v2) and contacts (v3).
    static func hourTag(dayKey: Data, timestamp: UInt64, info: String) -> Data {
        var hour = Data()
        hour.appendU64(timestamp / hourMs)
        let tagKey = SymmetricKey(data: hkdf(dayKey, info: info))
        return Data(HMAC<SHA256>.authenticationCode(for: hour, using: tagKey)).prefix(8)
    }

    /// `dayKey` must be the team key for `day(of: timestamp)`.
    static func sealChannel(kind: MeshSealedKind = .message, content: Data, sender: MeshIdentity, dayKey: Data,
                            timestamp: UInt64, messageId: Data = randomBytes(16)) -> MeshPacket? {
        let outer = P256.Signing.PrivateKey()
        let target = channelTag(dayKey: dayKey, timestamp: timestamp)
        let body = sealedBody(kind: kind, content: content, sender: sender, type: .channel,
                              messageId: messageId, timestamp: timestamp, target: target, recipientKey: Data())
        let originKey = outer.publicKey.x963Representation
        var p = MeshPacket(type: MeshPacketType.channel.rawValue, ttl: MeshWire.messageMaxTtl, maxTtl: MeshWire.messageMaxTtl,
                           messageId: messageId, origin: origin(of: originKey), timestamp: timestamp,
                           target: target, originKey: originKey, payload: Data(), signature: Data())
        guard let sealed = aesSeal(body.encoded(), key: channelMessageKey(dayKey), aad: p.aad) else { return nil }
        p.payload = sealed.nonce + sealed.ciphertextAndTag
        p.signature = sign(p.signedBytes, with: outer)
        return p
    }

    /// `dayKey` must be the team key for the packet's day. Nil unless the tag matches, it decrypts and
    /// the inner signature checks out.
    static func openChannel(_ p: MeshPacket, dayKey: Data) -> MeshSealedBody? {
        guard p.type == MeshPacketType.channel.rawValue, p.payload.count > 12 + 16,
              p.target == channelTag(dayKey: dayKey, timestamp: p.timestamp),
              let plain = aesOpen(Data(p.payload.dropFirst(12)), nonce: Data(p.payload.prefix(12)),
                                  key: channelMessageKey(dayKey), aad: p.aad)
        else { return nil }
        return verifiedSealedBody(plain, p, recipientKey: Data())
    }

    // MARK: team code: CFTEAM2.<b64url key(d)>.<d>.<b64url name>

    static func teamCode(dayKey: Data, day: UInt64, name: String) -> String {
        "\(teamCodePrefix).\(dayKey.base64URLNoPad).\(day).\(Data(name.utf8).base64URLNoPad)"
    }

    static func parseTeamCode(_ code: String) -> (dayKey: Data, day: UInt64, name: String)? {
        let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == teamCodePrefix,
              let key = Data(base64URLNoPad: parts[1]), key.count == 32,
              let day = UInt64(parts[2]),
              let nameData = Data(base64URLNoPad: parts[3]),
              let name = String(data: nameData, encoding: .utf8)
        else { return nil }
        return (key, day, name)
    }
}

extension Data {
    var base64URLNoPad: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLNoPad s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        self.init(base64Encoded: b)
    }
}
