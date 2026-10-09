//
//  CrowdMesh.swift
//  ChatFort — Crowd mesh
//
//  Multi-hop Bluetooth messaging with no internet or mobile network, interoperable with the
//  Android app (wire v2). Public crowd feed, encrypted team channels (joined by code) and
//  encrypted private messages (sealed sender).
//
//  Messages and contacts live in memory only. The mesh identity is new every start and rotates
//  every 15 minutes, so nobody can follow a phone by its ID. Team keys and a chosen nickname are
//  kept in the Keychain (this device only) and erased by the panic wipe.
//
//  Wire v3: ChatFort contacts linked through their chats (MeshLinkBridge) chat over the mesh with a pair
//  key; those chats, photos and voice notes are saved encrypted (MeshStore) and survive Stop.
//
//  Threading: `CrowdMesh` (UI state) is main-actor; `MeshEngine` owns the router, the Bluetooth
//  link layer, the identities and all crypto, on one serial queue.
//

import Foundation
import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class CrowdMesh: ObservableObject {
    static let shared = CrowdMesh()

    static let maxMessages = 500
    static let peerTimeout: TimeInterval = 5 * 60
    static let maxNicknameLength = 24
    static let maxTeamNameLength = 40

    @Published private(set) var status: CrowdMeshStatus = .stopped
    @Published private(set) var linkedPhones = 0
    @Published private(set) var nickname: String
    @Published private(set) var publicFeed: [MeshChatMessage] = []
    @Published private(set) var teams: [MeshTeamInfo] = []
    @Published private(set) var people: [MeshPerson] = []
    @Published private(set) var privateChats: [MeshPrivateChat] = []
    @Published private(set) var unreadPublic = 0
    @Published private(set) var log: [String] = []
    @Published private var teamMessageStore: [String: [MeshChatMessage]] = [:]
    @Published private var privateMessageStore: [String: [MeshChatMessage]] = [:]
    /// Linked ChatFort contacts of the active profile (wire v3).
    @Published private(set) var linkedContacts: [MeshLinkedContact] = []
    /// Every profile's contact chats (saved); only the active profile's are shown.
    @Published private var contactChats: [String: MeshContactChatState] = [:]

    var totalUnread: Int {
        unreadPublic + teams.reduce(0) { $0 + $1.unread } + privateChats.reduce(0) { $0 + $1.unread }
            + linkedContacts.reduce(0) { $0 + $1.unread }
    }

    private let engine = MeshEngine()
    /// Team key state, source of truth (persisted); the engine gets copies.
    private var teamKeys: [String: MeshTeamKeys] = [:]
    /// Public keys of everyone seen recently, by peer ID (hex).
    private var peerKeys: [String: Data] = [:]
    private var allPeople: [String: MeshPerson] = [:]
    /// Private contacts: current key (changed only by an accepted REKEY) and retired keys.
    private var contacts: [String: MeshContact] = [:]
    private var userChoseNickname: Bool
    /// Handovers whose old key isn't a contact's current key yet (catch-up delivers newest first).
    private var pendingRekeys: [Data: (newKey: Data, at: Date)] = [:]
    /// After a wipe, late engine lines (e.g. "BLE stopped") must not refill the log.
    private var logQuietUntil = Date.distantPast
    /// Link state per binding, every profile (Keychain).
    private var contactLinks: [String: MeshContactLink] = [:]
    /// The active profile's direct contacts (from MeshLinkBridge): binding → name.
    private var activeContactNames: [String: String] = [:]
    private var contactLastHeard: [String: Date] = [:]
    private var contactLastPing: [String: Date] = [:]
    /// False while the Keychain / store can't be read (before the first unlock after a restart):
    /// nothing is created or saved over the real state until it has been read.
    private var contactLinksLoaded = false
    private var contactChatsLoaded = false
    /// Briefly after a wipe, late link events must not recreate state.
    private var linksFrozenUntil = Date.distantPast

    static let contactNearbyFor: TimeInterval = 5 * 60
    static let outboxKeep: TimeInterval = 24 * 3600
    static let resendEvery: TimeInterval = 5 * 60
    static let pingEvery: TimeInterval = 5 * 60
    static let pingMinInterval: TimeInterval = 60
    /// Rounds a media item goes out in (the first + 2 resends).
    static let maxMediaSends = 3
    static let maxReceivedUids = 1000

    private init() {
        let saved = MeshKeychain.load(account: MeshKeychain.nicknameAccount).flatMap { String(data: $0, encoding: .utf8) }
        userChoseNickname = saved != nil
        nickname = saved ?? CrowdMesh.randomNickname()
        loadTeams()
        MeshStore.deleteVoiceTempFiles()
        loadContactLinks()
        engine.host = self
    }

    // MARK: - Start / stop

    func start() {
        // Only from stopped: with Bluetooth off the engine is already running and waiting for it.
        guard status == .stopped else { return }
        if !userChoseNickname { nickname = CrowdMesh.randomNickname() }
        status = .starting
        let teams = Array(teamKeys.values)
        let nick = nickname
        engine.run { $0.start(nickname: nick, teams: teams) }
        // Contacts outlive a stop; the engine needs their keys to send handovers.
        syncContactKeys()
        loadContactLinks()
        refreshContactLinkKeys()
        syncPairs()
        addLog("Crowd mesh started")
    }

    func stop() {
        engine.run { $0.stop() }
        status = .stopped
        linkedPhones = 0
        allPeople = [:]
        people = []
        peerKeys = [:]
        for id in privateChats.map(\.id) { updateChat(id) { $0.isNearby = false } }
        contactLastHeard = [:]
        publishLinked()
        addLog("Crowd mesh stopped")
    }

    func setNickname(_ name: String) {
        // 24 characters and 32 UTF-8 bytes (the wire limit; Urdu letters take 2 bytes each).
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CrowdMesh.maxNicknameLength))
            .utf8Prefix(maxBytes: MeshWire.maxNickBytes)
        if clean.isEmpty {
            userChoseNickname = false
            MeshKeychain.delete(account: MeshKeychain.nicknameAccount)
            nickname = CrowdMesh.randomNickname()
        } else {
            userChoseNickname = true
            MeshKeychain.save(Data(clean.utf8), account: MeshKeychain.nicknameAccount)
            nickname = clean
        }
        let nick = nickname
        engine.run { $0.setNickname(nick) }
    }

    // MARK: - Public feed

    func sendPublic(_ text: String) -> Result<Void, CrowdMeshError> {
        guard let text = checkedText(text) else { return .failure(.tooLong) }
        guard status == .running else { return .failure(.notRunning) }
        let messageId = MeshCrypto.randomBytes(16)
        let nick = nickname
        engine.run { $0.sendPublic(text: text, nickname: nick, messageId: messageId) }
        publicFeed = CrowdMesh.adding(mine(messageId, text, .sent), to: publicFeed)
        return .success(())
    }

    func markPublicRead() { unreadPublic = 0 }

    // MARK: - Teams

    func createTeam(name: String) -> MeshTeamInfo {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CrowdMesh.maxTeamNameLength))
        let keys = MeshTeamKeys(id: UUID().uuidString, name: clean.isEmpty ? "Team" : clean,
                                dayKey: MeshCrypto.randomBytes(32), day: MeshTeamKeys.today())
        return addTeam(keys)
    }

    func joinTeam(code: String) -> Result<MeshTeamInfo, CrowdMeshError> {
        guard let parsed = MeshCrypto.parseTeamCode(code) else { return .failure(.invalidTeamCode) }
        var keys = MeshTeamKeys(id: UUID().uuidString, name: String(parsed.name.prefix(CrowdMesh.maxTeamNameLength)),
                                dayKey: parsed.dayKey, day: parsed.day)
        _ = keys.refresh()
        if teamKeys.values.contains(where: { $0.sameTeam(as: keys) }) { return .failure(.alreadyInTeam) }
        return .success(addTeam(keys))
    }

    func teamCode(for teamId: String) -> String? {
        refreshTeamKeys()
        guard let keys = teamKeys[teamId] else { return nil }
        return MeshCrypto.teamCode(dayKey: keys.dayKey, day: keys.day, name: keys.name)
    }

    func leaveTeam(_ teamId: String) {
        teamKeys[teamId] = nil
        saveTeams()
        teams.removeAll { $0.id == teamId }
        deleteMediaFiles(teamMessageStore[teamId] ?? [])
        CrowdMeshMediaCache.clear()
        MeshVoicePlayer.shared.stop()
        teamMessageStore[teamId] = nil
        let remaining = Array(teamKeys.values)
        engine.run { $0.setTeams(remaining) }
    }

    func teamMessages(_ teamId: String) -> [MeshChatMessage] { teamMessageStore[teamId] ?? [] }

    func sendTeam(_ teamId: String, text: String) -> Result<Void, CrowdMeshError> {
        guard let text = checkedText(text) else { return .failure(.tooLong) }
        guard status == .running else { return .failure(.notRunning) }
        refreshTeamKeys()
        guard let keys = teamKeys[teamId] else { return .failure(.invalidTeamCode) }
        let messageId = MeshCrypto.randomBytes(16)
        let nick = nickname
        engine.run { $0.sendTeam(keys, text: text, nickname: nick, messageId: messageId) }
        addTeamMessage(teamId, mine(messageId, text, .sent), countUnread: false)
        return .success(())
    }

    func markRead(team teamId: String) {
        if let i = teams.firstIndex(where: { $0.id == teamId }) { teams[i].unread = 0 }
    }

    // MARK: - Private chats

    /// Opens (or creates) the private chat with someone in `people`.
    func openPrivateChat(with personId: String) -> String {
        if let existing = contacts.values.first(where: { $0.peerId == personId || $0.retiredPeerIds.contains(personId) }) {
            return existing.id
        }
        let key = peerKeys[personId] ?? Data()
        let contact = MeshContact(id: UUID().uuidString, currentKey: key, nickname: allPeople[personId]?.nickname ?? String(personId.prefix(8)))
        contacts[contact.id] = contact
        privateChats.insert(MeshPrivateChat(id: contact.id, nickname: contact.nickname, peerId: contact.peerId,
                                            unread: 0, lastMessage: nil, isNearby: allPeople[personId] != nil), at: 0)
        if let next = pendingRekeys.removeValue(forKey: key)?.newKey {
            applyRekey(contact.id, to: next)
        } else {
            syncContactKeys()
        }
        return contact.id
    }

    func privateMessages(_ chatId: String) -> [MeshChatMessage] { privateMessageStore[chatId] ?? [] }

    func sendPrivate(_ chatId: String, text: String) -> Result<Void, CrowdMeshError> {
        guard let text = checkedText(text) else { return .failure(.tooLong) }
        guard status == .running else { return .failure(.notRunning) }
        guard let contact = contacts[chatId], MeshCrypto.isValidPublicKey(contact.currentKey) else { return .failure(.notRunning) }
        let messageId = MeshCrypto.randomBytes(16)
        let nick = nickname
        let key = contact.currentKey
        engine.run { $0.sendDirect(to: key, text: text, nickname: nick, messageId: messageId) }
        addPrivateMessage(chatId, mine(messageId, text, .onItsWay), countUnread: false)
        return .success(())
    }

    func deletePrivateChat(_ chatId: String) {
        contacts[chatId] = nil
        privateMessageStore[chatId] = nil
        privateChats.removeAll { $0.id == chatId }
        syncContactKeys()
    }

    func markRead(privateChat chatId: String) { updateChat(chatId) { $0.unread = 0 } }

    // MARK: - Panic wipe

    /// Part of the emergency wipe: stops the mesh and erases team keys, nickname, messages and contacts.
    func wipe() {
        MeshKeychain.deleteAll()
        engine.run { $0.wipe() }
        logQuietUntil = Date().addingTimeInterval(10)
        pendingRekeys = [:]
        teamKeys = [:]
        contacts = [:]
        peerKeys = [:]
        allPeople = [:]
        status = .stopped
        linkedPhones = 0
        publicFeed = []
        teams = []
        people = []
        privateChats = []
        teamMessageStore = [:]
        privateMessageStore = [:]
        unreadPublic = 0
        wipeContactLinks()
        log = []
        userChoseNickname = false
        nickname = CrowdMesh.randomNickname()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [CrowdMesh.notificationId])
        // A copied team code may still be on the clipboard. Compare change counts: reading the
        // clipboard itself would show iOS's "Allow Paste?" prompt in the middle of a panic wipe.
        if let count = CrowdMeshUI.copiedSecretChangeCount, UIPasteboard.general.changeCount == count {
            UIPasteboard.general.items = []
        }
        CrowdMeshUI.copiedSecretChangeCount = nil
    }

    // MARK: - Engine events (main actor)

    func engineStatus(_ state: MeshBleState, links: Int) {
        guard status != .stopped else { return }
        linkedPhones = links
        switch state {
        case .starting: status = .starting
        case .ready: status = .running
        case .poweredOff: status = .bluetoothOff
        case .unauthorized: status = .unauthorized
        case .unsupported: status = .unsupported
        }
    }

    func engineLinks(_ links: Int) {
        guard status != .stopped else { return }
        let more = links > linkedPhones
        linkedPhones = links
        // A new Bluetooth link: ping contacts we have something waiting for, now.
        if more { pingWaitingContacts(force: true) }
    }

    func engineReceived(_ event: MeshInbound) {
        guard status != .stopped else { return }
        switch event {
        case let .announce(key, nick, hops):
            seen(key, nick, hops)
        case let .publicPost(messageId, key, nick, text, timestamp, hops):
            seen(key, nick, hops)
            let m = received(messageId, key, nick, text, timestamp, hops)
            guard !CrowdMesh.contains(m, publicFeed) else { return }
            publicFeed = CrowdMesh.adding(m, to: publicFeed)
            if CrowdMesh.contains(m, publicFeed) { unreadPublic += 1 }
        case let .team(teamId, messageId, key, nick, text, timestamp, hops):
            guard teamKeys[teamId] != nil else { return }
            seen(key, nick, hops)
            if addTeamMessage(teamId, received(messageId, key, nick, text, timestamp, hops), countUnread: true) {
                notify(NSLocalizedString("New team message", comment: "crowd mesh notification"))
            }
        case let .direct(messageId, key, nick, text, timestamp, hops):
            seen(key, nick, hops)
            let chatId = contactId(for: key, nickname: nick)
            if addPrivateMessage(chatId, received(messageId, key, nick, text, timestamp, hops), countUnread: true) {
                notify(NSLocalizedString("New private message", comment: "crowd mesh notification"))
            }
        case let .ack(ackedId):
            for (chatId, messages) in privateMessageStore {
                guard let i = messages.firstIndex(where: { $0.id == ackedId && $0.isMine }) else { continue }
                privateMessageStore[chatId]?[i].status = .delivered
                updateChat(chatId) { chat in
                    if chat.lastMessage?.id == ackedId { chat.lastMessage?.status = .delivered }
                }
            }
        case let .contactHeard(binding, fresh):
            contactHeard(binding, fresh: fresh)
        case let .contactMessage(binding, uid, text, timestamp, hops, fresh):
            contactMessage(binding, uid: uid, text: text, media: nil, timestamp: timestamp, hops: hops, fresh: fresh)
        case let .contactAck(binding, uid):
            contactAck(binding, uid: uid)
        case let .contactMediaHeader(binding, uid, header, timestamp, hops, fresh):
            contactMessage(binding, uid: uid, text: header.caption, media: header, timestamp: timestamp, hops: hops, fresh: fresh)
        case let .teamMediaHeader(teamId, uid, key, header, timestamp, hops):
            guard teamKeys[teamId] != nil else { return }
            seen(key, header.nick, hops)
            var m = received(uid, key, header.nick, header.caption, timestamp, hops)
            m.media = MeshMediaInfo(header)
            if addTeamMessage(teamId, m, countUnread: true) {
                notify(NSLocalizedString("New team message", comment: "crowd mesh notification"))
            }
        case let .media(event):
            mediaEvent(event)
        case let .rekey(oldKey, newKey):
            // A handover counts only from the contact's CURRENT key, to a different key.
            guard newKey != oldKey else { return }
            if let id = contacts.first(where: { $0.value.currentKey == oldKey })?.key {
                applyRekey(id, to: newKey)
            } else {
                // Catch-up delivers newest first, so a later handover can arrive before the one that
                // leads to it: keep it (1 h, bounded) and follow the chain when the earlier one lands.
                pendingRekeys[oldKey] = (newKey, Date())
                if pendingRekeys.count > 64, let oldest = pendingRekeys.min(by: { $0.value.at < $1.value.at })?.key {
                    pendingRekeys[oldest] = nil
                }
            }
        }
    }

    /// Moves contact `id` to `newKey` and along any buffered later handovers, then merges any chat that
    /// was opened with one of those keys (a message or a tap that beat the handover).
    private func applyRekey(_ id: String, to newKey: Data) {
        guard var contact = contacts[id] else { return }
        contact.retire(contact.currentKey, for: newKey)
        contacts[id] = contact
        // Every step below follows handovers each signed by the key it replaces, so the whole chain
        // is verified: two chats on one chain are the same person.
        for _ in 0..<16 {
            guard var me = contacts[id] else { return }
            if let next = pendingRekeys.removeValue(forKey: me.currentKey)?.newKey, next != me.currentKey {
                me.retire(me.currentKey, for: next)
                contacts[id] = me
                continue
            }
            let myKeys = Set(me.retiredKeys + [me.currentKey])
            if let ahead = contacts.values.first(where: { $0.id != id && $0.retiredKeys.contains(me.currentKey) }) {
                // That chat already moved on from our current key: take its key, then merge it.
                me.retire(me.currentKey, for: ahead.currentKey)
                contacts[id] = me
                mergeChat(ahead.id, into: id)
            } else if let behind = contacts.values.first(where: { $0.id != id && myKeys.contains($0.currentKey) }) {
                mergeChat(behind.id, into: id)
            } else {
                break
            }
        }
        let peerId = contacts[id]?.peerId ?? ""
        updateChat(id) { $0.peerId = peerId }
        syncContactKeys()
        addLog("Contact moved to a new key")
    }

    private func mergeChat(_ otherId: String, into id: String) {
        guard let other = contacts.removeValue(forKey: otherId) else { return }
        contacts[id]?.absorb(other.retiredKeys + [other.currentKey])
        var list = privateMessageStore[id] ?? []
        for m in privateMessageStore.removeValue(forKey: otherId) ?? [] { list = CrowdMesh.adding(m, to: list) }
        privateMessageStore[id] = list
        let unread = privateChats.first(where: { $0.id == otherId })?.unread ?? 0
        privateChats.removeAll { $0.id == otherId }
        updateChat(id) { chat in
            chat.unread += unread
            chat.lastMessage = list.last
        }
    }

    func engineLog(_ line: String) {
        guard Date() >= logQuietUntil else { return }
        addLog(line)
    }

    // MARK: - Linked ChatFort contacts (wire v3)

    /// MeshLinkBridge: the active profile's direct contacts (binding → name), after a profile switch
    /// or a contact change. Only these contacts are shown and given to the engine.
    func setActiveContacts(_ names: [String: String]) {
        loadContactLinks()
        guard names != activeContactNames else { return }
        activeContactNames = names
        syncPairs()
        publishLinked()
    }

    /// MeshLinkBridge: the contact was deleted: its pair state and mesh chat go too.
    func contactDeleted(_ binding: String) {
        forgetContact(binding)
        syncPairs()
        publishLinked()
    }

    /// A chat profile was deleted: its contacts' links, mesh chats and media go too.
    func profileDeleted(userId: Int64) {
        let prefix = "u\(userId):"
        for binding in Set(contactLinks.keys).union(contactChats.keys) where binding.hasPrefix(prefix) {
            forgetContact(binding)
        }
        syncPairs()
        publishLinked()
    }

    private var linksUsable: Bool { contactLinksLoaded && Date() >= linksFrozenUntil }

    /// MeshLinkBridge: link messages to send now to these ready contacts: answers not sent yet, first
    /// offers (again until confirmed sent) and the one re-offer. A new seed is saved before sending;
    /// call `linkMessageSent` once each is out.
    func linkMessagesToSend(readyBindings: [String]) -> [(binding: String, offer: MeshLinkOffer)] {
        guard linksUsable else { return [] }
        let now = CrowdMesh.nowMs()
        var out: [(binding: String, offer: MeshLinkOffer)] = []
        var changed = false
        for binding in readyBindings {
            var link = contactLinks[binding] ?? MeshContactLink()
            if let answer = link.unsentAnswer(nowMs: now) {
                out.append((binding, answer))
            } else if let offer = link.offerToSend(nowMs: now) {
                out.append((binding, offer))
            }
            if contactLinks[binding] != link {
                contactLinks[binding] = link
                changed = true
            }
        }
        if changed { saveContactLinks() }
        return out
    }

    /// MeshLinkBridge: this link message went out.
    func linkMessageSent(_ offer: MeshLinkOffer, to binding: String) {
        guard linksUsable, var link = contactLinks[binding] else { return }
        if offer.ack { link.answerSent(offer) } else { link.offerSent(offer, nowMs: CrowdMesh.nowMs()) }
        guard contactLinks[binding] != link else { return }
        contactLinks[binding] = link
        saveContactLinks()
    }

    /// MeshLinkBridge: a link message from this contact (active profile). Returns the message to send
    /// back (an answer, or a new offer after equal seeds), already saved as unsent.
    func receiveLinkOffer(_ offer: MeshLinkOffer, from binding: String) -> MeshLinkOffer? {
        guard linksUsable else { return nil }
        var link = contactLinks[binding] ?? MeshContactLink()
        let before = link
        let reply = link.receive(offer, nowMs: CrowdMesh.nowMs())
        guard link != before else { return reply }
        contactLinks[binding] = link
        saveContactLinks()
        if link.keys != before.keys {
            addLog("Offline contact linked")
            syncPairs()
            publishLinked()
        }
        return reply
    }

    func contactMessages(_ binding: String) -> [MeshChatMessage] { contactChats[binding]?.messages ?? [] }

    /// Opening the chat pings the contact (at most once a minute) to learn if they're nearby.
    func openContactChat(_ binding: String) {
        markRead(contact: binding)
        if Date().timeIntervalSince(contactLastPing[binding] ?? .distantPast) >= CrowdMesh.pingMinInterval { ping(binding) }
    }

    func markRead(contact binding: String) {
        guard let unread = contactChats[binding]?.unread, unread > 0 else { return }
        contactChats[binding]?.unread = 0
        saveContactChats()
        publishLinked()
    }

    func sendContactText(_ binding: String, text: String) -> Result<Void, CrowdMeshError> {
        guard let text = checkedText(text) else { return .failure(.tooLong) }
        guard status == .running, isActiveLinked(binding) else { return .failure(.notRunning) }
        let uid = MeshCrypto.randomBytes(16)
        let now = Date()
        appendContactMessage(binding, mine(uid, text, .onItsWay))
        contactChats[binding]?.outbox[uid.meshHex] = MeshOutboxItem(uid: uid, kind: MeshContactKind.message.rawValue, text: text,
                                                                     createdAt: now, lastSentAt: now, sends: 1)
        saveContactChats()
        engine.run { $0.sendContact(binding, kind: .message, uid: uid, content: Data(text.utf8)) }
        return .success(())
    }

    /// A photo (JPEG) or voice note (m4a) already encoded within the limits.
    func sendContactMedia(_ binding: String, _ type: MeshMediaType, data: Data, durationMs: UInt32 = 0,
                          width: UInt16 = 0, height: UInt16 = 0, caption: String = "") -> Result<Void, CrowdMeshError> {
        guard status == .running, isActiveLinked(binding) else { return .failure(.notRunning) }
        guard let header = MeshMediaHeader.make(type, data: data, durationMs: durationMs, width: width, height: height,
                                                caption: caption.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return .failure(.tooLong) }
        guard let file = MeshStore.saveMedia(data) else { return .failure(.notRunning) }
        let uid = MeshCrypto.randomBytes(16)
        let now = Date()
        var m = mine(uid, header.caption, .onItsWay)
        m.media = MeshMediaInfo(header, file: file)
        appendContactMessage(binding, m)
        contactChats[binding]?.outbox[uid.meshHex] = MeshOutboxItem(uid: uid, kind: MeshContactKind.media.rawValue,
                                                                     mediaHeader: header.encoded(), mediaFile: file,
                                                                     createdAt: now, lastSentAt: now, sends: 1)
        saveContactChats()
        engine.run { $0.sendContactMedia(binding, uid: uid, header: header, data: data) }
        return .success(())
    }

    func sendTeamMedia(_ teamId: String, _ type: MeshMediaType, data: Data, durationMs: UInt32 = 0,
                       width: UInt16 = 0, height: UInt16 = 0, caption: String = "") -> Result<Void, CrowdMeshError> {
        guard status == .running else { return .failure(.notRunning) }
        refreshTeamKeys()
        guard let keys = teamKeys[teamId] else { return .failure(.invalidTeamCode) }
        guard let header = MeshMediaHeader.make(type, data: data, durationMs: durationMs, width: width, height: height,
                                                nick: nickname, caption: caption.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return .failure(.tooLong) }
        guard let file = MeshStore.saveMedia(data) else { return .failure(.notRunning) }
        let uid = MeshCrypto.randomBytes(16), messageId = MeshCrypto.randomBytes(16)
        var m = mine(uid, header.caption, .sent)
        m.media = MeshMediaInfo(header, file: file)
        addTeamMessage(teamId, m, countUnread: false)
        engine.run { $0.sendTeamMedia(keys, uid: uid, header: header, data: data, messageId: messageId) }
        return .success(())
    }

    /// The decrypted bytes of a complete photo or voice note.
    func mediaData(_ media: MeshMediaInfo) -> Data? { media.file.flatMap(MeshStore.loadMedia) }

    private func isActiveLinked(_ binding: String) -> Bool {
        activeContactNames[binding] != nil && contactLinks[binding]?.isLinked == true
    }

    private func contactHeard(_ binding: String, fresh: Bool) {
        // Any packet that decrypts proves both sides hold the pair key: the kept answer can go.
        if var link = contactLinks[binding], link.answerSeed != nil, linksUsable {
            link.confirmLinked()
            contactLinks[binding] = link
            saveContactLinks()
        }
        // Only fresh packets count: a replayed old one must not trigger resends or show "nearby".
        guard fresh, isActiveLinked(binding) else { return }
        contactLastHeard[binding] = Date()
        resendOutbox(binding)
        publishLinked()
    }

    /// A MESSAGE (media nil) or MEDIA header from a linked contact.
    private func contactMessage(_ binding: String, uid: Data, text: String, media header: MeshMediaHeader?,
                                timestamp: UInt64, hops: Int, fresh: Bool) {
        guard let name = activeContactNames[binding], isActiveLinked(binding) else { return }
        var chat = contactChats[binding] ?? MeshContactChatState()
        let id = uid.meshHex
        if chat.receivedUids.contains(id) {
            // A repeat: the sender didn't get our ACK. Answer again only if the copy is fresh (no
            // replies to replays), and for media only once it's complete.
            let complete = chat.messages.first { $0.id == id && !$0.isMine }?.media?.isComplete ?? true
            if fresh, header == nil || complete { sendAck(binding, uid) }
            return
        }
        chat.receivedUids = Array((chat.receivedUids + [id]).suffix(CrowdMesh.maxReceivedUids))
        let date = min(Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000), Date())
        var m = MeshChatMessage(id: id, senderName: name, senderId: binding, text: text, date: date,
                                isMine: false, hops: hops, status: .received)
        if let header { m.media = MeshMediaInfo(header) }
        chat.messages = CrowdMesh.adding(m, to: chat.messages)
        chat.unread += 1
        contactChats[binding] = chat
        saveContactChats()
        publishLinked()
        // MESSAGE: ACK now. MEDIA: ACK once all chunks are in.
        if header == nil { sendAck(binding, uid) }
        notify(NSLocalizedString("New private message", comment: "crowd mesh notification"))
    }

    private func contactAck(_ binding: String, uid: Data) {
        guard var chat = contactChats[binding] else { return }
        let id = uid.meshHex
        var changed = chat.outbox.removeValue(forKey: id) != nil
        if let i = chat.messages.firstIndex(where: { $0.id == id && $0.isMine }), chat.messages[i].status != .delivered {
            chat.messages[i].status = .delivered
            changed = true
        }
        guard changed else { return }
        contactChats[binding] = chat
        saveContactChats()
        publishLinked()
    }

    private func sendAck(_ binding: String, _ uid: Data) {
        engine.run { $0.sendContact(binding, kind: .ack, uid: uid) }
    }

    private func ping(_ binding: String) {
        guard status == .running, isActiveLinked(binding) else { return }
        contactLastPing[binding] = Date()
        let uid = MeshCrypto.randomBytes(16)
        engine.run { $0.sendContact(binding, kind: .ping, uid: uid) }
    }

    /// Contacts we have unacknowledged items for: ping every 5 min, or on a new Bluetooth link (≥ 1 min apart).
    private func pingWaitingContacts(force: Bool) {
        guard status == .running else { return }
        let interval = force ? CrowdMesh.pingMinInterval : CrowdMesh.pingEvery
        for (binding, chat) in contactChats where !chat.outbox.isEmpty && isActiveLinked(binding) {
            if Date().timeIntervalSince(contactLastPing[binding] ?? .distantPast) >= interval { ping(binding) }
        }
    }

    /// The contact is nearby: resend what's unacknowledged (same uid; media with the same bytes),
    /// each at most every 5 min, media at most twice.
    private func resendOutbox(_ binding: String) {
        guard status == .running, var chat = contactChats[binding], !chat.outbox.isEmpty else { return }
        let now = Date()
        var sent = false
        for (id, var item) in chat.outbox {
            guard now.timeIntervalSince(item.lastSentAt) >= CrowdMesh.resendEvery,
                  now.timeIntervalSince(item.createdAt) < CrowdMesh.outboxKeep
            else { continue }
            let uid = item.uid
            if item.kind == MeshContactKind.media.rawValue {
                guard item.sends < CrowdMesh.maxMediaSends,
                      let header = item.mediaHeader.flatMap(MeshMediaHeader.decode),
                      let data = item.mediaFile.flatMap(MeshStore.loadMedia)
                else { continue }
                engine.run { $0.sendContactMedia(binding, uid: uid, header: header, data: data) }
            } else {
                let text = Data((item.text ?? "").utf8)
                engine.run { $0.sendContact(binding, kind: .message, uid: uid, content: text) }
            }
            item.lastSentAt = now
            item.sends += 1
            chat.outbox[id] = item
            sent = true
        }
        guard sent else { return }
        contactChats[binding] = chat
        saveContactChats()
    }

    /// Unacknowledged items are kept 24 h.
    private func expireOutbox() {
        let now = Date()
        var changed = false
        for (binding, chat) in contactChats where !chat.outbox.isEmpty {
            let kept = chat.outbox.filter { now.timeIntervalSince($0.value.createdAt) < CrowdMesh.outboxKeep }
            if kept.count != chat.outbox.count {
                contactChats[binding]?.outbox = kept
                changed = true
            }
        }
        if changed { saveContactChats() }
    }

    private func mediaEvent(_ e: MeshMediaAssembler.Event) {
        switch e {
        case let .progress(mediaId, received, total):
            updateMedia(mediaId.meshHex, save: false) { $0.received = received; $0.total = total }
        case let .complete(mediaId, data):
            guard let file = MeshStore.saveMedia(data) else { return }
            let owner = updateMedia(mediaId.meshHex, save: true) { media in
                media.file = file
                media.received = media.total
                media.failed = false
            }
            switch owner {
            case let .contact(binding, uid)?: sendAck(binding, uid)
            case .team?: break
            case nil: MeshStore.deleteMedia(file)
            }
        case let .failed(mediaId):
            updateMedia(mediaId.meshHex, save: true) { $0.failed = true }
        }
    }

    private enum MediaOwner {
        case contact(binding: String, uid: Data)
        case team(String)
    }

    /// Changes the (not yet complete) received media item with this ID, wherever it is.
    @discardableResult
    private func updateMedia(_ mediaId: String, save: Bool, _ change: (inout MeshMediaInfo) -> Void) -> MediaOwner? {
        for (binding, chat) in contactChats {
            guard let i = chat.messages.firstIndex(where: { !$0.isMine && $0.media?.mediaId == mediaId && $0.media?.isComplete == false }),
                  let uid = Data(meshHex: chat.messages[i].id)
            else { continue }
            change(&contactChats[binding]!.messages[i].media!)
            if save { saveContactChats() }
            publishLinked()
            return .contact(binding: binding, uid: uid)
        }
        for (teamId, list) in teamMessageStore {
            guard let i = list.firstIndex(where: { !$0.isMine && $0.media?.mediaId == mediaId && $0.media?.isComplete == false })
            else { continue }
            change(&teamMessageStore[teamId]![i].media!)
            if let t = teams.firstIndex(where: { $0.id == teamId }), teams[t].lastMessage?.id == list[i].id {
                teams[t].lastMessage = teamMessageStore[teamId]?[i]
            }
            return .team(teamId)
        }
        return nil
    }

    private func appendContactMessage(_ binding: String, _ m: MeshChatMessage) {
        var chat = contactChats[binding] ?? MeshContactChatState()
        chat.messages = CrowdMesh.adding(m, to: chat.messages)
        contactChats[binding] = chat
        publishLinked()
    }

    private func publishLinked() {
        let now = Date()
        let list = activeContactNames.compactMap { binding, name -> MeshLinkedContact? in
            guard contactLinks[binding]?.isLinked == true else { return nil }
            let chat = contactChats[binding]
            let heard = contactLastHeard[binding]
            return MeshLinkedContact(id: binding, name: name,
                                     isNearby: status != .stopped && heard.map { now.timeIntervalSince($0) < CrowdMesh.contactNearbyFor } == true,
                                     lastHeard: heard, unread: chat?.unread ?? 0, lastMessage: chat?.messages.last)
        }.sorted {
            let a = $0.lastMessage?.date ?? .distantPast, b = $1.lastMessage?.date ?? .distantPast
            return a != b ? a > b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if list != linkedContacts { linkedContacts = list }
    }

    /// The engine reads only the active profile's linked contacts.
    private func syncPairs() {
        let pairs = activeContactNames.keys.compactMap { binding -> MeshEnginePair? in
            guard let link = contactLinks[binding], let keys = link.keys else { return nil }
            return MeshEnginePair(binding: binding, keys: keys, myRole: link.myRole)
        }
        engine.run { $0.setPairs(pairs) }
    }

    private func refreshContactLinkKeys() {
        let now = CrowdMesh.nowMs()
        var changed = false
        for binding in Array(contactLinks.keys) {
            guard var link = contactLinks[binding], link.refreshKeys(nowMs: now) else { continue }
            contactLinks[binding] = link
            changed = true
        }
        if changed {
            saveContactLinks()
            syncPairs()
        }
    }

    private func forgetContact(_ binding: String) {
        if contactLinks.removeValue(forKey: binding) != nil { saveContactLinks() }
        if let chat = contactChats.removeValue(forKey: binding) {
            deleteMediaFiles(chat.messages)
            saveContactChats()
        }
        contactLastHeard[binding] = nil
        contactLastPing[binding] = nil
        CrowdMeshMediaCache.clear()
        MeshVoicePlayer.shared.stop()
    }

    private func deleteMediaFiles(_ messages: [MeshChatMessage]) {
        for m in messages { if let f = m.media?.file { MeshStore.deleteMedia(f) } }
    }

    /// Links, contact chats and their media (emergency wipe, self-destruct, Delete database).
    func wipeContactLinks() {
        linksFrozenUntil = Date().addingTimeInterval(15)
        MeshLinkBridge.reset()
        contactLinks = [:]
        contactChats = [:]
        contactLinksLoaded = true
        contactChatsLoaded = true
        activeContactNames = [:]
        contactLastHeard = [:]
        contactLastPing = [:]
        linkedContacts = []
        MeshKeychain.delete(account: MeshKeychain.contactLinksAccount)
        MeshStore.wipe()
        CrowdMeshMediaCache.clear()
        MeshVoicePlayer.shared.stop()
        engine.run { $0.setPairs([]) }
    }

    /// Reads link states and chats once they're readable (retried until then; see `contactLinksLoaded`).
    private func loadContactLinks() {
        if !contactLinksLoaded {
            switch MeshKeychain.read(account: MeshKeychain.contactLinksAccount) {
            case let .found(data):
                contactLinks = (try? JSONDecoder().decode([String: MeshContactLink].self, from: data)) ?? [:]
                contactLinksLoaded = true
                refreshContactLinkKeys()
            case .notFound:
                contactLinksLoaded = true
            case .failed:
                break
            }
        }
        if !contactChatsLoaded, var chats = MeshStore.loadContactChats() {
            // The reassembly of photos / voice notes doesn't survive a restart: mark unfinished ones.
            for (binding, chat) in chats {
                for (i, m) in chat.messages.enumerated() where !m.isMine && m.media?.isComplete == false && m.media?.failed == false {
                    chats[binding]?.messages[i].media?.failed = true
                }
            }
            contactChats = chats
            contactChatsLoaded = true
            // Team media from a previous run and orphans: only files of saved contact chats are kept.
            var keep = Set<String>()
            for chat in contactChats.values {
                for m in chat.messages { if let f = m.media?.file { keep.insert(f) } }
                for item in chat.outbox.values { if let f = item.mediaFile { keep.insert(f) } }
            }
            MeshStore.deleteMedia(except: keep)
        }
    }

    private func saveContactLinks() {
        guard contactLinksLoaded else { return }
        if contactLinks.isEmpty {
            MeshKeychain.delete(account: MeshKeychain.contactLinksAccount)
        } else if let data = try? JSONEncoder().encode(contactLinks) {
            MeshKeychain.save(data, account: MeshKeychain.contactLinksAccount)
        }
    }

    private func saveContactChats() {
        guard contactChatsLoaded else { return }
        MeshStore.saveContactChats(contactChats)
    }

    private static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - Internals

    private func addTeam(_ keys: MeshTeamKeys) -> MeshTeamInfo {
        teamKeys[keys.id] = keys
        saveTeams()
        let info = MeshTeamInfo(id: keys.id, name: keys.name, unread: 0, lastMessage: nil)
        teams.append(info)
        let all = Array(teamKeys.values)
        engine.run { $0.setTeams(all) }
        return info
    }

    private func loadTeams() {
        guard let data = MeshKeychain.load(account: MeshKeychain.teamsAccount),
              let saved = try? JSONDecoder().decode([MeshTeamKeys].self, from: data)
        else { return }
        for keys in saved {
            teamKeys[keys.id] = keys
            teams.append(MeshTeamInfo(id: keys.id, name: keys.name, unread: 0, lastMessage: nil))
        }
        refreshTeamKeys()
    }

    private func saveTeams() {
        let all = Array(teamKeys.values)
        if all.isEmpty {
            MeshKeychain.delete(account: MeshKeychain.teamsAccount)
        } else if let data = try? JSONEncoder().encode(all) {
            MeshKeychain.save(data, account: MeshKeychain.teamsAccount)
        }
    }

    /// Ratchets every team to today and drops yesterday's key after 12:00 UTC; saves and updates the
    /// engine whenever anything changed, so the Keychain never keeps a key older than needed.
    private func refreshTeamKeys() {
        var changed = false
        for id in Array(teamKeys.keys) {
            guard var keys = teamKeys[id], keys.refresh() else { continue }
            teamKeys[id] = keys
            changed = true
        }
        if changed {
            saveTeams()
            let all = Array(teamKeys.values)
            engine.run { $0.setTeams(all) }
        }
    }

    /// Every engine tick (5 s): expire people, advance team keys past midnight UTC.
    fileprivate func refreshPeople() {
        let now = Date()
        allPeople = allPeople.filter { now.timeIntervalSince($0.value.lastSeen) < CrowdMesh.peerTimeout }
        let contactPeerIds = Set(contacts.values.map(\.peerId))
        peerKeys = peerKeys.filter { allPeople[$0.key] != nil || contactPeerIds.contains($0.key) }
        publishPeople()
        refreshTeamKeys()
        let hourAgo = Date().addingTimeInterval(-3600)
        pendingRekeys = pendingRekeys.filter { $0.value.at > hourAgo }
        loadContactLinks()
        refreshContactLinkKeys()
        expireOutbox()
        pingWaitingContacts(force: false)
        publishLinked()
    }

    private func seen(_ key: Data, _ nick: String, _ hops: Int) {
        let peerId = MeshCrypto.origin(of: key).meshHex
        peerKeys[peerId] = key
        let name = nick.isEmpty ? String(peerId.prefix(8)) : nick
        allPeople[peerId] = MeshPerson(id: peerId, nickname: name, hops: hops, lastSeen: Date())
        if let id = contacts.first(where: { $0.value.currentKey == key })?.key {
            contacts[id]?.nickname = name
            updateChat(id) { $0.nickname = name }
        }
        publishPeople()
    }

    private func publishPeople() {
        people = allPeople.values.sorted { ($0.hops, $0.nickname.lowercased()) < ($1.hops, $1.nickname.lowercased()) }
        for chat in privateChats {
            let nearby = allPeople[chat.peerId] != nil
            if chat.isNearby != nearby { updateChat(chat.id) { $0.isNearby = nearby } }
        }
    }

    /// The contact for a sender key: current or retired key of an existing contact, else a new one.
    /// A late message from a retired key never changes the contact's current key.
    private func contactId(for key: Data, nickname: String) -> String {
        if let c = contacts.values.first(where: { $0.currentKey == key || $0.retiredKeys.contains(key) }) { return c.id }
        let name = nickname.isEmpty ? String(MeshCrypto.origin(of: key).meshHex.prefix(8)) : nickname
        let contact = MeshContact(id: UUID().uuidString, currentKey: key, nickname: name)
        contacts[contact.id] = contact
        privateChats.insert(MeshPrivateChat(id: contact.id, nickname: name, peerId: contact.peerId,
                                            unread: 0, lastMessage: nil, isNearby: true), at: 0)
        if let next = pendingRekeys.removeValue(forKey: key)?.newKey {
            applyRekey(contact.id, to: next)
        } else {
            syncContactKeys()
        }
        return contact.id
    }

    /// The engine sends a REKEY to every contact before it rotates the identity.
    private func syncContactKeys() {
        let keys = contacts.values.map(\.currentKey).filter(MeshCrypto.isValidPublicKey)
        engine.run { $0.setContactKeys(keys) }
    }

    @discardableResult
    private func addTeamMessage(_ teamId: String, _ m: MeshChatMessage, countUnread: Bool) -> Bool {
        let list = teamMessageStore[teamId] ?? []
        guard !CrowdMesh.contains(m, list) else { return false }
        let updated = CrowdMesh.adding(m, to: list)
        teamMessageStore[teamId] = updated
        let kept = CrowdMesh.contains(m, updated)
        if let i = teams.firstIndex(where: { $0.id == teamId }) {
            teams[i].lastMessage = updated.last
            if countUnread && kept { teams[i].unread += 1 }
        }
        return countUnread && kept
    }

    @discardableResult
    private func addPrivateMessage(_ chatId: String, _ m: MeshChatMessage, countUnread: Bool) -> Bool {
        let list = privateMessageStore[chatId] ?? []
        guard !CrowdMesh.contains(m, list) else { return false }
        let updated = CrowdMesh.adding(m, to: list)
        privateMessageStore[chatId] = updated
        let kept = CrowdMesh.contains(m, updated)
        updateChat(chatId) { chat in
            chat.lastMessage = updated.last
            if countUnread && kept { chat.unread += 1 }
        }
        if let i = privateChats.firstIndex(where: { $0.id == chatId }), i != 0 {
            privateChats.insert(privateChats.remove(at: i), at: 0)
        }
        return countUnread && kept
    }

    private func updateChat(_ id: String, _ change: (inout MeshPrivateChat) -> Void) {
        guard let i = privateChats.firstIndex(where: { $0.id == id }) else { return }
        change(&privateChats[i])
    }

    private func mine(_ messageId: Data, _ text: String, _ status: MeshDeliveryStatus) -> MeshChatMessage {
        MeshChatMessage(id: messageId.meshHex, senderName: nickname, senderId: "", text: text,
                        date: Date(), isMine: true, hops: nil, status: status)
    }

    private func received(_ messageId: Data, _ key: Data, _ nick: String, _ text: String, _ timestamp: UInt64, _ hops: Int) -> MeshChatMessage {
        // A phone whose clock runs fast must not pin its messages below newer ones.
        let date = min(Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000), Date())
        let peerId = MeshCrypto.origin(of: key).meshHex
        return MeshChatMessage(id: messageId.meshHex, senderName: nick.isEmpty ? String(peerId.prefix(8)) : nick,
                               senderId: peerId, text: text, date: date, isMine: false, hops: hops, status: .received)
    }

    private func checkedText(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.utf8.count <= MeshWire.maxTextBytes else { return nil }
        return t
    }

    private static func contains(_ m: MeshChatMessage, _ list: [MeshChatMessage]) -> Bool {
        list.contains { $0.id == m.id && $0.senderId == m.senderId }
    }

    private static func adding(_ m: MeshChatMessage, to list: [MeshChatMessage]) -> [MeshChatMessage] {
        if contains(m, list) { return list }
        return Array((list + [m]).sorted { $0.date < $1.date }.suffix(maxMessages))
    }

    private static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Diagnostic lines for field testing. Never message text.
    private func addLog(_ line: String) {
        log.append("\(CrowdMesh.logTime.string(from: Date())) \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    static let notificationId = "chatfort.crowdmesh.message"

    /// Lock-screen safe: never shows who wrote or what.
    private func notify(_ text: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Crowd mesh", comment: "crowd mesh notification title")
        content.body = text
        content.sound = .default
        let request = UNNotificationRequest(identifier: CrowdMesh.notificationId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func randomNickname() -> String { "anon\(1000 + Int(MeshCrypto.randomUInt32() % 9000))" }
}

// MARK: - Contacts and team keys

struct MeshContact {
    let id: String
    private(set) var currentKey: Data
    private(set) var retiredKeys: [Data] = []
    var nickname: String

    init(id: String, currentKey: Data, nickname: String) {
        self.id = id
        self.currentKey = currentKey
        self.nickname = nickname
    }

    var peerId: String { currentKey.isEmpty ? "" : MeshCrypto.origin(of: currentKey).meshHex }
    var retiredPeerIds: [String] { retiredKeys.map { MeshCrypto.origin(of: $0).meshHex } }

    mutating func retire(_ old: Data, for new: Data) {
        retiredKeys = Array((retiredKeys.filter { $0 != old && $0 != new } + [old]).suffix(8))
        currentKey = new
    }

    /// Keys of a merged duplicate chat, so its late messages land here.
    mutating func absorb(_ keys: [Data]) {
        let extra = keys.filter { $0 != currentKey && !retiredKeys.contains($0) }
        retiredKeys = Array((retiredKeys + extra).suffix(8))
    }
}

/// A team's daily key chain: key(d+1) = HKDF(key(d)). Keeps today's key, plus yesterday's for the
/// first 12 h after midnight UTC; tomorrow's is derived on demand (see `MeshDailyKeyChain`).
struct MeshTeamKeys: Codable, Equatable, MeshDailyKeyChain {
    let id: String
    var name: String
    var dayKey: Data
    var day: UInt64
    var previousKey: Data?

    static func ratchet(_ key: Data) -> Data { MeshCrypto.ratchet(key) }

    static func today(_ nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> UInt64 { MeshCrypto.day(of: nowMs) }

    /// Same team: one key chain reaches the other.
    func sameTeam(as other: MeshTeamKeys) -> Bool {
        var a = self, b = other
        let d = max(a.day, b.day)
        a.advance(to: d)
        b.advance(to: d)
        return a.dayKey == b.dayKey
    }
}

// MARK: - Keychain (this device only, erased by the panic wipe)

enum MeshKeychain {
    static let service = "chat.chatfort.crowdmesh"
    static let teamsAccount = "teams"
    static let nicknameAccount = "nickname"
    static let contactLinksAccount = "contact-links"

    static func save(_ data: Data, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        if case let .found(data) = read(account: account) { return data }
        return nil
    }

    enum ReadResult {
        case found(Data)
        case notFound
        /// Couldn't read (e.g. before the first unlock after a restart): not the same as "none".
        case failed
    }

    static func read(account: String) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &out) {
        case errSecSuccess: return (out as? Data).map(ReadResult.found) ?? .failed
        case errSecItemNotFound: return .notFound
        default: return .failed
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Engine (mesh queue)

enum MeshInbound {
    case announce(key: Data, nick: String, hops: Int)
    case publicPost(messageId: Data, key: Data, nick: String, text: String, timestamp: UInt64, hops: Int)
    case team(teamId: String, messageId: Data, key: Data, nick: String, text: String, timestamp: UInt64, hops: Int)
    case direct(messageId: Data, key: Data, nick: String, text: String, timestamp: UInt64, hops: Int)
    case ack(ackedId: String)
    case rekey(oldKey: Data, newKey: Data)
    // Wire v3 (linked contacts and media). `fresh`: timestamp within 2 min of now (anti-replay).
    case contactHeard(binding: String, fresh: Bool)
    case contactMessage(binding: String, uid: Data, text: String, timestamp: UInt64, hops: Int, fresh: Bool)
    case contactAck(binding: String, uid: Data)
    case contactMediaHeader(binding: String, uid: Data, header: MeshMediaHeader, timestamp: UInt64, hops: Int, fresh: Bool)
    case teamMediaHeader(teamId: String, uid: Data, key: Data, header: MeshMediaHeader, timestamp: UInt64, hops: Int)
    case media(MeshMediaAssembler.Event)
}

/// A linked contact's pair key, as the engine uses it (active profile only).
struct MeshEnginePair {
    let binding: String
    let keys: MeshPairKeys
    let myRole: UInt8
}

final class MeshEngine: MeshLinkLayerDelegate {
    static let tickInterval: TimeInterval = 5
    static let announceInterval: TimeInterval = 120
    static let identityLifetime: TimeInterval = 15 * 60
    /// DIRECTs to the previous identity still open for this long after a rotation.
    static let previousIdentityGrace: TimeInterval = 15 * 60

    let queue = DispatchQueue(label: "chat.chatfort.crowdmesh", qos: .userInitiated)
    weak var host: CrowdMesh?

    // Owned by `queue`
    private var router: MeshRouter?
    private var ble: MeshBleLinkLayer?
    private var identity: MeshIdentity?
    private var previousIdentity: (identity: MeshIdentity, until: TimeInterval)?
    private var identitySince: TimeInterval = 0
    private var lastAnnounce: TimeInterval = 0
    private var nickname = ""
    private var teams: [MeshTeamKeys] = []
    private var contactKeys: [Data] = []
    private var timer: DispatchSourceTimer?
    private var bleState: MeshBleState = .starting
    /// Our public keys from this app run: neighbours serve our old packets back for up to an hour,
    /// including after a stop/start. Cleared only by a wipe.
    private var ownKeys: [Data] = []
    // Wire v3
    private var pairs: [String: MeshEnginePair] = [:]
    /// CONTACT targets per hour: hour → tag → (binding, that hour's day key). Built on demand for the
    /// hour of each packet's own (signed) timestamp, so stored packets relayed hours later still match.
    private var tagIndexes: [UInt64: [Data: (binding: String, dayKey: Data)]] = [:]
    private let assembler = MeshMediaAssembler()
    private var lastPong: [String: TimeInterval] = [:]
    static let pongInterval: TimeInterval = 60
    /// Chunks of one media item go out this far apart, behind live text.
    static let chunkSpacing: TimeInterval = 0.1

    func run(_ work: @escaping (MeshEngine) -> Void) {
        queue.async { work(self) }
    }

    /// Monotonic and counts device sleep, unlike systemUptime: the 15-minute identity must not stretch
    /// while the phone sleeps in the background.
    static func monotonicNow() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }
    private var uptime: TimeInterval { MeshEngine.monotonicNow() }
    private var nowMs: UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    func start(nickname: String, teams: [MeshTeamKeys]) {
        guard router == nil else { return }
        self.nickname = nickname
        self.teams = teams
        let id = MeshIdentity()
        identity = id
        rememberOwnKey(id.publicKey)
        identitySince = uptime
        previousIdentity = nil
        let r = MeshRouter()
        r.now = { MeshEngine.monotonicNow() }
        r.sendFrame = { [weak self] frame, link, priority in self?.ble?.send(frame, to: link, bulk: priority == .bulk) }
        r.deliver = { [weak self] packet, _, _ in self?.process(packet) }
        r.schedule = { [weak self] delay, work in self?.queue.asyncAfter(deadline: .now() + delay, execute: work) }
        r.log = { [weak self] line in self?.log(line) }
        router = r
        // One link layer for the app's lifetime: restarting the same instance is supported, and a
        // new one within 2 s of a stop would briefly advertise two mesh services.
        let b = ble ?? MeshBleLinkLayer(queue: queue, delegate: self)
        ble = b
        // A new session gets a new token too, or the old token would link the two identities.
        b.rotateToken()
        b.start()
        announce()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + MeshEngine.tickInterval, repeating: MeshEngine.tickInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        ble?.stop()
        router?.reset()
        router = nil
        identity = nil
        previousIdentity = nil
        contactKeys = []
    }

    /// Panic wipe: stop, and forget team keys, contact pairs, media in progress, nickname and our old keys.
    func wipe() {
        stop()
        teams = []
        nickname = ""
        ownKeys = []
        setPairs([])
        assembler.reset()
        lastPong = [:]
    }

    private func rememberOwnKey(_ key: Data) {
        ownKeys = Array((ownKeys + [key]).suffix(32))
    }

    func setNickname(_ nick: String) {
        nickname = nick
        announce()
    }

    func setTeams(_ t: [MeshTeamKeys]) { teams = t }
    func setContactKeys(_ keys: [Data]) { contactKeys = keys }

    /// Linked contacts of the active profile (wire v3).
    func setPairs(_ list: [MeshEnginePair]) {
        pairs = Dictionary(list.map { ($0.binding, $0) }, uniquingKeysWith: { _, b in b })
        tagIndexes = [:]
        lastPong = lastPong.filter { pairs[$0.key] != nil }
    }

    /// MESSAGE, ACK, PING or PONG to a linked contact.
    func sendContact(_ binding: String, kind: MeshContactKind, uid: Data, content: Data = Data()) {
        guard let router, let p = sealContact(binding, MeshContactBody(kind: kind, role: pairs[binding]?.myRole ?? 0, uid: uid, content: content))
        else { return }
        router.originate(p)
    }

    /// A photo or voice note to a linked contact: the header (kind MEDIA, uid), then the chunks.
    /// Resends pass the same header and bytes.
    func sendContactMedia(_ binding: String, uid: Data, header: MeshMediaHeader, data: Data) {
        guard let router, let pair = pairs[binding],
              let p = sealContact(binding, MeshContactBody(kind: .media, role: pair.myRole, uid: uid, content: header.encoded()))
        else { return }
        router.originate(p)
        sendChunks(data, header)
    }

    /// A photo or voice note to a team: CHANNEL with sealed kind 4 (uid | header), then the chunks.
    func sendTeamMedia(_ keys: MeshTeamKeys, uid: Data, header: MeshMediaHeader, data: Data, messageId: Data) {
        guard let router, let identity else { return }
        let now = nowMs
        guard let dayKey = keys.key(forDay: MeshCrypto.day(of: now), nowMs: now),
              let p = MeshCrypto.sealChannel(kind: .media, content: uid + header.encoded(), sender: identity,
                                             dayKey: dayKey, timestamp: now, messageId: messageId)
        else { return }
        router.originate(p)
        sendChunks(data, header)
    }

    private func sealContact(_ binding: String, _ body: MeshContactBody) -> MeshPacket? {
        let now = nowMs
        guard var keys = pairs[binding]?.keys else { return nil }
        _ = keys.refresh(nowMs: now)
        guard let key = keys.key(forDay: MeshCrypto.day(of: now), nowMs: now) else { return nil }
        return MeshCrypto.sealContact(body, dayKey: key, timestamp: now)
    }

    /// All chunks of one item (one one-time key), originated ~100 ms apart as bulk.
    private func sendChunks(_ data: Data, _ header: MeshMediaHeader) {
        let chunks = MeshCrypto.mediaChunks(data, header: header, timestamp: nowMs)
        for (i, c) in chunks.enumerated() {
            queue.asyncAfter(deadline: .now() + MeshEngine.chunkSpacing * Double(i + 1)) { [weak self] in
                self?.router?.originate(c, priority: .bulk)
            }
        }
    }

    func sendPublic(text: String, nickname nick: String, messageId: Data) {
        guard let router, let identity else { return }
        let body = MeshMessageBody(nick: nick, text: text).encoded()
        router.originate(MeshPacket.make(type: .publicPost, maxTtl: MeshWire.messageMaxTtl, messageId: messageId,
                                         timestamp: nowMs, payload: body, signingKey: identity.signingKey))
    }

    func sendTeam(_ keys: MeshTeamKeys, text: String, nickname nick: String, messageId: Data) {
        guard let router, let identity else { return }
        let now = nowMs
        guard let dayKey = keys.key(forDay: MeshCrypto.day(of: now), nowMs: now),
              let p = MeshCrypto.sealChannel(content: MeshMessageBody(nick: nick, text: text).encoded(), sender: identity,
                                             dayKey: dayKey, timestamp: now, messageId: messageId)
        else { return }
        router.originate(p)
    }

    func sendDirect(to key: Data, text: String, nickname nick: String, messageId: Data) {
        guard let router, let identity,
              let p = MeshCrypto.sealDirect(kind: .message, content: MeshMessageBody(nick: nick, text: text).encoded(),
                                            sender: identity, recipientKey: key, timestamp: nowMs, messageId: messageId)
        else { return }
        router.originate(p)
    }

    // MARK: tick: router upkeep, announcements, identity rotation

    private func tick() {
        guard let router else { return }
        router.tick()
        assembler.expire(uptime)
        let now = uptime
        if let prev = previousIdentity, now > prev.until { previousIdentity = nil }
        if now - identitySince >= MeshEngine.identityLifetime {
            rotateIdentity()
        } else if now - lastAnnounce >= MeshEngine.announceInterval {
            announce()
        }
        let links = ble?.linkCount ?? 0
        let state = bleState
        DispatchQueue.main.async { [weak host] in
            host?.engineStatus(state, links: links)
            host?.refreshPeopleFromEngine()
        }
    }

    private func announce() {
        guard let router, let identity else { return }
        lastAnnounce = uptime
        let body = MeshMessageBody(nick: nickname, text: "").encoded()
        router.originate(MeshPacket.make(type: .announce, maxTtl: MeshWire.announceMaxTtl, timestamp: nowMs,
                                         payload: body, signingKey: identity.signingKey))
    }

    /// Hand over to a new key: REKEY (signed by the old key) to every contact first, then switch,
    /// rotate the Bluetooth token and announce. The old key still opens DIRECTs for 15 minutes.
    private func rotateIdentity() {
        guard let router, let old = identity else { return }
        let new = MeshIdentity()
        let now = nowMs
        for key in contactKeys {
            if let p = MeshCrypto.sealDirect(kind: .rekey, content: new.publicKey, sender: old, recipientKey: key, timestamp: now) {
                router.originate(p)
            }
        }
        previousIdentity = (old, uptime + MeshEngine.previousIdentityGrace)
        identity = new
        rememberOwnKey(new.publicKey)
        identitySince = uptime
        ble?.rotateToken()
        log("New mesh identity (sent handover to \(contactKeys.count) contacts)")
        announce()
    }

    // MARK: delivered packets

    private func process(_ p: MeshPacket) {
        guard let identity else { return }
        switch p.packetType {
        case .announce:
            guard !ownKeys.contains(p.originKey), let body = MeshMessageBody.decode(p.payload) else { return }
            emit(.announce(key: p.originKey, nick: body.nick, hops: p.hops))
        case .publicPost:
            guard !ownKeys.contains(p.originKey), let body = MeshMessageBody.decode(p.payload) else { return }
            emit(.publicPost(messageId: p.messageId, key: p.originKey, nick: body.nick, text: body.text, timestamp: p.timestamp, hops: p.hops))
        case .channel:
            let now = nowMs
            for team in teams {
                guard let dayKey = team.key(forDay: MeshCrypto.day(of: p.timestamp), nowMs: now),
                      let sealed = MeshCrypto.openChannel(p, dayKey: dayKey)
                else { continue }
                guard !ownKeys.contains(sealed.senderKey) else { return }
                if sealed.sealedKind == .media {
                    guard sealed.content.count > 16, let header = MeshMediaHeader.decode(Data(sealed.content.dropFirst(16))) else { return }
                    emit(.teamMediaHeader(teamId: team.id, uid: Data(sealed.content.prefix(16)), key: sealed.senderKey,
                                          header: header, timestamp: p.timestamp, hops: p.hops))
                    expectMedia(header)
                    return
                }
                guard sealed.sealedKind == .message, let body = MeshMessageBody.decode(sealed.content) else { return }
                emit(.team(teamId: team.id, messageId: p.messageId, key: sealed.senderKey, nick: body.nick,
                           text: body.text, timestamp: p.timestamp, hops: p.hops))
                return
            }
        case .direct:
            var candidates = [identity]
            if let prev = previousIdentity { candidates.append(prev.identity) }
            for me in candidates {
                guard let sealed = MeshCrypto.openDirect(p, recipient: me) else { continue }
                handleDirect(sealed, p)
                return
            }
        case .contact:
            processContact(p)
        case .mediaChunk:
            if let e = assembler.add(p, now: uptime) { emit(.media(e)) }
        case nil:
            return
        }
    }

    /// CONTACT: one tag lookup, then the pair key of that hour. Own packets (our role) are dropped.
    private func processContact(_ p: MeshPacket) {
        let now = nowMs
        guard let hit = tagIndex(hour: p.timestamp / MeshCrypto.hourMs, now: now)[p.target], let pair = pairs[hit.binding],
              let body = MeshCrypto.openContact(p, dayKey: hit.dayKey), body.role != pair.myRole,
              let kind = body.contactKind
        else { return }
        let binding = hit.binding
        let fresh = MeshV3.isFresh(p.timestamp, nowMs: now)
        switch kind {
        case .message:
            guard body.content.count <= MeshV3.maxContactTextBytes, let text = String(data: body.content, encoding: .utf8) else { return }
            emit(.contactMessage(binding: binding, uid: body.uid, text: text, timestamp: p.timestamp, hops: p.hops, fresh: fresh))
        case .ack:
            emit(.contactAck(binding: binding, uid: body.uid))
        case .ping:
            // Answered only when fresh, so a recorded PING replayed elsewhere reveals nothing.
            if fresh, uptime - (lastPong[binding] ?? -.infinity) >= MeshEngine.pongInterval {
                lastPong[binding] = uptime
                sendContact(binding, kind: .pong, uid: body.uid)
            }
        case .pong:
            break
        case .media:
            guard let header = MeshMediaHeader.decode(body.content), header.nick.isEmpty else { return }
            emit(.contactMediaHeader(binding: binding, uid: body.uid, header: header, timestamp: p.timestamp, hops: p.hops, fresh: fresh))
            expectMedia(header)
        }
        emit(.contactHeard(binding: binding, fresh: fresh))
    }

    private func expectMedia(_ header: MeshMediaHeader) {
        for e in assembler.expect(header, now: uptime) { emit(.media(e)) }
    }

    /// Every linked contact's tag for `hour` (one HMAC per contact, cached per hour).
    private func tagIndex(hour: UInt64, now: UInt64) -> [Data: (binding: String, dayKey: Data)] {
        if let index = tagIndexes[hour] { return index }
        let t = hour * MeshCrypto.hourMs
        var index: [Data: (binding: String, dayKey: Data)] = [:]
        for pair in pairs.values {
            // A chain saved days ago may be behind: ratchet a copy to today first.
            var keys = pair.keys
            _ = keys.refresh(nowMs: now)
            guard let key = keys.key(forDay: MeshCrypto.day(of: t), nowMs: now) else { continue }
            index[MeshCrypto.contactTag(dayKey: key, timestamp: t)] = (pair.binding, key)
        }
        // The router accepts packets within 6 h of now: older and newer hours are never asked for.
        let nowHour = now / MeshCrypto.hourMs
        tagIndexes = tagIndexes.filter { $0.key + 8 >= nowHour && $0.key <= nowHour + 8 }
        tagIndexes[hour] = index
        return index
    }

    private func handleDirect(_ sealed: MeshSealedBody, _ p: MeshPacket) {
        switch sealed.sealedKind {
        case .message:
            guard let body = MeshMessageBody.decode(sealed.content) else { return }
            emit(.direct(messageId: p.messageId, key: sealed.senderKey, nick: body.nick, text: body.text,
                         timestamp: p.timestamp, hops: p.hops))
            // Receipt to the inner sender, from our current identity.
            if let router, let identity,
               let ack = MeshCrypto.sealDirect(kind: .ack, content: p.messageId, sender: identity,
                                               recipientKey: sealed.senderKey, timestamp: nowMs) {
                router.originate(ack)
            }
        case .ack:
            guard sealed.content.count == 16 else { return }
            emit(.ack(ackedId: sealed.content.meshHex))
        case .rekey:
            guard MeshCrypto.isValidPublicKey(sealed.content) else { return }
            emit(.rekey(oldKey: sealed.senderKey, newKey: sealed.content))
        case .media, nil:
            // Media goes only to linked contacts (CONTACT) and teams (CHANNEL), never DIRECT.
            return
        }
    }

    private func emit(_ event: MeshInbound) {
        DispatchQueue.main.async { [weak host] in host?.engineReceived(event) }
    }

    private func log(_ line: String) {
        DispatchQueue.main.async { [weak host] in host?.engineLog(line) }
    }

    // MARK: MeshLinkLayerDelegate (on `queue`)

    func linkLayer(linkUp link: MeshLinkID) {
        router?.linkUp(link)
        let links = ble?.linkCount ?? 0
        DispatchQueue.main.async { [weak host] in host?.engineLinks(links) }
    }

    func linkLayer(linkDown link: MeshLinkID) {
        router?.linkDown(link)
        let links = ble?.linkCount ?? 0
        DispatchQueue.main.async { [weak host] in host?.engineLinks(links) }
    }

    func linkLayer(received frame: Data, from link: MeshLinkID) {
        router?.receive(frame, from: link)
    }

    func linkLayer(stateChanged state: MeshBleState) {
        bleState = state
        let links = ble?.linkCount ?? 0
        DispatchQueue.main.async { [weak host] in host?.engineStatus(state, links: links) }
    }

    func linkLayer(log line: String) { log(line) }
}

extension CrowdMesh {
    fileprivate func refreshPeopleFromEngine() { refreshPeople() }
}

extension MeshMediaInfo {
    init(_ h: MeshMediaHeader, file: String? = nil) {
        self.init(mediaId: h.mediaId.meshHex, kind: h.type == .voice ? .voice : .photo, durationMs: h.durationMs,
                  width: h.width, height: h.height, file: file, received: file == nil ? 0 : Int(h.chunkCount),
                  total: Int(h.chunkCount))
    }
}
