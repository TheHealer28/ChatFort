//
//  MeshRouter.swift
//  ChatFort — Crowd mesh
//
//  Moves mesh packets through the crowd: floods them over Bluetooth links, keeps recent ones for
//  people who arrive later, and relays future-version packets unread. Port of Android's v1
//  MeshRouter with the v2 changes in ios-alignment-2.md §2 and the v3 types (CONTACT, MEDIA_CHUNK)
//  of ios-alignment-6.md. It never decrypts: CHANNEL, DIRECT and CONTACT are sealed, and their
//  origin is a one-time key. Media chunks have their own limits and store. Foundation only and no
//  timers of its own (time and scheduling come from the host), so it also runs in the macOS tests.
//

import Foundation

typealias MeshLinkID = Int

/// `.bulk` frames are catch-up answers and may wait behind `.live` traffic.
enum MeshPriority { case live, bulk }

/// Live packets are flooded: a phone relays a new packet once, after a short random delay, to every
/// neighbour that doesn't already hold it with as many hops left, until its ttl runs out. Neighbours
/// swap inventories of stored packet IDs (on link-up and every minute) and pull what they miss, so
/// people who arrive late or were cut off catch up.
///
/// Single-threaded: the host calls everything on one serial queue; callbacks are synchronous.
/// `deliver` may call `originate` (to send an ACK, say). `sendFrame` must only queue the frame and
/// never call back into the router.
final class MeshRouter {
    struct Config {
        /// Packet IDs remembered for dedup. The oldest are forgotten first, and every entry is
        /// forgotten 2 × `timestampWindowMs` after the packet's timestamp.
        var seenCapacity = 50_000
        /// Future-version frame IDs remembered for dedup.
        var opaqueSeenCapacity = 10_000
        /// Packets whose timestamp is further than this from the local clock, either way, are dropped.
        var timestampWindowMs: UInt64 = 6 * 3_600_000

        var storeCapacity = 300
        var storeMaxAge: TimeInterval = 60 * 60
        /// Most packets kept per sender identity (origin), own ones included.
        var storePerIdentity = 30
        /// MEDIA_CHUNK packets are kept apart, so photos never push text out.
        var mediaStoreCapacity = 240
        var mediaStoreMaxAge: TimeInterval = 60 * 60
        /// Per origin key: one key signs one media item's chunks.
        var mediaStorePerIdentity = 48

        var relayJitterMin: TimeInterval = 0.015
        var relayJitterMax: TimeInterval = 0.120
        /// On link-up, our last ANNOUNCE is sent if it is younger than this.
        var announceFreshFor: TimeInterval = 5 * 60
        /// Largest future-version frame relayed.
        var maxOpaqueBytes = MeshWire.maxFrame

        // Rate limits: token buckets that hold one minute's worth.
        /// Per sender identity, packets that arrive live.
        var identityLivePerMinute: Double = 30
        /// Per sender identity, packets we asked for. Beyond this they are deferred, not seen.
        var identityCatchUpPerMinute: Double = 60
        /// Per link, every new packet.
        var linkPerMinute: Double = 1200
        /// Per link, CHANNEL, DIRECT and CONTACT.
        var linkSealedPerMinute: Double = 240
        /// Per link, MEDIA_CHUNK.
        var linkMediaPerMinute: Double = 180
        /// Per media origin key (one per item), MEDIA_CHUNK that arrive live.
        var mediaIdentityPerMinute: Double = 60
        /// Per link, ANNOUNCE and PUBLIC from identities not seen before.
        var linkNewIdentityPerMinute: Double = 300
        /// Per link, future-version frames.
        var linkOpaquePerMinute: Double = 60
        /// Per link, packets sent in answer to REQUESTs.
        var linkServePerMinute: Double = 300

        /// Most IDs asked for in one REQUEST, and answered from one REQUEST.
        var maxRequested = 200
        /// v2 phones can't mark v3 packets seen (they keep them as opaque), so they ask for every v3 ID
        /// in our inventories again every `requestRetry`: serve each v3 packet to a link at most this
        /// often per `offerMaxAge`. v2 packets are served as before.
        var maxV3ServesPerLink = 2
        /// An unanswered request is sent again after this.
        var requestRetry: TimeInterval = 10
        /// We keep asking for an ID a neighbour offered until this long after its last offer.
        var offerMaxAge: TimeInterval = 10 * 60
        var maxOffersPerLink = 1024
        var resyncEvery: TimeInterval = 60
        /// A resync INVENTORY lists the packets stored within this window.
        var resyncWindow: TimeInterval = 3 * 60

        var knownIdentityCapacity = 10_000
        var maxIdentityBuckets = 10_000
    }

    /// Sends one whole frame to a direct neighbour.
    var sendFrame: (Data, MeshLinkID, MeshPriority) -> Void = { _, _, _ in }
    /// A new, signature-verified packet for the app (not own, not opaque). viaCatchUp = came as a REQUEST answer.
    var deliver: (MeshPacket, _ fromLink: MeshLinkID, _ viaCatchUp: Bool) -> Void = { _, _, _ in }
    /// Run `work` on the router's queue after `delay` seconds (relay jitter, retries). Tests use a virtual clock.
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { _, work in work() }
    /// Monotonic seconds (for rate limits, expiry).
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Wall clock, ms since 1970 (for the ±6 h timestamp window).
    var nowMs: () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }
    var log: (String) -> Void = { _ in }
    /// Uniform in 0..<1, for relay jitter. Tests use a seeded generator.
    var random: () -> Double = { Double.random(in: 0..<1) }

    let config: Config

    init(config: Config = Config()) {
        self.config = config
        seen = MeshFIFOMap(capacity: config.seenCapacity)
        seenOpaque = MeshFIFOMap(capacity: config.opaqueSeenCapacity)
        knownIdentities = MeshFIFOMap(capacity: config.knownIdentityCapacity)
        store = MeshPacketStore(capacity: config.storeCapacity, maxAge: config.storeMaxAge, perIdentity: config.storePerIdentity)
        mediaStore = MeshPacketStore(capacity: config.mediaStoreCapacity, maxAge: config.mediaStoreMaxAge,
                                     perIdentity: config.mediaStorePerIdentity)
    }

    var storedCount: Int { store.count }
    var storedMediaCount: Int { mediaStore.count }
    var linkCount: Int { links.count }

    // MARK: - State

    private static let noRelay = UInt8.max

    private struct Seen {
        /// Most hops-to-live we have had it with; `noRelay` for own and rate-limited packets.
        var ttl: UInt8
        let timestamp: UInt64
    }

    private final class Link {
        var all: MeshTokenBucket
        var sealed: MeshTokenBucket
        var media: MeshTokenBucket
        var newIdentity: MeshTokenBucket
        var opaque: MeshTokenBucket
        var serve: MeshTokenBucket
        /// IDs this neighbour offered that we don't have, in offer order, with when it last offered them.
        var offers: MeshFIFOMap<TimeInterval>
        /// v3 packets served to this neighbour: how often since when.
        var servedV3: MeshFIFOMap<Served>

        init(_ c: Config, _ t: TimeInterval) {
            all = MeshTokenBucket(perMinute: c.linkPerMinute, at: t)
            sealed = MeshTokenBucket(perMinute: c.linkSealedPerMinute, at: t)
            media = MeshTokenBucket(perMinute: c.linkMediaPerMinute, at: t)
            newIdentity = MeshTokenBucket(perMinute: c.linkNewIdentityPerMinute, at: t)
            opaque = MeshTokenBucket(perMinute: c.linkOpaquePerMinute, at: t)
            serve = MeshTokenBucket(perMinute: c.linkServePerMinute, at: t)
            offers = MeshFIFOMap(capacity: c.maxOffersPerLink)
            servedV3 = MeshFIFOMap(capacity: 2048)
        }
    }

    private struct Served {
        var count: Int
        let since: TimeInterval
    }

    /// A relay waiting out its jitter, and the ttl each neighbour already holds the packet with.
    private final class PendingRelay {
        var holders: [MeshLinkID: Int]
        init(_ holders: [MeshLinkID: Int]) { self.holders = holders }
    }

    private var links: [MeshLinkID: Link] = [:]
    /// Up links in the order they came up (sending order).
    private var linkOrder: [MeshLinkID] = []
    private var seen: MeshFIFOMap<Seen>
    private var seenOpaque: MeshFIFOMap<Void>
    /// Packet IDs we asked for, and when.
    private var requested = MeshFIFOMap<TimeInterval>(capacity: 4096)
    /// Caught-up packets deferred by their sender's catch-up limit, with that sender.
    private var deferred = MeshFIFOMap<UInt64>(capacity: 4096)
    /// Deferred packets asked for again with a catch-up token already taken.
    private var prepaid = MeshFIFOMap<Void>(capacity: 4096)
    /// Origins of ANNOUNCE and PUBLIC packets we have accepted.
    private var knownIdentities: MeshFIFOMap<Void>
    /// Origins of our own packets.
    private var ownIdentities = MeshFIFOMap<Void>(capacity: 4096)
    private var liveBuckets: [UInt64: MeshTokenBucket] = [:]
    private var mediaBuckets: [UInt64: MeshTokenBucket] = [:]
    private var catchUpBuckets: [UInt64: MeshTokenBucket] = [:]
    private var store: MeshPacketStore
    private var mediaStore: MeshPacketStore
    private var pendingRelays: [UInt64: PendingRelay] = [:]
    private var lastAnnounce: (bytes: Data, at: TimeInterval)?
    private var lastResync: TimeInterval?
    private var lastSeenSweep: TimeInterval?
    /// Drops since the last tick, by reason, logged as one line.
    private var drops: [String: Int] = [:]

    // MARK: - Host calls

    func linkUp(_ link: MeshLinkID) {
        let t = now()
        if links[link] == nil {
            links[link] = Link(config, t)
            linkOrder.append(link)
        }
        if let a = lastAnnounce, t - a.at < config.announceFreshFor { sendFrame(a.bytes, link, .live) }
        store.prune(t)
        mediaStore.prune(t)
        sendInventory(store.newestFirst() + mediaStore.newestFirst(), to: link)
    }

    func linkDown(_ link: MeshLinkID) {
        guard links.removeValue(forKey: link) != nil else { return }
        linkOrder.removeAll { $0 == link }
    }

    func receive(_ frame: Data, from link: MeshLinkID) {
        guard let l = links[link] else { return }
        let t = now()
        switch MeshFrame.classify(frame) {
        case let .packet(p)?: receivePacket(p, from: link, l, t)
        case let .opaque(raw)?: receiveOpaque(raw, from: link, l, t)
        case let .control(code, ids)?: receiveControl(code, ids, from: link, l, t)
        case nil: drop("malformed")
        }
    }

    /// Own packet: mark seen, store (not ANNOUNCE; remember ANNOUNCE as the last announce), send to all
    /// links. Media chunks go as `.bulk`, behind live text.
    func originate(_ packet: MeshPacket, priority: MeshPriority = .live) {
        let t = now()
        let id = packet.shortId
        let identity = packet.origin.readU64()
        let bytes = packet.encoded()
        ownIdentities.set(identity, ())
        seen.set(id, Seen(ttl: MeshRouter.noRelay, timestamp: packet.timestamp))
        requested.remove(id)
        deferred.remove(id)
        if packet.type == MeshPacketType.announce.rawValue {
            lastAnnounce = (bytes, t)
        } else {
            keep(id, bytes, identity, media: packet.knownTypeAndVersion == .mediaChunk, t)
        }
        for link in linkOrder { sendFrame(bytes, link, priority) }
    }

    /// Every ~5 s: INVENTORY resync, REQUEST retries, expiry of store/seen/limits.
    func tick() {
        let t = now()
        store.prune(t)
        mediaStore.prune(t)
        let forgetRequests = 6 * config.requestRetry
        requested.removeAll { _, at in t - at > forgetRequests }
        let live = config.identityLivePerMinute, catchUp = config.identityCatchUpPerMinute
        liveBuckets = liveBuckets.filter { !$0.value.isFull(live, t) }
        let media = config.mediaIdentityPerMinute
        mediaBuckets = mediaBuckets.filter { !$0.value.isFull(media, t) }
        catchUpBuckets = catchUpBuckets.filter { !$0.value.isFull(catchUp, t) }
        if lastSeenSweep.map({ t - $0 >= 60 }) ?? true {
            lastSeenSweep = t
            // Older than this, a packet would fail the timestamp window anyway.
            let n = nowMs(), forgetAfter = 2 * config.timestampWindowMs
            seen.removeAll { _, s in s.timestamp < n && n - s.timestamp > forgetAfter }
        }
        for link in linkOrder {
            if let l = links[link] { requestMissing(from: link, l, t) }
        }
        if lastResync.map({ t - $0 >= config.resyncEvery }) ?? true {
            lastResync = t
            let window = config.resyncWindow
            let recent = store.newestFirst(storedWithin: window, t) + mediaStore.newestFirst(storedWithin: window, t)
            if !recent.isEmpty {
                for link in linkOrder { sendInventory(recent, to: link) }
            }
        }
        if !drops.isEmpty {
            log("mesh dropped: " + drops.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
            drops = [:]
        }
    }

    /// Forget everything (stop / panic wipe), links included: call `linkUp` again for links still connected.
    func reset() {
        links = [:]
        linkOrder = []
        seen.removeAll()
        seenOpaque.removeAll()
        requested.removeAll()
        deferred.removeAll()
        prepaid.removeAll()
        knownIdentities.removeAll()
        ownIdentities.removeAll()
        liveBuckets = [:]
        mediaBuckets = [:]
        catchUpBuckets = [:]
        store.removeAll()
        mediaStore.removeAll()
        pendingRelays = [:]
        lastAnnounce = nil
        lastResync = nil
        lastSeenSweep = nil
        drops = [:]
    }

    // MARK: - Packets

    private func receivePacket(_ p: MeshPacket, from link: MeshLinkID, _ l: Link, _ t: TimeInterval) {
        let id = p.shortId
        if let s = seen[id] {
            duplicate(p, id, s, from: link, l, t)
            return
        }
        // v2 has four types and v3 two; anything new comes as a new version (relayed unread).
        guard let type = p.knownTypeAndVersion else { reject(id, l, "unknown type"); return }
        guard inTimeWindow(p.timestamp) else { reject(id, l, "outside the time window"); return }
        let media = type == .mediaChunk
        guard !media || p.maxTtl <= MeshV3.mediaMaxTtl else { reject(id, l, "media chunk with maxTtl over 5"); return }
        let sealed = type == .channel || type == .direct || type == .contact
        let identity = p.origin.readU64()
        // Sealed packets always have a fresh origin, so the sealed limit is their new-identity limit;
        // a media item's chunks share one one-time key, limited per link and per key instead.
        let newIdentity = !sealed && !media && !knownIdentities.contains(identity)
        guard admit(l, sealed: sealed, media: media, newIdentity: newIdentity, t) else {
            // Not the packet's fault, so not marked seen. If we asked for it, ask again later.
            if requested.contains(id) { requested.set(id, t) }
            return
        }
        // Verify before marking seen, so forged copies can't block the genuine packet.
        guard p.verifySignature() else { reject(id, l, "invalid signature"); return }
        let caughtUp = requested.remove(id) != nil
        if ownIdentities.contains(identity) {
            seen.set(id, Seen(ttl: MeshRouter.noRelay, timestamp: p.timestamp))
            return
        }
        if !sealed && !media { knownIdentities.set(identity, ()) }
        if caughtUp {
            if prepaid.remove(id) == nil,
               !takeIdentity(&catchUpBuckets, identity, config.identityCatchUpPerMinute, t) {
                // Deferred, not seen: asked for again once this sender's catch-up budget allows.
                deferred.set(id, identity)
                drop("for now (sender over its catch-up limit, fetched again later)")
                return
            }
        } else if !(media ? takeIdentity(&mediaBuckets, identity, config.mediaIdentityPerMinute, t)
                          : takeIdentity(&liveBuckets, identity, config.identityLivePerMinute, t)) {
            // Marked seen, so it is never passed on, not even by a shorter route.
            seen.set(id, Seen(ttl: MeshRouter.noRelay, timestamp: p.timestamp))
            drop("over the sender's live limit")
            return
        }
        deferred.remove(id)
        seen.set(id, Seen(ttl: p.ttl, timestamp: p.timestamp))
        // Out of hops (ttl 1): delivered here, but neither relayed nor kept for others.
        if let forward = p.relayed() {
            let bytes = forward.encoded()
            if type != .announce { keep(id, bytes, identity, media: media, t) }
            // Caught-up packets spread through the next inventory swap instead, so a reconnect
            // doesn't re-flood neighbours that mostly have them already.
            if !caughtUp { scheduleRelay(id, from: link, fromHolds: Int(p.ttl) + 1, bytes: bytes, ttl: forward.ttl) }
        }
        deliver(p, link, caughtUp)
    }

    /// The neighbour holds it with one more hop than the copy it sent us. If this copy has more hops
    /// to live than any we had, it came by a shorter route: flooding can deliver the long way round
    /// first, so pass it on again (without delivering it twice).
    private func duplicate(_ p: MeshPacket, _ id: UInt64, _ s: Seen, from link: MeshLinkID, _ l: Link, _ t: TimeInterval) {
        requested.remove(id)
        if let pending = pendingRelays[id] { pending.holders[link] = max(pending.holders[link] ?? 0, Int(p.ttl) + 1) }
        guard s.ttl != MeshRouter.noRelay, p.ttl > s.ttl, let type = p.knownTypeAndVersion, inTimeWindow(p.timestamp),
              let forward = p.relayed(), l.all.take(config.linkPerMinute, t), p.verifySignature()
        else { return }
        seen.set(id, Seen(ttl: p.ttl, timestamp: s.timestamp))
        let bytes = forward.encoded()
        if type != .announce { keep(id, bytes, p.origin.readU64(), media: type == .mediaChunk, t) }
        scheduleRelay(id, from: link, fromHolds: Int(p.ttl) + 1, bytes: bytes, ttl: forward.ttl)
    }

    /// Future versions: relayed unread (ttl − 1), deduped by opaque ID, never stored or delivered.
    private func receiveOpaque(_ raw: Data, from link: MeshLinkID, _ l: Link, _ t: TimeInterval) {
        let id = MeshWire.opaqueId(raw)
        let ttl = raw[raw.startIndex + 3]
        if seenOpaque.contains(id) {
            if let pending = pendingRelays[id] { pending.holders[link] = max(pending.holders[link] ?? 0, Int(ttl) + 1) }
            return
        }
        guard raw.count <= config.maxOpaqueBytes else { drop("oversized future-version frame"); return }
        guard l.opaque.take(config.linkOpaquePerMinute, t) else { drop("future-version frame over the link limit"); return }
        seenOpaque.set(id, ())
        guard let forward = MeshFrame.relayedOpaque(raw) else { return }
        scheduleRelay(id, from: link, fromHolds: Int(ttl) + 1, bytes: forward, ttl: ttl - 1)
    }

    /// Relays after a random delay to the neighbours that don't hold it with as many hops left.
    private func scheduleRelay(_ id: UInt64, from link: MeshLinkID, fromHolds: Int, bytes: Data, ttl: UInt8) {
        // A newer relay of the same packet supersedes one still waiting, keeping what it learned.
        // `reset()` empties pendingRelays, so relays scheduled before it never fire.
        var holders = pendingRelays[id]?.holders ?? [:]
        holders[link] = max(holders[link] ?? 0, fromHolds)
        let pending = PendingRelay(holders)
        pendingRelays[id] = pending
        let jitter = config.relayJitterMin + max(0, config.relayJitterMax - config.relayJitterMin) * min(max(random(), 0), 1)
        schedule(jitter) { [weak self] in
            guard let self, self.pendingRelays[id] === pending else { return }
            self.pendingRelays[id] = nil
            for link in self.linkOrder where (pending.holders[link] ?? 0) < Int(ttl) {
                self.sendFrame(bytes, link, .live)
            }
        }
    }

    /// Per-link limits: every new packet, sealed ones, media chunks, and ones from identities not seen
    /// before. A packet is taken only if every bucket that applies has a token.
    private func admit(_ l: Link, sealed: Bool, media: Bool, newIdentity: Bool, _ t: TimeInterval) -> Bool {
        l.all.refill(config.linkPerMinute, t)
        l.sealed.refill(config.linkSealedPerMinute, t)
        l.media.refill(config.linkMediaPerMinute, t)
        l.newIdentity.refill(config.linkNewIdentityPerMinute, t)
        guard l.all.tokens >= 1 else { drop("over the link limit"); return false }
        guard !sealed || l.sealed.tokens >= 1 else { drop("over the link's sealed limit"); return false }
        guard !media || l.media.tokens >= 1 else { drop("over the link's media limit"); return false }
        guard !newIdentity || l.newIdentity.tokens >= 1 else { drop("over the link's new-identity limit"); return false }
        l.all.tokens -= 1
        if sealed { l.sealed.tokens -= 1 }
        if media { l.media.tokens -= 1 }
        if newIdentity { l.newIdentity.tokens -= 1 }
        return true
    }

    private func takeIdentity(_ buckets: inout [UInt64: MeshTokenBucket], _ identity: UInt64,
                              _ perMinute: Double, _ t: TimeInterval) -> Bool {
        if buckets[identity] == nil {
            if buckets.count >= config.maxIdentityBuckets {
                buckets = buckets.filter { !$0.value.isFull(perMinute, t) }
                if buckets.count >= config.maxIdentityBuckets { buckets.remove(at: buckets.startIndex) }
            }
            buckets[identity] = MeshTokenBucket(perMinute: perMinute, at: t)
        }
        return buckets[identity]!.take(perMinute, t)
    }

    private func inTimeWindow(_ timestamp: UInt64) -> Bool {
        let n = nowMs()
        return (timestamp >= n ? timestamp - n : n - timestamp) <= config.timestampWindowMs
    }

    /// Dropped, not marked seen (a genuine copy may still come), and not asked of this neighbour again.
    private func reject(_ id: UInt64, _ l: Link, _ reason: String) {
        drop(reason)
        l.offers.remove(id)
    }

    private func drop(_ reason: String) { drops[reason, default: 0] += 1 }

    // MARK: - Store-and-forward

    private func receiveControl(_ code: MeshControlCode, _ ids: [UInt64], from link: MeshLinkID, _ l: Link, _ t: TimeInterval) {
        switch code {
        case .inventory:
            for id in ids where !seen.contains(id) { l.offers.set(id, t) }
            requestMissing(from: link, l, t)
        case .request:
            store.prune(t)
            mediaStore.prune(t)
            for id in ids.prefix(config.maxRequested) {
                guard let bytes = store.bytes(id) ?? mediaStore.bytes(id) else { continue }
                let isV3 = bytes.count > 1 && bytes[bytes.startIndex + 1] == MeshWire.v3
                var served = l.servedV3[id].flatMap { t - $0.since < config.offerMaxAge ? $0 : nil } ?? Served(count: 0, since: t)
                if isV3, served.count >= config.maxV3ServesPerLink { drop("repeated REQUEST for a v3 packet"); continue }
                guard l.serve.take(config.linkServePerMinute, t) else { drop("REQUEST over the serve limit"); break }
                sendFrame(bytes, link, .bulk)
                if isV3 {
                    served.count += 1
                    l.servedV3.set(id, served)
                }
            }
        }
    }

    /// Asks `link` for what it offered and we still miss: new offers, requests unanswered for
    /// `requestRetry`, and deferred packets once their sender's catch-up budget allows.
    private func requestMissing(from link: MeshLinkID, _ l: Link, _ t: TimeInterval) {
        var ids: [UInt64] = []
        var stale: [UInt64] = []
        l.offers.forEachInOrder { id, offeredAt in
            if seen.contains(id) || t - offeredAt > config.offerMaxAge {
                stale.append(id)
                return true
            }
            if let at = requested[id], t - at < config.requestRetry { return true }
            if let identity = deferred[id] {
                guard takeIdentity(&catchUpBuckets, identity, config.identityCatchUpPerMinute, t) else { return true }
                prepaid.set(id, ())
            }
            ids.append(id)
            return ids.count < config.maxRequested
        }
        stale.forEach { l.offers.remove($0) }
        guard !ids.isEmpty else { return }
        ids.forEach { requested.set($0, t) }
        sendFrame(MeshFrame.control(.request, ids), link, .live)
    }

    /// Text packets newest first, then media chunks newest first, in frames of ≤ 512 IDs.
    private func sendInventory(_ newestFirst: [UInt64], to link: MeshLinkID) {
        var start = 0
        while start < newestFirst.count {
            let end = min(newestFirst.count, start + MeshWire.maxControlIds)
            sendFrame(MeshFrame.control(.inventory, Array(newestFirst[start..<end])), link, .live)
            start = end
        }
    }

    /// Stores (or re-stores, as newest) a packet in the text or media store.
    private func keep(_ id: UInt64, _ bytes: Data, _ identity: UInt64, media: Bool, _ t: TimeInterval) {
        if media {
            store.remove(id)
            mediaStore.keep(id, bytes, identity, t)
        } else {
            mediaStore.remove(id)
            store.keep(id, bytes, identity, t)
        }
    }
}

// MARK: - Helpers

/// Recent packets kept for neighbours who arrive later: at most `capacity`, for `maxAge`, and at most
/// `perIdentity` per sender identity (origin).
private struct MeshPacketStore {
    private struct Stored {
        /// Encoded as served: our own packets as sent, others with ttl − 1 (as relayed).
        let bytes: Data
        let identity: UInt64
        let storedAt: TimeInterval
    }

    let capacity: Int
    let maxAge: TimeInterval
    let perIdentity: Int
    private var stored: [UInt64: Stored] = [:]
    /// Stored IDs, oldest first.
    private var order: [UInt64] = []
    private var countPerIdentity: [UInt64: Int] = [:]

    init(capacity: Int, maxAge: TimeInterval, perIdentity: Int) {
        self.capacity = capacity
        self.maxAge = maxAge
        self.perIdentity = perIdentity
    }

    var count: Int { stored.count }
    func bytes(_ id: UInt64) -> Data? { stored[id]?.bytes }

    func newestFirst() -> [UInt64] { order.reversed() }

    func newestFirst(storedWithin window: TimeInterval, _ t: TimeInterval) -> [UInt64] {
        order.reversed().filter { id in stored[id].map { t - $0.storedAt < window } ?? false }
    }

    /// Stores (or re-stores, as newest) a packet, keeping at most `perIdentity` per sender.
    mutating func keep(_ id: UInt64, _ bytes: Data, _ identity: UInt64, _ t: TimeInterval) {
        guard capacity > 0, perIdentity > 0 else { return }
        remove(id)
        if countPerIdentity[identity, default: 0] >= perIdentity,
           let oldest = order.first(where: { stored[$0]?.identity == identity }) {
            remove(oldest)
        }
        stored[id] = Stored(bytes: bytes, identity: identity, storedAt: t)
        order.append(id)
        countPerIdentity[identity, default: 0] += 1
        prune(t)
    }

    mutating func remove(_ id: UInt64) {
        guard let s = stored.removeValue(forKey: id) else { return }
        if let i = order.firstIndex(of: id) { order.remove(at: i) }
        let left = (countPerIdentity[s.identity] ?? 1) - 1
        countPerIdentity[s.identity] = left > 0 ? left : nil
    }

    mutating func prune(_ t: TimeInterval) {
        while let id = order.first, let s = stored[id], stored.count > capacity || t - s.storedAt > maxAge {
            remove(id)
        }
    }

    mutating func removeAll() {
        stored = [:]
        order = []
        countPerIdentity = [:]
    }
}

/// Refills continuously up to one minute's worth.
private struct MeshTokenBucket {
    var tokens: Double
    private var at: TimeInterval

    init(perMinute: Double, at t: TimeInterval) {
        tokens = perMinute
        at = t
    }

    mutating func refill(_ perMinute: Double, _ t: TimeInterval) {
        guard t > at else { return }
        tokens = min(perMinute, tokens + (t - at) * perMinute / 60)
        at = t
    }

    mutating func take(_ perMinute: Double, _ t: TimeInterval) -> Bool {
        refill(perMinute, t)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    /// Full again, so the same as a new bucket.
    func isFull(_ perMinute: Double, _ t: TimeInterval) -> Bool {
        tokens + max(0, t - at) * perMinute / 60 >= perMinute
    }
}

/// A dictionary keyed by 64-bit IDs that forgets its oldest insertions beyond `capacity`.
/// Updating a key keeps its place.
private struct MeshFIFOMap<Value> {
    private struct Entry {
        var value: Value
        let seq: Int
    }

    let capacity: Int
    private var dict: [UInt64: Entry] = [:]
    /// Insertion order; entries whose seq no longer matches were removed.
    private var order: [(key: UInt64, seq: Int)] = []
    private var head = 0
    private var nextSeq = 0

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { dict.count }
    subscript(key: UInt64) -> Value? { dict[key]?.value }
    func contains(_ key: UInt64) -> Bool { dict[key] != nil }

    mutating func set(_ key: UInt64, _ value: Value) {
        if dict[key] != nil {
            dict[key]!.value = value
            return
        }
        dict[key] = Entry(value: value, seq: nextSeq)
        order.append((key, nextSeq))
        nextSeq += 1
        while dict.count > capacity, head < order.count {
            let o = order[head]
            head += 1
            if dict[o.key]?.seq == o.seq { dict[o.key] = nil }
        }
        compact()
    }

    @discardableResult
    mutating func remove(_ key: UInt64) -> Value? { dict.removeValue(forKey: key)?.value }

    mutating func removeAll(where shouldRemove: (UInt64, Value) -> Bool) {
        dict = dict.filter { !shouldRemove($0.key, $0.value.value) }
        compact()
    }

    mutating func removeAll() {
        dict = [:]
        order = []
        head = 0
    }

    /// Live entries, oldest first, until `body` returns false.
    func forEachInOrder(_ body: (UInt64, Value) -> Bool) {
        for o in order[head...] {
            guard let e = dict[o.key], e.seq == o.seq else { continue }
            if !body(o.key, e.value) { return }
        }
    }

    private mutating func compact() {
        if order.count - head > 2 * dict.count + 1024 {
            let d = dict
            order = order[head...].filter { d[$0.key]?.seq == $0.seq }
            head = 0
        } else if head > 4096, head * 2 > order.count {
            order.removeFirst(head)
            head = 0
        }
    }
}
