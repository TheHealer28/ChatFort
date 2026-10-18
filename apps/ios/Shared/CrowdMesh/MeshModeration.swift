//
//  MeshModeration.swift
//  ChatFort — Crowd mesh
//
//  Blocking and the word filter for the crowd mesh (the safeguards App Review asks of apps with
//  user-generated content, Guideline 1.2). Pure logic, also in the macOS tests.
//

import Foundation

/// People the user blocked in the crowd mesh. Mesh identities rotate (a new key on every start and
/// every 15 minutes), so a block matches three things: the sender's peer IDs, their private-chat
/// contact (which follows handovers), and, for posts after a rotation, their nickname.
struct MeshBlockList: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        var nickname: String
        var peerIds: [String]
        var contactId: String?
        let blockedAt: Date
    }

    static let maxEntries = 500
    static let maxPeerIdsPerEntry = 16

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// True if a message or person with these details is blocked.
    func blocks(peerId: String?, nickname: String?, contactId: String? = nil) -> Bool {
        let nick = nickname.map(MeshBlockList.normalized) ?? ""
        return entries.contains { e in
            if let p = peerId, !p.isEmpty, e.peerIds.contains(p) { return true }
            if let c = contactId, c == e.contactId { return true }
            return !nick.isEmpty && MeshBlockList.normalized(e.nickname) == nick
        }
    }

    /// Blocks a person; merges into an existing entry for the same contact or nickname.
    @discardableResult
    mutating func block(nickname: String, peerIds: [String], contactId: String?, now: Date = Date()) -> Entry {
        let nick = MeshBlockList.normalized(nickname)
        if let i = entries.firstIndex(where: { (contactId != nil && $0.contactId == contactId)
                                                || (!nick.isEmpty && MeshBlockList.normalized($0.nickname) == nick) }) {
            for p in peerIds { addPeerId(p, at: i) }
            if entries[i].contactId == nil { entries[i].contactId = contactId }
            return entries[i]
        }
        var entry = Entry(id: UUID().uuidString, nickname: nickname, peerIds: [], contactId: contactId, blockedAt: now)
        entries.append(entry)
        for p in peerIds { addPeerId(p, at: entries.count - 1) }
        entry = entries[entries.count - 1]
        if entries.count > MeshBlockList.maxEntries { entries.removeFirst(entries.count - MeshBlockList.maxEntries) }
        return entry
    }

    mutating func unblock(_ id: String) {
        entries.removeAll { $0.id == id }
    }

    /// A blocked contact moved to a new key (handover): its new peer ID is blocked too.
    mutating func addPeerId(_ peerId: String, toContact contactId: String) {
        guard let i = entries.firstIndex(where: { $0.contactId == contactId }) else { return }
        addPeerId(peerId, at: i)
    }

    /// Two chats turned out to be one person (merged after handovers): the block follows the one kept.
    mutating func moveContact(from oldId: String, to newId: String) {
        for i in entries.indices where entries[i].contactId == oldId { entries[i].contactId = newId }
    }

    func entry(forContact contactId: String) -> Entry? {
        entries.first { $0.contactId == contactId }
    }

    private mutating func addPeerId(_ peerId: String, at i: Int) {
        guard !peerId.isEmpty, !entries[i].peerIds.contains(peerId) else { return }
        entries[i].peerIds.append(peerId)
        if entries[i].peerIds.count > MeshBlockList.maxPeerIdsPerEntry { entries[i].peerIds.removeFirst() }
    }

    /// Case-, accent- and width-insensitive, with spaces squeezed.
    static func normalized(_ nickname: String) -> String {
        nickname.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// What the crowd mesh keeps in the Keychain for moderation (cleared by the emergency wipe).
struct MeshModerationState: Codable, Equatable {
    var blockList = MeshBlockList()
    /// The user agreed to the crowd mesh rules before the first start.
    var rulesAccepted = false
}

/// Spots offensive words in crowd mesh text: English, Roman Urdu/Hindi, Urdu and Hindi script. The
/// Everyone channel refuses to send such a message, and received ones are hidden until tapped.
/// Whole words only (after undoing common disguises), so ordinary words that contain one aren't caught.
enum MeshContentFilter {
    static func isObjectionable(_ text: String) -> Bool {
        let tokens = tokens(of: text)
        for (i, t) in tokens.enumerated() {
            if matches(t) { return true }
            if i + 1 < tokens.count, matches(t + tokens[i + 1]) { return true }
        }
        return false
    }

    /// Lowercased, accents and tatweel removed, look-alike Arabic letters unified, digits and symbols
    /// used as letters turned back into letters, zero-width characters dropped; split into words.
    static func tokens(of text: String) -> [String] {
        var s = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        s = String(s.unicodeScalars.filter { !ignored.contains($0) }.map(Character.init))
        // Symbols used as letters stay inside words ("$hit", "b!tch"); trailing "!" is punctuation.
        let raw = s.split(whereSeparator: { !($0.isLetter || $0.isNumber || leet[$0] != nil) })
        return raw.compactMap { word -> String? in
            var w = Substring(word)
            while let last = w.last, last == "!" || last == "|" { w = w.dropLast() }
            while let first = w.first, first == "!" || first == "|" { w = w.dropFirst() }
            let mapped = String(w.map { leet[$0] ?? arabicVariants[$0] ?? $0 })
            return mapped.isEmpty ? nil : mapped
        }
    }

    private static func matches(_ token: String) -> Bool {
        let two = squeezed(token, keep: 2)
        if words.contains(token) || words.contains(two) { return true }
        let one = squeezed(token, keep: 1)
        if one.count >= 4, squeezedWords.contains(one) { return true }
        for suffix in ["s", "es", "ing", "ed", "er", "ers", "in"] where token.count > suffix.count + 3 && token.hasSuffix(suffix) {
            if words.contains(String(token.dropLast(suffix.count))) { return true }
        }
        return false
    }

    /// Runs of the same letter cut down to `keep` ("fuuuck" → "fuuck" or "fuck").
    static func squeezed(_ s: String, keep: Int) -> String {
        var out = ""
        var last: Character?
        var run = 0
        for ch in s {
            if ch == last { run += 1 } else { last = ch; run = 1 }
            if run <= keep { out.append(ch) }
        }
        return out
    }

    private static let ignored: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{0640}"]
    private static let leet: [Character: Character] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i", "|": "l",
    ]
    private static let arabicVariants: [Character: Character] = [
        "ي": "ی", "ى": "ی", "ك": "ک", "ه": "ہ", "ۃ": "ہ", "ة": "ہ", "أ": "ا", "إ": "ا", "آ": "ا",
    ]

    /// Base forms. Keep this list in step with Android (alignment branch: mesh-blocked-words.txt).
    /// Left out on purpose: words people need to report what happened ("rape", "attack"), and words
    /// with an ordinary meaning ("cock", "prick", "dala").
    static let wordList: [String] = [
        // English
        "fuck", "fucker", "fucking", "motherfucker", "fuk", "fck", "shit", "bullshit", "bitch", "cunt",
        "dickhead", "pussy", "whore", "slut", "bastard", "asshole", "arsehole", "wanker", "twat",
        "faggot", "nigger", "nigga", "retard", "porn", "nudes", "kys", "killyourself",
        // Roman Urdu / Hindi
        "madarchod", "maderchod", "madarchot", "behenchod", "bhenchod", "bhanchod", "behnchod",
        "chutiya", "chutiye", "chootiya", "chutia", "harami", "haramzada", "haramzadi", "haramkhor",
        "randi", "gandu", "gaandu", "gaand", "lund", "lauda", "loda", "bhosdi", "bhosdike", "bhosda",
        "bhosri", "kanjar", "kanjri", "chodu", "tatte",
        // Urdu
        "مادرچود", "بہنچود", "بہن‌چود", "چوتیا", "چوتیے", "حرامی", "حرامزادہ", "حرامزادی", "حرامخور",
        "رنڈی", "گانڈو", "گانڈ", "لنڈ", "لوڑا", "بھوسڑی", "بھوسڑا", "کنجر", "کنجری", "ٹٹے", "چودو",
        // Hindi
        "मादरचोद", "बहनचोद", "चूतिया", "हरामी", "रंडी", "गांडू", "भोसड़ी", "लौड़ा",
    ]

    static let words: Set<String> = Set(wordList.flatMap { tokens(of: $0) })
    /// Only words without a doubled letter: squeezing "nigger" or "tatte" would catch "Niger" and "Tate".
    private static let squeezedWords: Set<String> = Set(words.filter { $0.count >= 4 && squeezed($0, keep: 1) == $0 })
}
