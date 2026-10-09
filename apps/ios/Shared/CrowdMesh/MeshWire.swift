//
//  MeshWire.swift
//  ChatFort — Crowd mesh
//
//  Wire format v2, byte-compatible with Android (frozen 2026-09-24, see
//  ~/Documents/projects/ios-alignment-2.md §2 and mesh-v2-vectors.txt), plus the version-3
//  packet types (CONTACT, MEDIA_CHUNK; ios-alignment-6.md), which keep the v2 header layout.
//  Foundation + CryptoKit only, so it also compiles in the macOS vector tests.
//

import CryptoKit
import Foundation

enum MeshWire {
    static let magic: UInt8 = 0x43          // 'C'
    /// ANNOUNCE, PUBLIC, CHANNEL, DIRECT and control frames.
    static let version: UInt8 = 2
    /// CONTACT and MEDIA_CHUNK. v2 phones relay these unread (opaque).
    static let v3: UInt8 = 3
    static let maxHops: UInt8 = 7
    static let announceMaxTtl: UInt8 = 3
    static let messageMaxTtl: UInt8 = 7
    static let maxPayload = 2048
    /// Largest frame relayed at all (also the opaque-relay limit).
    static let maxFrame = 4096
    static let maxNickBytes = 32
    static let maxTextBytes = 1000
    static let maxControlIds = 512
}

enum MeshPacketType: UInt8 {
    case announce = 1
    case publicPost = 2
    case channel = 3
    case direct = 4
    /// Version 3: to a linked ChatFort contact (pair key, hourly tag).
    case contact = 5
    /// Version 3: one piece of a photo or voice note.
    case mediaChunk = 6

    /// The version byte packets of this type carry.
    var version: UInt8 { rawValue >= 5 ? MeshWire.v3 : MeshWire.version }
}

// MARK: - Packet

/// `'C' | version | type | ttl | maxTtl | flags | messageId(16) | origin(8) | timestamp(8) |
///  target(8) | originKey(65) | payloadLen(u16) | payload | sigLen(u8) | DER signature`
struct MeshPacket: Equatable {
    static let payloadOffset = 113

    /// 2, or 3 for CONTACT / MEDIA_CHUNK. The header layout is the same.
    var version: UInt8 = MeshWire.version
    var type: UInt8
    var ttl: UInt8
    var maxTtl: UInt8
    var flags: UInt8 = 0
    var messageId: Data
    var origin: Data
    var timestamp: UInt64
    var target: Data
    var originKey: Data
    var payload: Data
    var signature: Data

    var packetType: MeshPacketType? { MeshPacketType(rawValue: type) }
    /// Known type sent with the version byte that type uses (v2: 1-4, v3: 5-6).
    var knownTypeAndVersion: MeshPacketType? { packetType.flatMap { $0.version == version ? $0 : nil } }
    /// Approximate, for display only (relays can't change maxTtl).
    var hops: Int { Int(maxTtl) - Int(ttl) }

    /// Everything before sigLen, with ttl = 0 (relays change only ttl).
    var signedBytes: Data {
        var d = Data(capacity: MeshPacket.payloadOffset + payload.count)
        d.append(contentsOf: [MeshWire.magic, version, type, 0, maxTtl, flags])
        d.append(messageId)
        d.append(origin)
        d.appendU64(timestamp)
        d.append(target)
        d.append(originKey)
        d.appendU16(UInt16(payload.count))
        d.append(payload)
        return d
    }

    func encoded() -> Data {
        var d = signedBytes
        d[d.startIndex + 3] = ttl
        d.append(UInt8(signature.count))
        d.append(signature)
        return d
    }

    /// Additional authenticated data for CHANNEL and DIRECT payloads.
    var aad: Data {
        var d = Data([type])
        d.append(messageId)
        d.append(origin)
        d.appendU64(timestamp)
        d.append(target)
        return d
    }

    /// Dedup key used in INVENTORY / REQUEST: SHA-256(origin ‖ messageId)[0..8] for v2. A v3 packet
    /// uses its opaque ID, the value v2 phones compute when they relay it unread.
    var shortId: UInt64 {
        version == MeshWire.version ? MeshWire.shortId(origin: origin, messageId: messageId) : MeshWire.opaqueId(encoded())
    }

    /// The copy a relay forwards: ttl − 1. Nil when it must not travel further.
    func relayed() -> MeshPacket? {
        guard ttl > 1 else { return nil }
        var p = self
        p.ttl -= 1
        return p
    }

    func verifySignature() -> Bool {
        MeshCrypto.origin(of: originKey) == origin
            && MeshCrypto.verify(signature: signature, data: signedBytes, publicKey: originKey)
    }

    /// Structure and ranges only; call `verifySignature()` before trusting it.
    static func decode(_ raw: Data) -> MeshPacket? {
        let b = [UInt8](raw)
        guard b.count > payloadOffset + 1, b.count <= MeshWire.maxFrame,
              b[0] == MeshWire.magic, b[1] == MeshWire.version || b[1] == MeshWire.v3, b[2] < 0x80
        else { return nil }
        let ttl = b[3], maxTtl = b[4]
        guard (1...MeshWire.maxHops).contains(maxTtl), (1...maxTtl).contains(ttl) else { return nil }
        let n = Int(b[111]) << 8 | Int(b[112])
        guard n <= MeshWire.maxPayload, b.count > payloadOffset + n else { return nil }
        let sigLen = Int(b[payloadOffset + n])
        guard (8...80).contains(sigLen), b.count == payloadOffset + n + 1 + sigLen else { return nil }
        return MeshPacket(
            version: b[1], type: b[2], ttl: ttl, maxTtl: maxTtl, flags: b[5],
            messageId: Data(b[6..<22]), origin: Data(b[22..<30]),
            timestamp: Data(b[30..<38]).readU64(),
            target: Data(b[38..<46]), originKey: Data(b[46..<111]),
            payload: Data(b[payloadOffset..<(payloadOffset + n)]),
            signature: Data(b[(payloadOffset + n + 1)...])
        )
    }

    /// A new signed packet with ttl = maxTtl.
    static func make(type: MeshPacketType, maxTtl: UInt8, messageId: Data = MeshCrypto.randomBytes(16),
                     timestamp: UInt64, target: Data = Data(count: 8), payload: Data,
                     signingKey: P256.Signing.PrivateKey) -> MeshPacket {
        let originKey = signingKey.publicKey.x963Representation
        var p = MeshPacket(version: type.version, type: type.rawValue, ttl: maxTtl, maxTtl: maxTtl, flags: 0,
                           messageId: messageId, origin: MeshCrypto.origin(of: originKey),
                           timestamp: timestamp, target: target, originKey: originKey,
                           payload: payload, signature: Data())
        p.signature = MeshCrypto.sign(p.signedBytes, with: signingKey)
        return p
    }
}

extension MeshWire {
    static func shortId(origin: Data, messageId: Data) -> UInt64 {
        MeshCrypto.sha256(origin + messageId).prefix(8).readU64()
    }

    /// Dedup key for packets of a future version, relayed unread:
    /// SHA-256("chatfort-mesh-opaque" ‖ bytes with ttl = 0)[0..8].
    static func opaqueId(_ raw: Data) -> UInt64 {
        var z = raw
        z[z.startIndex + 3] = 0
        return MeshCrypto.sha256(Data("chatfort-mesh-opaque".utf8) + z).prefix(8).readU64()
    }
}

// MARK: - Frames seen by the router

enum MeshControlCode: UInt8 {
    case inventory = 0x81
    case request = 0x82
}

enum MeshFrame {
    case packet(MeshPacket)
    /// Versions this phone can't read (v3 types other than 5-6, and 4...0x7F): relay unread
    /// (ttl − 1), never store.
    case opaque(Data)
    case control(MeshControlCode, [UInt64])

    static func classify(_ raw: Data) -> MeshFrame? {
        let b = [UInt8](raw)
        guard b.count >= 5, b.count <= MeshWire.maxFrame, b[0] == MeshWire.magic else { return nil }
        if b[1] == MeshWire.version {
            if b[2] >= 0x80 {
                guard let code = MeshControlCode(rawValue: b[2]) else { return nil }
                let count = Int(b[3]) << 8 | Int(b[4])
                guard count <= MeshWire.maxControlIds, b.count == 5 + 8 * count else { return nil }
                let ids = (0..<count).map { i in Data(b[(5 + 8 * i)..<(13 + 8 * i)]).readU64() }
                return .control(code, ids)
            }
            return MeshPacket.decode(raw).map(MeshFrame.packet)
        }
        if b[1] == MeshWire.v3, b[2] == MeshPacketType.contact.rawValue || b[2] == MeshPacketType.mediaChunk.rawValue {
            return MeshPacket.decode(raw).map(MeshFrame.packet)
        }
        // A v2 type (1-4) always carries version byte 2: under version 3 it can only be malformed or
        // crafted, and relaying it would dodge that type's limits. Dropped (same as Android).
        if b[1] == MeshWire.v3, (1...4).contains(b[2]) { return nil }
        // Future versions: bytes 0-4 are fixed forever (magic, version, type < 0x80, ttl, maxTtl).
        guard (3...0x7f).contains(b[1]), b[2] < 0x80,
              (1...MeshWire.maxHops).contains(b[4]), (1...b[4]).contains(b[3])
        else { return nil }
        return .opaque(raw)
    }

    static func control(_ code: MeshControlCode, _ ids: [UInt64]) -> Data {
        var d = Data([MeshWire.magic, MeshWire.version, code.rawValue])
        d.appendU16(UInt16(ids.count))
        ids.forEach { d.appendU64($0) }
        return d
    }

    /// The copy of an opaque frame a relay forwards (ttl − 1), or nil.
    static func relayedOpaque(_ raw: Data) -> Data? {
        let i = raw.startIndex + 3
        guard raw.count >= 5, raw[i] > 1 else { return nil }
        var r = raw
        r[i] -= 1
        return r
    }
}

// MARK: - Message body: nickLen(u8) | nick UTF-8 (≤32 B) | text UTF-8 (≤1000 B)

struct MeshMessageBody: Equatable {
    var nick: String
    var text: String

    func encoded() -> Data {
        let n = Data(nick.utf8Prefix(maxBytes: MeshWire.maxNickBytes).utf8)
        var d = Data([UInt8(n.count)])
        d.append(n)
        d.append(Data(text.utf8Prefix(maxBytes: MeshWire.maxTextBytes).utf8))
        return d
    }

    static func decode(_ d: Data) -> MeshMessageBody? {
        guard let first = d.first else { return nil }
        let len = Int(first)
        guard len <= MeshWire.maxNickBytes, d.count >= 1 + len,
              d.count - 1 - len <= MeshWire.maxTextBytes,
              let nick = String(data: d.subdata(in: (d.startIndex + 1)..<(d.startIndex + 1 + len)), encoding: .utf8),
              let text = String(data: d.subdata(in: (d.startIndex + 1 + len)..<d.endIndex), encoding: .utf8)
        else { return nil }
        return MeshMessageBody(nick: nick, text: text)
    }
}

// MARK: - Sealed body (inside CHANNEL / DIRECT encryption)
// kind(u8) | senderKey(65) | sigLen(u8) | sig | content

enum MeshSealedKind: UInt8 {
    case message = 1   // content = MessageBody
    case ack = 2       // content = acked messageId (16 B)
    case rekey = 3     // content = new public key (65 B), signed by the old key
    /// v3, CHANNEL only: content = uid(16) | media header (a team photo or voice note).
    /// Phones before v3 drop unknown kinds when opening, so they show nothing.
    case media = 4
}

struct MeshSealedBody: Equatable {
    var kind: UInt8
    var senderKey: Data
    var signature: Data
    var content: Data

    var sealedKind: MeshSealedKind? { MeshSealedKind(rawValue: kind) }

    func encoded() -> Data {
        var d = Data([kind])
        d.append(senderKey)
        d.append(UInt8(signature.count))
        d.append(signature)
        d.append(content)
        return d
    }

    static func decode(_ d: Data) -> MeshSealedBody? {
        let b = [UInt8](d)
        guard b.count >= 67 else { return nil }
        let sigLen = Int(b[66])
        guard (8...80).contains(sigLen), b.count >= 67 + sigLen else { return nil }
        return MeshSealedBody(kind: b[0], senderKey: Data(b[1..<66]),
                              signature: Data(b[67..<(67 + sigLen)]), content: Data(b[(67 + sigLen)...]))
    }

    /// What the sender identity signs. `recipientKey` is 65 bytes for DIRECT, empty for CHANNEL.
    static func signedBytes(type: UInt8, messageId: Data, timestamp: UInt64, target: Data,
                            recipientKey: Data, kind: UInt8, content: Data) -> Data {
        var d = Data("chatfort-mesh-sealed-v2".utf8)
        d.append(type)
        d.append(messageId)
        d.appendU64(timestamp)
        d.append(target)
        d.append(UInt8(recipientKey.count))
        d.append(recipientKey)
        d.append(kind)
        d.append(content)
        return d
    }
}

// MARK: - Link frames (BLE layer only): 4C 01 type(01 HELLO | 02 BYE) token(u32 BE)

enum MeshLinkFrame: Equatable {
    case hello(token: UInt32)
    case bye(token: UInt32)

    static let size = 7

    func encoded() -> Data {
        switch self {
        case let .hello(token): return Data([0x4c, 0x01, 0x01]) + Data(u32: token)
        case let .bye(token): return Data([0x4c, 0x01, 0x02]) + Data(u32: token)
        }
    }

    static func decode(_ d: Data) -> MeshLinkFrame? {
        let b = [UInt8](d)
        guard b.count == size, b[0] == 0x4c, b[1] == 0x01 else { return nil }
        let token = UInt32(b[3]) << 24 | UInt32(b[4]) << 16 | UInt32(b[5]) << 8 | UInt32(b[6])
        switch b[2] {
        case 0x01: return .hello(token: token)
        case 0x02: return .bye(token: token)
        default: return nil
        }
    }
}

// MARK: - Fragmentation: [sequence][index][count][data], up to 255 fragments

final class MeshFragmenter {
    static let header = 3
    static let maxFragments = 255
    private var sequence: UInt8 = 0

    /// `maxFragment` is the largest single BLE write/notification. Empty if the frame is too big.
    func split(_ frame: Data, maxFragment: Int) -> [Data] {
        let chunk = maxFragment - MeshFragmenter.header
        guard chunk >= 1, !frame.isEmpty else { return [] }
        let count = (frame.count + chunk - 1) / chunk
        guard count <= MeshFragmenter.maxFragments else { return [] }
        let seq = sequence
        sequence &+= 1
        return (0..<count).map { i in
            let start = frame.startIndex + i * chunk
            let end = min(frame.endIndex, start + chunk)
            return Data([seq, UInt8(i), UInt8(count)]) + frame[start..<end]
        }
    }
}

final class MeshReassembler {
    private struct Pending {
        var count: Int
        var startedAt: TimeInterval
        var parts: [Data?]
        var received = 0
    }

    private let timeout: TimeInterval
    private let maxPending: Int
    private var pending: [UInt8: Pending] = [:]
    private var order: [UInt8] = []

    init(timeout: TimeInterval = 15, maxPending: Int = 16) {
        self.timeout = timeout
        self.maxPending = maxPending
    }

    /// The whole frame when its last fragment arrives, otherwise nil.
    func accept(_ fragment: Data, now: TimeInterval) -> Data? {
        let b = [UInt8](fragment)
        guard b.count > MeshFragmenter.header else { return nil }
        let seq = b[0], index = Int(b[1]), count = Int(b[2])
        guard count > 0, index < count else { return nil }
        if count == 1 { return Data(b[MeshFragmenter.header...]) }
        expire(now)
        var p: Pending
        if let existing = pending[seq], existing.count == count {
            p = existing
        } else {
            if pending[seq] == nil, pending.count >= maxPending, let oldest = order.first {
                pending[oldest] = nil
                order.removeFirst()
            }
            p = Pending(count: count, startedAt: now, parts: Array(repeating: nil, count: count))
            if !order.contains(seq) { order.append(seq) }
        }
        if p.parts[index] == nil {
            p.parts[index] = Data(b[MeshFragmenter.header...])
            p.received += 1
        }
        guard p.received == count else {
            pending[seq] = p
            return nil
        }
        pending[seq] = nil
        order.removeAll { $0 == seq }
        return p.parts.reduce(into: Data()) { $0.append($1!) }
    }

    func expire(_ now: TimeInterval) {
        for (seq, p) in pending where now - p.startedAt > timeout {
            pending[seq] = nil
            order.removeAll { $0 == seq }
        }
    }
}

// MARK: - Byte helpers

extension Data {
    init(u32 v: UInt32) { self = Swift.withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    mutating func appendU16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendU64(_ v: UInt64) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }

    func readU64() -> UInt64 { reduce(0) { ($0 << 8) | UInt64($1) } }

    var meshHex: String { map { String(format: "%02x", $0) }.joined() }

    init?(meshHex s: String) {
        guard s.count % 2 == 0 else { return nil }
        var d = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let byte = UInt8(s[i..<j], radix: 16) else { return nil }
            d.append(byte)
            i = j
        }
        self = d
    }
}

extension String {
    /// Longest prefix whose UTF-8 encoding fits in `maxBytes`, never splitting a character.
    func utf8Prefix(maxBytes: Int) -> String {
        guard utf8.count > maxBytes else { return self }
        var out = ""
        var used = 0
        for ch in self {
            let n = String(ch).utf8.count
            if used + n > maxBytes { break }
            out.append(ch)
            used += n
        }
        return out
    }
}
