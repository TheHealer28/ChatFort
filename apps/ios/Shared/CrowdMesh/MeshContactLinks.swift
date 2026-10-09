//
//  MeshContactLinks.swift
//  ChatFort — Crowd mesh
//
//  Linking two ChatFort contacts for the mesh (wire v3): while online, each side sends a random
//  32-byte seed inside their ChatFort chat; both derive the same pair key from the two seeds. Seeds
//  are forgotten once linked (only SHA-256 of theirs is kept), except an answer we sent, kept up to
//  7 days so a repeated offer gets the identical answer. Pure logic, also in the macOS tests.
//

import Foundation

/// The link message's fields (sent as hidden chat message content "chatfortMeshLink").
struct MeshLinkOffer: Equatable {
    var seed: Data
    /// Days since 1970 (UTC) when the sender made the seed.
    var day: UInt64
    /// false: "here is my seed"; true: the answer to an offer.
    var ack: Bool
}

/// One contact's mesh link state. Persisted (Keychain) per binding.
struct MeshContactLink: Codable, Equatable {
    static let reofferAfterMs: UInt64 = 3 * 86_400_000
    static let maxOffers = 2
    /// How long our answer is kept for repeats (until the partner's first CONTACT packet confirms the link).
    static let keepAnswerMs: UInt64 = 7 * 86_400_000

    /// Our offer waiting for an answer.
    private(set) var pendingSeed: Data?
    private(set) var pendingDay: UInt64 = 0
    /// Offers (ack false) confirmed sent while unanswered: the first, and one re-send after 3 days.
    private(set) var offersSent = 0
    private(set) var lastOfferMs: UInt64 = 0
    /// Linked: the pair key chain (from d0), our role, SHA-256 of their seed.
    private(set) var keys: MeshPairKeys?
    private(set) var myRole: UInt8 = 0
    private(set) var theirSeedHash: Data?
    /// The answer (ack true) we sent when linking to their offer, kept for repeats of that offer.
    private(set) var answerSeed: Data?
    private(set) var answerDay: UInt64 = 0
    private(set) var answerUntilMs: UInt64 = 0
    /// The answer still has to go out (survives the app being stopped before it's sent).
    private(set) var answerUnsent = false

    var isLinked: Bool { keys != nil }

    init() {}

    /// The offer to send now, if any: the first one (again, until it's confirmed sent), or the single
    /// re-send of an unanswered offer after 3 days (contacts on older apps see the fallback text, so
    /// never more than two). Call `offerSent` once it's out. The seed is kept before sending, so an
    /// answer that races the send still links.
    mutating func offerToSend(nowMs: UInt64, newSeed: () -> Data = { MeshCrypto.randomBytes(32) }) -> MeshLinkOffer? {
        guard keys == nil, offersSent < MeshContactLink.maxOffers else { return nil }
        if pendingSeed == nil {
            guard offersSent == 0 else { return nil }
            pendingSeed = newSeed()
            pendingDay = MeshCrypto.day(of: nowMs)
        }
        guard let seed = pendingSeed else { return nil }
        if offersSent == 1, nowMs < lastOfferMs + MeshContactLink.reofferAfterMs { return nil }
        return MeshLinkOffer(seed: seed, day: pendingDay, ack: false)
    }

    /// The offer (ack false) went out.
    mutating func offerSent(_ offer: MeshLinkOffer, nowMs: UInt64) {
        guard !offer.ack, offer.seed == pendingSeed else { return }
        offersSent += 1
        lastOfferMs = nowMs
    }

    /// Our answer, if it still has to go out (it was created but the app stopped before sending).
    func unsentAnswer(nowMs: UInt64) -> MeshLinkOffer? {
        guard answerUnsent, let seed = answerSeed, nowMs < answerUntilMs else { return nil }
        return MeshLinkOffer(seed: seed, day: answerDay, ack: true)
    }

    /// The answer (ack true) went out.
    mutating func answerSent(_ offer: MeshLinkOffer) {
        if offer.ack, offer.seed == answerSeed { answerUnsent = false }
    }

    /// A CONTACT packet from the partner decrypted: both sides hold the pair key, the answer can go.
    mutating func confirmLinked() {
        answerSeed = nil
        answerDay = 0
        answerUntilMs = 0
        answerUnsent = false
    }

    /// Applies a received link message; returns the message to send back, if any.
    /// - An answer (ack true) links our pending offer; with no pending offer it's ignored (no loops).
    /// - An offer while our own is pending links to it with no reply: both sides reach the same pair.
    ///   Our offered seed is kept as the answer (already sent), so if they never saw our offer and
    ///   repeat theirs, they get it and link to the same pair (ios-alignment-7 §4.1).
    /// - An offer we already linked to (a repeat or a queued second copy) gets the identical answer
    ///   again, never a new seed: a new seed would leave the two sides on different keys.
    /// - Any other offer (first contact, or a partner who reset) links with a new seed of ours, sent
    ///   back with ack true.
    mutating func receive(_ offer: MeshLinkOffer, nowMs: UInt64,
                          newSeed: () -> Data = { MeshCrypto.randomBytes(32) }) -> MeshLinkOffer? {
        guard offer.seed.count == 32 else { return nil }
        let theirHash = MeshCrypto.sha256(offer.seed)
        if offer.ack {
            guard theirSeedHash != theirHash, let mine = pendingSeed else { return nil }
            return link(mySeed: mine, myDay: pendingDay, offer, theirHash, nowMs: nowMs, keep: .nothing, newSeed: newSeed)
        }
        if keys == nil, let mine = pendingSeed {
            return link(mySeed: mine, myDay: pendingDay, offer, theirHash, nowMs: nowMs, keep: .sentOffer, newSeed: newSeed)
        }
        if keys != nil, theirSeedHash == theirHash {
            guard let seed = answerSeed, nowMs < answerUntilMs else { return nil }
            answerUnsent = true
            return MeshLinkOffer(seed: seed, day: answerDay, ack: true)
        }
        let mine = newSeed()
        let today = MeshCrypto.day(of: nowMs)
        if let retry = link(mySeed: mine, myDay: today, offer, theirHash, nowMs: nowMs, keep: .newAnswer, newSeed: newSeed) {
            return retry
        }
        return MeshLinkOffer(seed: mine, day: today, ack: true)
    }

    /// Ratchets the pair key to today (dropping yesterday's after 12:00 UTC) and forgets an old
    /// answer. True if anything changed.
    mutating func refreshKeys(nowMs: UInt64) -> Bool {
        var changed = false
        if answerSeed != nil, nowMs >= answerUntilMs {
            confirmLinked()
            changed = true
        }
        if var k = keys, k.refresh(nowMs: nowMs) {
            keys = k
            changed = true
        }
        return changed
    }

    private enum KeptAnswer {
        /// They answered our offer: nothing to keep.
        case nothing
        /// Crossing offers: our offer (already sent) answers a repeat of theirs.
        case sentOffer
        /// We answer their offer with a new seed (still to be sent).
        case newAnswer
    }

    /// Links (forgetting both seeds, except our answer), or, for equal seeds, makes a new offer.
    private mutating func link(mySeed: Data, myDay: UInt64, _ offer: MeshLinkOffer, _ theirHash: Data,
                               nowMs: UInt64, keep: KeptAnswer, newSeed: () -> Data) -> MeshLinkOffer? {
        guard let root = MeshCrypto.contactRoot(mySeed: mySeed, theirSeed: offer.seed) else {
            let seed = newSeed()
            pendingSeed = seed
            pendingDay = MeshCrypto.day(of: nowMs)
            offersSent = 0
            keys = nil
            theirSeedHash = nil
            confirmLinked()
            return MeshLinkOffer(seed: seed, day: pendingDay, ack: false)
        }
        var k = MeshPairKeys(dayKey: root.key, day: max(myDay, offer.day), previousKey: nil)
        _ = k.refresh(nowMs: nowMs)
        keys = k
        myRole = root.myRole
        theirSeedHash = theirHash
        pendingSeed = nil
        pendingDay = 0
        switch keep {
        case .nothing:
            confirmLinked()
        case .sentOffer, .newAnswer:
            answerSeed = mySeed
            answerDay = myDay
            answerUntilMs = nowMs + MeshContactLink.keepAnswerMs
            answerUnsent = keep == .newAnswer
        }
        return nil
    }
}
