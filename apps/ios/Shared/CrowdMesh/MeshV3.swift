//
//  MeshV3.swift
//  ChatFort — Crowd mesh
//
//  Wire v3 (ios-alignment-6.md, readings in android-alignment-9.md §3): CONTACT packets between
//  linked ChatFort contacts (pair key from seeds swapped in their chat, daily ratchet, hourly tag),
//  and photos / voice notes sent as a media header plus MEDIA_CHUNK packets. Foundation + CryptoKit
//  only, so it also builds into the macOS tests.
//

import CryptoKit
import Foundation

enum MeshV3 {
    static let contactRootInfo = "chatfort-mesh-contact-root-v3"
    static let contactRatchetInfo = "chatfort-mesh-contact-ratchet-v3"
    static let contactMessageInfo = "chatfort-mesh-contact-msg-v3"
    static let contactTagInfo = "chatfort-mesh-contact-tag-v3"
    static let mediaChunkInfo = "chatfort-mesh-media-chunk-v3"

    static let contactMaxTtl: UInt8 = 7
    /// Relays drop MEDIA_CHUNK packets with a larger maxTtl.
    static let mediaMaxTtl: UInt8 = 5
    static let maxContactTextBytes = 1000
    static let chunkSize = 1536
    static let maxChunks = 48
    /// 32 chunks.
    static let photoMaxBytes = 49_152
    /// 42 chunks (64 KB in the note doesn't fit 42; see android-alignment-9 §2.2).
    static let voiceMaxBytes = 64_512
    static let photoMaxEdge = 1024
    static let voiceMaxDurationMs: UInt32 = 30_000
    static let maxCaptionBytes = 500
    /// Anti-replay (android-alignment-9 §2.3): PING/PONG count, and a repeated item is ACKed again,
    /// only if the packet's timestamp is this close to now.
    static let freshMs: UInt64 = 2 * 60_000

    static func isFresh(_ timestamp: UInt64, nowMs: UInt64) -> Bool {
        (timestamp >= nowMs ? timestamp - nowMs : nowMs - timestamp) <= freshMs
    }
}

// MARK: - CONTACT body: kind(u8) | role(u8) | uid(16) | content

enum MeshContactKind: UInt8 {
    /// content = text UTF-8 (≤ 1000 B)
    case message = 1
    /// uid = the acked item's uid, no content
    case ack = 2
    case ping = 3
    /// uid = the ping's uid
    case pong = 4
    /// content = media header
    case media = 5
}

struct MeshContactBody: Equatable {
    var kind: UInt8
    /// The sender's role in the pair (0: seed ordered first, 1: second). Own packets come back with ours.
    var role: UInt8
    /// The sender's stable ID for the item, the same across resends.
    var uid: Data
    var content: Data

    var contactKind: MeshContactKind? { MeshContactKind(rawValue: kind) }

    init(kind: MeshContactKind, role: UInt8, uid: Data, content: Data = Data()) {
        self.init(kind: kind.rawValue, role: role, uid: uid, content: content)
    }

    init(kind: UInt8, role: UInt8, uid: Data, content: Data) {
        self.kind = kind
        self.role = role
        self.uid = uid
        self.content = content
    }

    func encoded() -> Data { Data([kind, role]) + uid + content }

    static func decode(_ data: Data) -> MeshContactBody? {
        let d = Data(data)
        guard d.count >= 18 else { return nil }
        return MeshContactBody(kind: d[0], role: d[1], uid: d.subdata(in: 2..<18), content: d.subdata(in: 18..<d.count))
    }
}

// MARK: - Pair keys

/// A daily key chain: key(d+1) = ratchet(key(d)). Keeps today's key, plus yesterday's for the first
/// 12 h after midnight UTC; tomorrow's is derived on demand. Days before `day` have no key.
protocol MeshDailyKeyChain {
    var dayKey: Data { get set }
    var day: UInt64 { get set }
    var previousKey: Data? { get set }
    static func ratchet(_ key: Data) -> Data
}

extension MeshDailyKeyChain {
    /// Ratchets forward to `today` (never back), keeping yesterday's key.
    mutating func advance(to today: UInt64) {
        guard today > day else { return }
        var key = dayKey
        var d = day
        var previous: Data? = nil
        while d < today {
            previous = key
            key = Self.ratchet(key)
            d += 1
        }
        previousKey = previous
        dayKey = key
        day = today
    }

    /// Ratchets to today and forgets yesterday's key after 12:00 UTC. True if anything changed.
    mutating func refresh(nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        let before = (dayKey, day, previousKey)
        advance(to: MeshCrypto.day(of: nowMs))
        if previousKey != nil, nowMs >= day * MeshCrypto.dayMs + 12 * MeshCrypto.hourMs { previousKey = nil }
        return before.0 != dayKey || before.1 != day || before.2 != previousKey
    }

    /// The key for `packetDay`, or nil if it's too old or too far ahead.
    func key(forDay packetDay: UInt64, nowMs: UInt64) -> Data? {
        if packetDay == day { return dayKey }
        if packetDay == day + 1 { return Self.ratchet(dayKey) }
        if packetDay + 1 == day, let previousKey, nowMs < day * MeshCrypto.dayMs + 12 * MeshCrypto.hourMs {
            return previousKey
        }
        return nil
    }
}

/// The pair key chain of two linked contacts. Starts at d0 = max(both seeds' days) with the root key.
struct MeshPairKeys: Codable, Equatable, MeshDailyKeyChain {
    var dayKey: Data
    var day: UInt64
    var previousKey: Data?

    static func ratchet(_ key: Data) -> Data { MeshCrypto.contactRatchet(key) }
}

extension MeshCrypto {
    /// key(d0) and our role: the seeds ordered as unsigned bytes. Nil for equal seeds or wrong sizes.
    static func contactRoot(mySeed: Data, theirSeed: Data) -> (key: Data, myRole: UInt8)? {
        guard mySeed.count == 32, theirSeed.count == 32, mySeed != theirSeed else { return nil }
        let mineFirst = mySeed.lexicographicallyPrecedes(theirSeed)
        let (lo, hi) = mineFirst ? (mySeed, theirSeed) : (theirSeed, mySeed)
        return (hkdf(lo + hi, info: MeshV3.contactRootInfo), mineFirst ? 0 : 1)
    }

    static func contactRatchet(_ dayKey: Data) -> Data { hkdf(dayKey, info: MeshV3.contactRatchetInfo) }
    static func contactMessageKey(_ dayKey: Data) -> Data { hkdf(dayKey, info: MeshV3.contactMessageInfo) }

    /// `dayKey` must be the pair key for `day(of: timestamp)`.
    static func contactTag(dayKey: Data, timestamp: UInt64) -> Data {
        hourTag(dayKey: dayKey, timestamp: timestamp, info: MeshV3.contactTagInfo)
    }

    // MARK: CONTACT (type 5, version 3): target = tag, payload = nonce(12) | AES-GCM(body), AAD as v2

    /// New packet signed by a one-time key. `dayKey` must be the pair key for `day(of: timestamp)`.
    static func sealContact(_ body: MeshContactBody, dayKey: Data, timestamp: UInt64,
                            messageId: Data = randomBytes(16), nonce: Data? = nil,
                            outerKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) -> MeshPacket? {
        let originKey = outerKey.publicKey.x963Representation
        var p = MeshPacket(version: MeshWire.v3, type: MeshPacketType.contact.rawValue,
                           ttl: MeshV3.contactMaxTtl, maxTtl: MeshV3.contactMaxTtl,
                           messageId: messageId, origin: origin(of: originKey), timestamp: timestamp,
                           target: contactTag(dayKey: dayKey, timestamp: timestamp), originKey: originKey,
                           payload: Data(), signature: Data())
        guard let sealed = aesSeal(body.encoded(), key: contactMessageKey(dayKey), aad: p.aad, nonce: nonce) else { return nil }
        p.payload = sealed.nonce + sealed.ciphertextAndTag
        guard p.payload.count <= MeshWire.maxPayload else { return nil }
        p.signature = sign(p.signedBytes, with: outerKey)
        return p
    }

    /// `dayKey` must be the pair key for the packet's day. Nil unless the tag matches and it decrypts.
    static func openContact(_ p: MeshPacket, dayKey: Data) -> MeshContactBody? {
        guard p.version == MeshWire.v3, p.type == MeshPacketType.contact.rawValue, p.payload.count >= 12 + 18 + 16,
              p.target == contactTag(dayKey: dayKey, timestamp: p.timestamp),
              let plain = aesOpen(Data(p.payload.dropFirst(12)), nonce: Data(p.payload.prefix(12)),
                                  key: contactMessageKey(dayKey), aad: p.aad)
        else { return nil }
        return MeshContactBody.decode(plain)
    }
}

// MARK: - Media header
// mediaType(u8) | totalSize(u32) | chunkCount(u8) | sha256(32) | mediaKey(32) | mediaId(8) |
// durationMs(u32) | width(u16) | height(u16) | nickLen(u8) | nick | captionLen(u16) | caption UTF-8

enum MeshMediaType: UInt8 {
    /// JPEG re-encoded from pixels (no EXIF or location), long edge ≤ 1024.
    case photo = 1
    /// AAC in .m4a, mono 16 kHz, ≤ 30 s.
    case voice = 2

    var maxBytes: Int { self == .photo ? MeshV3.photoMaxBytes : MeshV3.voiceMaxBytes }
}

struct MeshMediaHeader: Equatable {
    var mediaType: UInt8
    var totalSize: UInt32
    var chunkCount: UInt8
    var sha256: Data
    /// Random per item; chunks are encrypted under HKDF(mediaKey). Never reused for other bytes.
    var mediaKey: Data
    /// Random per item: the chunks' target.
    var mediaId: Data
    var durationMs: UInt32
    var width: UInt16
    var height: UInt16
    /// Team nickname (teams); empty for contacts.
    var nick: String
    var caption: String

    var type: MeshMediaType? { MeshMediaType(rawValue: mediaType) }

    static func chunkCount(for size: Int) -> Int { (size + MeshV3.chunkSize - 1) / MeshV3.chunkSize }

    /// A header for `data` with a fresh media key and ID; nil if `data` is too big for its type.
    static func make(_ type: MeshMediaType, data: Data, durationMs: UInt32 = 0, width: UInt16 = 0, height: UInt16 = 0,
                     nick: String = "", caption: String = "") -> MeshMediaHeader? {
        guard !data.isEmpty, data.count <= type.maxBytes else { return nil }
        let h = MeshMediaHeader(mediaType: type.rawValue, totalSize: UInt32(data.count),
                                chunkCount: UInt8(chunkCount(for: data.count)), sha256: MeshCrypto.sha256(data),
                                mediaKey: MeshCrypto.randomBytes(32), mediaId: MeshCrypto.randomBytes(8),
                                durationMs: durationMs, width: width, height: height,
                                nick: nick.utf8Prefix(maxBytes: MeshWire.maxNickBytes),
                                caption: caption.utf8Prefix(maxBytes: MeshV3.maxCaptionBytes))
        return h.isValid ? h : nil
    }

    /// The receiver's checks: known type, size within its limit, chunk count = ceil(size / 1536) ≤ 48.
    var isValid: Bool {
        guard let type, totalSize > 0, Int(totalSize) <= type.maxBytes,
              Int(chunkCount) == MeshMediaHeader.chunkCount(for: Int(totalSize)), Int(chunkCount) <= MeshV3.maxChunks,
              sha256.count == 32, mediaKey.count == 32, mediaId.count == 8,
              nick.utf8.count <= MeshWire.maxNickBytes, caption.utf8.count <= MeshV3.maxCaptionBytes
        else { return false }
        return true
    }

    func encoded() -> Data {
        var d = Data([mediaType])
        d.append(Data(u32: totalSize))
        d.append(chunkCount)
        d.append(sha256)
        d.append(mediaKey)
        d.append(mediaId)
        d.append(Data(u32: durationMs))
        d.appendU16(width)
        d.appendU16(height)
        let n = Data(nick.utf8)
        d.append(UInt8(n.count))
        d.append(n)
        let c = Data(caption.utf8)
        d.appendU16(UInt16(c.count))
        d.append(c)
        return d
    }

    /// Nil unless well-formed and `isValid`. Trailing bytes are ignored (room for later fields).
    static func decode(_ data: Data) -> MeshMediaHeader? {
        let b = [UInt8](data)
        guard b.count >= 87 + 2 else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
        func u32(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
        let nickLen = Int(b[86])
        guard b.count >= 87 + nickLen + 2 else { return nil }
        let captionLen = Int(u16(87 + nickLen))
        let captionStart = 89 + nickLen
        guard b.count >= captionStart + captionLen,
              let nick = String(bytes: b[87..<(87 + nickLen)], encoding: .utf8),
              let caption = String(bytes: b[captionStart..<(captionStart + captionLen)], encoding: .utf8)
        else { return nil }
        let h = MeshMediaHeader(mediaType: b[0], totalSize: u32(1), chunkCount: b[5],
                                sha256: Data(b[6..<38]), mediaKey: Data(b[38..<70]), mediaId: Data(b[70..<78]),
                                durationMs: u32(78), width: u16(82), height: u16(84), nick: nick, caption: caption)
        return h.isValid ? h : nil
    }
}

// MARK: - MEDIA_CHUNK (type 6, version 3): target = mediaId, payload = index(u8) | AES-GCM(data)
// AAD = mediaId(8) | index(1) only (android-alignment-9 §2.6, agreed in ios-alignment-7): every send
// round encrypts a chunk to the same bytes, so a (key, nonce) pair never covers two different AADs.

extension MeshCrypto {
    static func mediaChunkKey(_ mediaKey: Data) -> Data { hkdf(mediaKey, info: MeshV3.mediaChunkInfo) }

    /// 11 zero bytes ‖ index (the key is unique per item); not sent.
    static func chunkNonce(_ index: UInt8) -> Data { Data(count: 11) + Data([index]) }

    static func chunkAAD(mediaId: Data, index: UInt8) -> Data { mediaId + Data([index]) }

    /// Bytes [index × 1536, min((index + 1) × 1536, size)) of `data`.
    static func chunkData(_ data: Data, index: Int) -> Data {
        let d = Data(data)
        return d.subdata(in: (index * MeshV3.chunkSize)..<min((index + 1) * MeshV3.chunkSize, d.count))
    }

    static func sealChunk(index: UInt8, data: Data, chunkKey: Data, mediaId: Data, timestamp: UInt64,
                          signingKey: P256.Signing.PrivateKey, messageId: Data = randomBytes(16)) -> MeshPacket? {
        let originKey = signingKey.publicKey.x963Representation
        var p = MeshPacket(version: MeshWire.v3, type: MeshPacketType.mediaChunk.rawValue,
                           ttl: MeshV3.mediaMaxTtl, maxTtl: MeshV3.mediaMaxTtl,
                           messageId: messageId, origin: origin(of: originKey), timestamp: timestamp,
                           target: mediaId, originKey: originKey, payload: Data(), signature: Data())
        guard let sealed = aesSeal(data, key: chunkKey, aad: chunkAAD(mediaId: mediaId, index: index), nonce: chunkNonce(index))
        else { return nil }
        p.payload = Data([index]) + sealed.ciphertextAndTag
        p.signature = sign(p.signedBytes, with: signingKey)
        return p
    }

    /// The chunk's index and data, or nil if it doesn't decrypt under `chunkKey`.
    static func openChunk(_ p: MeshPacket, chunkKey: Data) -> (index: UInt8, data: Data)? {
        guard p.version == MeshWire.v3, p.type == MeshPacketType.mediaChunk.rawValue, p.payload.count > 1 + 16,
              let index = p.payload.first,
              let plain = aesOpen(Data(p.payload.dropFirst()), nonce: chunkNonce(index), key: chunkKey,
                                  aad: chunkAAD(mediaId: p.target, index: index))
        else { return nil }
        return (index, plain)
    }

    /// Every chunk of one media item for one send round, all signed by one fresh one-time key (so
    /// relays can rate-limit per item). A resend must pass the same bytes and header.
    static func mediaChunks(_ data: Data, header: MeshMediaHeader, timestamp: UInt64,
                            signingKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) -> [MeshPacket] {
        guard data.count == Int(header.totalSize), sha256(data) == header.sha256 else { return [] }
        let key = mediaChunkKey(header.mediaKey)
        return (0..<Int(header.chunkCount)).compactMap { i in
            sealChunk(index: UInt8(i), data: chunkData(data, index: i), chunkKey: key,
                      mediaId: header.mediaId, timestamp: timestamp, signingKey: signingKey)
        }
    }
}

// MARK: - Reassembly

/// Collects MEDIA_CHUNK packets per mediaId until an item is complete. Chunks can arrive before the
/// header: unknown mediaIds are held (at most 2 items or 100 chunks, for 10 min). Not thread-safe;
/// time comes from the caller.
final class MeshMediaAssembler {
    enum Event: Equatable {
        case progress(mediaId: Data, received: Int, total: Int)
        /// Size and SHA-256 checked.
        case complete(mediaId: Data, data: Data)
        /// All chunks arrived but the size or hash is wrong.
        case failed(mediaId: Data)
    }

    static let unknownMaxItems = 2
    static let unknownMaxChunks = 100
    static let unknownMaxAge: TimeInterval = 10 * 60
    static let expectedMaxItems = 16
    static let expectedMaxAge: TimeInterval = 60 * 60

    private struct Expected {
        let header: MeshMediaHeader
        let chunkKey: Data
        var parts: [Data?]
        var received = 0
        let since: TimeInterval
    }

    private struct Unknown {
        var chunks: [UInt8: MeshPacket] = [:]
        let since: TimeInterval
    }

    private var expected: [Data: Expected] = [:]
    private var unknown: [Data: Unknown] = [:]
    /// Completed items: later copies of their chunks (resends) are ignored.
    private var done: [Data] = []

    var pendingCount: Int { expected.count }

    /// After a header is accepted (decrypted and valid). Returns events for chunks already held.
    func expect(_ header: MeshMediaHeader, now: TimeInterval) -> [Event] {
        expire(now)
        let id = header.mediaId
        guard header.isValid, !done.contains(id) else { return [] }
        if let e = expected[id] {
            // A resend of a header we're already assembling: keep the progress if it's the same item.
            guard e.header != header else { return [] }
            expected[id] = nil
        }
        if expected.count >= MeshMediaAssembler.expectedMaxItems,
           let oldest = expected.min(by: { $0.value.since < $1.value.since })?.key {
            expected[oldest] = nil
        }
        expected[id] = Expected(header: header, chunkKey: MeshCrypto.mediaChunkKey(header.mediaKey),
                                parts: Array(repeating: nil, count: Int(header.chunkCount)), since: now)
        var events: [Event] = []
        for chunk in (unknown.removeValue(forKey: id)?.chunks.values).map(Array.init) ?? [] {
            if let e = add(chunk, now: now) { events.append(e) }
        }
        return events
    }

    /// A verified MEDIA_CHUNK packet. Nil when it changes nothing visible (held, duplicate, bad).
    func add(_ p: MeshPacket, now: TimeInterval) -> Event? {
        let id = p.target
        guard p.type == MeshPacketType.mediaChunk.rawValue, let index = p.payload.first, !done.contains(id) else { return nil }
        guard var e = expected[id] else {
            hold(p, index: index, now: now)
            return nil
        }
        let i = Int(index)
        guard i < e.parts.count, e.parts[i] == nil,
              let opened = MeshCrypto.openChunk(p, chunkKey: e.chunkKey), opened.index == index
        else { return nil }
        let size = Int(e.header.totalSize)
        let expectedLength = i == e.parts.count - 1 ? size - i * MeshV3.chunkSize : MeshV3.chunkSize
        guard opened.data.count == expectedLength else { return nil }
        e.parts[i] = opened.data
        e.received += 1
        guard e.received == e.parts.count else {
            expected[id] = e
            return .progress(mediaId: id, received: e.received, total: e.parts.count)
        }
        expected[id] = nil
        let joined = e.parts.reduce(into: Data()) { $0.append($1!) }
        guard joined.count == size, MeshCrypto.sha256(joined) == e.header.sha256 else { return .failed(mediaId: id) }
        done = Array((done + [id]).suffix(256))
        return .complete(mediaId: id, data: joined)
    }

    /// Stops collecting an item (its chat was deleted, say).
    func cancel(_ mediaId: Data) {
        expected[mediaId] = nil
        unknown[mediaId] = nil
    }

    func expire(_ now: TimeInterval) {
        expected = expected.filter { now - $0.value.since <= MeshMediaAssembler.expectedMaxAge }
        unknown = unknown.filter { now - $0.value.since <= MeshMediaAssembler.unknownMaxAge }
    }

    func reset() {
        expected = [:]
        unknown = [:]
        done = []
    }

    private func hold(_ p: MeshPacket, index: UInt8, now: TimeInterval) {
        expire(now)
        let id = p.target
        if unknown[id] == nil {
            if unknown.count >= MeshMediaAssembler.unknownMaxItems,
               let oldest = unknown.min(by: { $0.value.since < $1.value.since })?.key {
                unknown[oldest] = nil
            }
            unknown[id] = Unknown(since: now)
        }
        guard unknown[id]?.chunks[index] == nil, Int(index) < MeshV3.maxChunks else { return }
        let held = unknown.values.reduce(0) { $0 + $1.chunks.count }
        guard held < MeshMediaAssembler.unknownMaxChunks else { return }
        unknown[id]?.chunks[index] = p
    }
}

// MARK: - Voice note files

/// iOS's recorder reserves a large `free` atom (about 24 KB) in each .m4a for its index to grow into.
/// On the mesh every byte counts, so it's cut out before sending, and the chunk offsets (`stco` /
/// `co64`) that point past it are moved back. Anything unexpected returns the file unchanged.
enum MeshM4A {
    static func compact(_ data: Data) -> Data {
        let b = [UInt8](data)
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        func type(_ i: Int) -> String { String(bytes: b[(i + 4)..<(i + 8)], encoding: .ascii) ?? "" }
        // Top-level atoms (32-bit sizes only; voice notes are tiny).
        var atoms: [(type: String, start: Int, size: Int)] = []
        var i = 0
        while i + 8 <= b.count {
            let size = u32(i)
            guard size >= 8, i + size <= b.count else { return data }
            atoms.append((type(i), i, size))
            i += size
        }
        guard i == b.count,
              let free = atoms.first(where: { $0.type == "free" }),
              let moov = atoms.first(where: { $0.type == "moov" }),
              let mdat = atoms.first(where: { $0.type == "mdat" }),
              free.start < mdat.start
        else { return data }
        var out = b
        // Offsets past the cut move back by its size; patch them in moov (before cutting, if moov
        // comes first; its position doesn't change then).
        var patched = true
        func patch(_ start: Int, _ end: Int) {
            var j = start
            while j + 8 <= end {
                let size = u32(j), t = type(j)
                guard size >= 8, j + size <= end else { patched = false; return }
                switch t {
                case "trak", "mdia", "minf", "stbl":
                    patch(j + 8, j + size)
                case "stco":
                    let count = u32(j + 12)
                    guard j + 16 + 4 * count <= j + size else { patched = false; return }
                    for k in 0..<count {
                        let at = j + 16 + 4 * k
                        let v = u32(at)
                        guard v >= free.start + free.size else { continue }
                        let nv = UInt32(v - free.size)
                        out[at] = UInt8(nv >> 24); out[at + 1] = UInt8(nv >> 16 & 0xff)
                        out[at + 2] = UInt8(nv >> 8 & 0xff); out[at + 3] = UInt8(nv & 0xff)
                    }
                case "co64":
                    patched = false   // not produced for files this small
                    return
                default:
                    break
                }
                j += size
            }
        }
        patch(moov.start + 8, moov.start + moov.size)
        guard patched else { return data }
        out.removeSubrange(free.start..<(free.start + free.size))
        return Data(out)
    }
}
