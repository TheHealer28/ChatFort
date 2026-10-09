//
//  MeshLinkBridge.swift
//  ChatFort — Crowd mesh
//
//  Links ChatFort contacts for the mesh through their chats (wire v3): sends each ready
//  direct contact of the active profile a hidden "chatfortMeshLink" message with a random seed,
//  handles the ones that arrive, and deletes them locally (internal mode) right away. They never
//  show: not in the chat list, the chat, the unread count or a notification (the NSE skips them).
//  Link messages for another profile stay in its database until that profile is active.
//

import Foundation
import InqalaabChat

@MainActor
enum MeshLinkBridge {
    /// Link messages go out 1 every 2 s.
    static let sendSpacing: TimeInterval = 2

    private struct Outgoing {
        let userId: Int64
        let contactId: Int64
        let binding: String
        let offer: MeshLinkOffer
    }

    private static var sendQueue: [Outgoing] = []
    private static var sending = false
    private static var refreshing = false
    private static var refreshAgain = false
    /// Bumped by `reset()` (wipes): work started before it is dropped.
    private static var generation = 0
    /// Chats already swept, with their newest item's time then: unchanged chats aren't read again.
    private static var swept: [ChatId: Date] = [:]
    /// Link items already handled (the live path and a sweep can both see one before it's deleted).
    private static var handledItems = Set<Int64>()

    /// Never sent: identifies the contact, and a reused contact ID never matches an old one.
    static func binding(userId: Int64, contact: Contact) -> String {
        "u\(userId):c\(contact.contactId)@\(Int64((contact.createdAt.timeIntervalSince1970 * 1000).rounded()))"
    }

    /// Wipes: forget queued sends and memos, and drop work in flight.
    static func reset() {
        generation += 1
        sendQueue = []
        swept = [:]
        handledItems = []
        refreshAgain = false
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(scannedKeyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// After the chat starts, a profile switch, coming to the foreground or a contact connecting:
    /// tells the mesh who the active profile's contacts are, handles link messages left in their
    /// chats, and sends what is due.
    static func refresh() {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        let m = ChatModel.shared
        guard m.chatRunning == true, let user = m.currentUser else { return }
        // Not mesh work, but due at exactly these moments (a profile's chats loaded): preset cards and
        // the address of a newly added profile.
        InqalaabServers.shared.profileChatsLoaded()
        refreshing = true
        let gen = generation
        let userId = user.userId
        var names: [String: String] = [:]
        var ready: [String: Int64] = [:]
        var directChats: [ChatId] = []
        var toSweep: [(id: ChatId, stamp: Date?)] = []
        for chat in m.chats {
            guard case let .direct(contact) = chat.chatInfo else { continue }
            let b = binding(userId: userId, contact: contact)
            names[b] = contact.chatViewName
            directChats.append(chat.id)
            // "Delete conversation" keeps the contact but its chat must stay hidden: no offers.
            if contact.ready && contact.active && !contact.chatDeleted { ready[b] = contact.contactId }
            // Unhandled link messages that arrived for this app are unread (never shown).
            let last = chat.chatItems.last
            let mayHoldLink = chat.chatStats.unreadCount > 0 || last?.content.msgContent?.isChatfortMeshLink == true
            if mayHoldLink, last.map({ swept[chat.id] != $0.meta.itemTs }) ?? true {
                toSweep.append((chat.id, last?.meta.itemTs))
            }
        }
        CrowdMesh.shared.setActiveContacts(names)
        Task {
            var deleted = false
            // Once per profile: link messages an older ChatFort already showed (and the user read)
            // before this update can be anywhere in a chat, so search every direct chat for them.
            if !UserDefaults.standard.bool(forKey: scannedKey(userId)) {
                var complete = true
                for chatId in directChats {
                    for text in MeshLinkContent.knownFallbackTexts {
                        guard gen == generation, ChatModel.shared.currentUser?.userId == userId else {
                            complete = false
                            break
                        }
                        switch await sweep(chatId, userId: userId, search: text) {
                        case .failed: complete = false
                        case let .done(removed): deleted = deleted || removed
                        }
                    }
                }
                if gen == generation, ChatModel.shared.currentUser?.userId == userId {
                    // A chat that keeps failing mustn't make every refresh scan them all: 3 tries.
                    let tries = UserDefaults.standard.integer(forKey: scannedKey(userId) + ".tries") + 1
                    UserDefaults.standard.set(tries, forKey: scannedKey(userId) + ".tries")
                    if complete || tries >= 3 { UserDefaults.standard.set(true, forKey: scannedKey(userId)) }
                }
            }
            for (chatId, stamp) in toSweep {
                guard gen == generation, ChatModel.shared.currentUser?.userId == userId else { break }
                if case let .done(removed) = await sweep(chatId, userId: userId, search: "") {
                    deleted = deleted || removed
                    if let stamp { swept[chatId] = stamp }
                }
            }
            if gen == generation, ChatModel.shared.currentUser?.userId == userId {
                for (b, message) in CrowdMesh.shared.linkMessagesToSend(readyBindings: Array(ready.keys)) {
                    if let contactId = ready[b] { enqueue(Outgoing(userId: userId, contactId: contactId, binding: b, offer: message)) }
                }
                if deleted, let chats = try? await apiGetChatsAsync(), ChatModel.shared.currentUser?.userId == userId {
                    ChatModel.shared.updateChats(chats)
                }
            }
            refreshing = false
            if refreshAgain {
                refreshAgain = false
                refresh()
            }
        }
    }

    /// A live link message (the newChatItems event), already kept out of the chat model.
    static func received(_ link: MeshLinkContent, item: ChatItem, contact: Contact, userId: Int64) {
        handle(link, itemId: item.id, contact: contact, userId: userId)
        delete([item.id], contactId: contact.contactId)
    }

    // MARK: - Internals

    private static let scannedKeyPrefix = "chatfort.meshLinkScan.v3."
    private static func scannedKey(_ userId: Int64) -> String { scannedKeyPrefix + "u\(userId)" }

    private static func handle(_ link: MeshLinkContent, itemId: Int64, contact: Contact, userId: Int64) {
        guard handledItems.insert(itemId).inserted else { return }
        if handledItems.count > 2000 { handledItems = [itemId] }
        guard link.v == 3, let seed = Data(base64URLNoPad: link.seed), seed.count == 32, link.day >= 0 else { return }
        let b = binding(userId: userId, contact: contact)
        let offer = MeshLinkOffer(seed: seed, day: UInt64(link.day), ack: link.ack)
        // The answer is saved as unsent first: if it can't go now, the next refresh sends it.
        if let reply = CrowdMesh.shared.receiveLinkOffer(offer, from: b), contact.ready && contact.active && !contact.chatDeleted {
            enqueue(Outgoing(userId: userId, contactId: contact.contactId, binding: b, offer: reply))
        }
    }

    private enum SweepResult {
        case done(removedAny: Bool)
        case failed
    }

    /// Handles the link messages in one chat (oldest first) and deletes them.
    private static func sweep(_ chatId: ChatId, userId: Int64, search: String) async -> SweepResult {
        guard let (chat, _) = try? await apiGetChat(chatId: chatId, scope: nil, pagination: .last(count: search.isEmpty ? 50 : 200),
                                                   search: search),
              case let .direct(contact) = chat.chatInfo
        else { return .failed }
        let links = chat.chatItems.filter { $0.content.msgContent?.isChatfortMeshLink == true }
        guard !links.isEmpty else { return .done(removedAny: false) }
        for item in links.sorted(by: { $0.meta.itemTs < $1.meta.itemTs }) {
            if case let .rcvMsgContent(.chatfortMeshLink(_, link)) = item.content {
                handle(link, itemId: item.id, contact: contact, userId: userId)
            }
        }
        let removed = (try? await apiDeleteChatItems(type: .direct, id: contact.contactId, scope: nil,
                                                     itemIds: links.map(\.id), mode: .cidmInternal)) != nil
        return removed ? .done(removedAny: true) : .failed
    }

    private static func enqueue(_ o: Outgoing) {
        // One pending message per contact: a newer one (an answer after an offer, say) replaces it.
        sendQueue.removeAll { $0.binding == o.binding }
        sendQueue.append(o)
        guard !sending else { return }
        sending = true
        let gen = generation
        Task {
            while gen == generation, !sendQueue.isEmpty {
                let next = sendQueue.removeFirst()
                // A profile switch since it was queued: the next refresh of that profile sends it.
                guard ChatModel.shared.currentUser?.userId == next.userId else { continue }
                if await send(next.offer, to: next.contactId), gen == generation {
                    CrowdMesh.shared.linkMessageSent(next.offer, to: next.binding)
                }
                try? await Task.sleep(nanoseconds: UInt64(sendSpacing * 1_000_000_000))
            }
            sending = false
        }
    }

    /// Sends quietly (no alerts: this is background work), then deletes our own copy.
    private static func send(_ offer: MeshLinkOffer, to contactId: Int64) async -> Bool {
        let content = MeshLinkContent(v: 3, seed: offer.seed.base64URLNoPad, day: Int64(offer.day), ack: offer.ack)
        let cmd = ChatCommand.apiSendMessages(type: .direct, id: contactId, scope: nil, live: false, ttl: nil, composedMessages: [
            ComposedMessage(msgContent: .chatfortMeshLink(text: MeshLinkContent.fallbackText, link: content))
        ])
        let r: APIResult<ChatResponse1> = await chatApiSendCmd(cmd)
        guard case let .result(.newChatItems(_, items)) = r else {
            logger.error("mesh link send failed")
            return false
        }
        delete(items.map(\.chatItem.id), contactId: contactId)
        return true
    }

    private static func delete(_ itemIds: [Int64], contactId: Int64) {
        guard !itemIds.isEmpty else { return }
        Task {
            do { _ = try await apiDeleteChatItems(type: .direct, id: contactId, scope: nil, itemIds: itemIds, mode: .cidmInternal) }
            catch { logger.error("mesh link item delete error: \(responseError(error))") }
        }
    }
}
