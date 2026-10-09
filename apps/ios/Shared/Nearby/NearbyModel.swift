import Foundation
import MultipeerConnectivity
import Combine

/// A pending incoming Nearby *message* request: a peer we haven't accepted has
/// messaged us. Their messages are held here until the user accepts, at which
/// point they flush into a normal conversation. Declining drops them.
struct NearbyMessageRequest: Identifiable, Equatable {
    let id: String              // peerId = full MCPeerID displayName (with suffix)
    let displayName: String     // user-visible name (suffix stripped)
    var messages: [NearbyMessage]
    let firstReceived: Date

    /// Preview of the first held message for the request row.
    var preview: String { messages.first?.text ?? "" }

    static func == (lhs: NearbyMessageRequest, rhs: NearbyMessageRequest) -> Bool {
        lhs.id == rhs.id && lhs.messages.count == rhs.messages.count
    }
}

/// Observable model that holds all Nearby P2P state and bridges NearbyService events to SwiftUI.
///
/// Thread Safety: All @Published properties are only accessed on the main thread.
/// MPC delegate callbacks (which fire on background threads) dispatch to main
/// before touching any published state.
class NearbyModel: ObservableObject {
    static let shared = NearbyModel()

    // MARK: - Published State (main thread only)

    @Published var nearbyMode: Bool = false {
        didSet {
            if nearbyMode {
                startNearby()
            } else {
                stopNearby()
            }
        }
    }

    @Published var peers: [NearbyPeer] = []
    @Published var conversations: [String: NearbyConversation] = [:]
    @Published var activePeerId: String? = nil
    @Published var isSearching: Bool = false
    /// Set when advertising/browsing fails to start (usually Local Network
    /// permission denied). Surfaced in the UI so Nearby stops failing silently.
    @Published var lastError: String? = nil

    /// Incoming message requests, keyed by peerId — a peer we haven't accepted
    /// has messaged us. Held until the user accepts (then flushed into a
    /// conversation) or declines (dropped). This is the consent gate.
    @Published var messageRequests: [String: NearbyMessageRequest] = [:]

    /// Peers whose conversations are open (you accepted their request, or you
    /// messaged them first). Session-scoped, matching how conversations are
    /// keyed by the per-session peerId.
    private var acceptedPeerIds: Set<String> = []
    /// Peers whose requests you declined this session — their messages are dropped.
    private var blockedPeerIds: Set<String> = []
    /// Peers whose chat you deleted — hidden from the list until they message
    /// again (which resurfaces them as a fresh request). Without this, a deleted
    /// chat's peer stays in the discovered list and the row looks undeleted.
    private var hiddenPeerIds: Set<String> = []

    /// Whether a peer is currently hidden from the list (deleted chat).
    func isHidden(_ peerId: String) -> Bool { hiddenPeerIds.contains(peerId) }

    /// Pending requests sorted oldest-first for display.
    var sortedMessageRequests: [NearbyMessageRequest] {
        messageRequests.values.sorted { $0.firstReceived < $1.firstReceived }
    }

    /// True once at least one peer has actually connected — lets the UI stop
    /// showing the "searching / check permissions" hint.
    var hasConnectedPeer: Bool { peers.contains { $0.connectionState == .connected } }

    /// A peer is allowed a normal conversation if you accepted them or already
    /// have history with them.
    private func isAccepted(_ peerId: String) -> Bool {
        acceptedPeerIds.contains(peerId) || conversations[peerId] != nil
    }

    // MARK: - Private

    private let service = NearbyService.shared
    private let store = NearbyStore.shared
    private var myDisplayName: String = ""

    private init() {
        service.delegate = self
        // Load persisted conversations
        conversations = store.load()
    }

    // MARK: - Start / Stop

    /// UserDefaults key for the stable per-install Nearby name suffix.
    private let nearbySuffixKey = "inqalaab_nearby_suffix"

    /// A 4-char suffix that stays the same across toggles and app relaunches, so
    /// other devices always see this device as the SAME peer (no duplicates).
    /// Reset on panic wipe so a wiped device gets a fresh Nearby identity.
    private func stableSuffix() -> String {
        if let s = UserDefaults.standard.string(forKey: nearbySuffixKey), s.count == 4 {
            return s
        }
        let s = String((0..<4).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        UserDefaults.standard.set(s, forKey: nearbySuffixKey)
        return s
    }

    /// The name other phones see, e.g. "Nearby-7K2F". Never the profile name:
    /// Multipeer Connectivity broadcasts it in plain text over Bluetooth/Wi-Fi to
    /// anyone nearby (the same leak Android fixed by hiding Find People Nearby).
    /// Built from the stable suffix, so dedup and conversations keep working.
    var myNearbyName: String { "Nearby-\(stableSuffix().uppercased())" }

    private func startNearby() {
        lastError = nil
        myDisplayName = NearbyDisplayName.create(from: myNearbyName, suffix: stableSuffix())
        service.start(displayName: myDisplayName)
        isSearching = true
    }

    private func stopNearby() {
        service.stop()
        isSearching = false
        messageRequests.removeAll()
        hiddenPeerIds.removeAll()
        // Mark all peers as disconnected
        for i in peers.indices {
            peers[i].connectionState = .disconnected
        }
        // Save conversations before stopping
        store.saveNow(conversations)
    }

    // MARK: - Message-request consent

    /// Accept a peer's message request: open the conversation and flush the held
    /// messages into it. Future messages from this peer go straight through.
    func acceptMessageRequest(_ peerId: String) {
        guard let req = messageRequests[peerId] else { return }
        acceptedPeerIds.insert(peerId)
        messageRequests[peerId] = nil
        for m in req.messages {
            addMessageToConversation(m, peerId: peerId, peerDisplayName: req.displayName)
        }
    }

    /// Decline a peer's message request: drop the held messages and ignore
    /// further messages from them this session.
    func declineMessageRequest(_ peerId: String) {
        messageRequests[peerId] = nil
        blockedPeerIds.insert(peerId)
    }

    // MARK: - Send Message

    func sendMessage(text: String, toPeerId: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let message = NearbyMessage(
            senderDisplayName: NearbyDisplayName.extractDisplayName(from: myDisplayName),
            text: text,
            isOutgoing: true
        )

        // Find the MCPeerID
        guard let peer = peers.first(where: { $0.id == toPeerId }),
              let mcPeer = peer.mcPeerID else {
            logger.error("NearbyModel: cannot send — peer not found or not connected")
            return
        }

        do {
            try service.send(message, to: mcPeer)
            // You initiated → this peer is accepted; their replies flow straight in.
            acceptedPeerIds.insert(toPeerId)
            addMessageToConversation(message, peerId: toPeerId, peerDisplayName: peer.displayName)
        } catch {
            logger.error("NearbyModel: failed to send message: \(error.localizedDescription)")
        }
    }

    // MARK: - Conversation Management (main thread only)

    /// Must be called on the main thread.
    private func addMessageToConversation(_ message: NearbyMessage, peerId: String, peerDisplayName: String) {
        // A new message un-hides a previously deleted chat.
        hiddenPeerIds.remove(peerId)
        if var conversation = self.conversations[peerId] {
            conversation.addMessage(message)
            self.conversations[peerId] = conversation
        } else {
            var conversation = NearbyConversation(
                id: peerId,
                peerDisplayName: peerDisplayName
            )
            conversation.addMessage(message)
            self.conversations[peerId] = conversation
        }
        self.store.scheduleSave(self.conversations)
    }

    /// Delete one Nearby conversation: drop its messages, revert acceptance (so
    /// the peer must re-accept if they message again), clear any pending request,
    /// and persist immediately. The peer stays discoverable.
    func deleteConversation(peerId: String) {
        conversations[peerId] = nil
        acceptedPeerIds.remove(peerId)
        messageRequests[peerId] = nil
        // Hide from the list so the row actually disappears (the peer may still
        // be discovered/connected). They reappear only if they message again.
        hiddenPeerIds.insert(peerId)
        if activePeerId == peerId { activePeerId = nil }
        store.saveNow(conversations)
    }

    func markConversationRead(_ peerId: String) {
        if var conversation = conversations[peerId] {
            conversation.markRead()
            conversations[peerId] = conversation
            store.scheduleSave(conversations)
        }
    }

    /// Sorted conversations for display — most recent first
    var sortedConversations: [NearbyConversation] {
        conversations.values
            .sorted { ($0.lastMessageTimestamp ?? .distantPast) > ($1.lastMessageTimestamp ?? .distantPast) }
    }

    /// Total unread count across all nearby conversations
    var totalUnreadCount: Int {
        conversations.values.reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: - App Lifecycle

    func onBackground() {
        if nearbyMode {
            service.stop()
            store.saveNow(conversations)
            isSearching = false
        }
    }

    func onForeground() {
        if nearbyMode {
            service.start(displayName: myDisplayName)
            isSearching = true
        }
    }

    // MARK: - Panic Mode

    func clearAllData() {
        service.stop()
        peers.removeAll()
        conversations.removeAll()
        activePeerId = nil
        nearbyMode = false
        isSearching = false
        messageRequests.removeAll()
        acceptedPeerIds.removeAll()
        blockedPeerIds.removeAll()
        hiddenPeerIds.removeAll()
        // Fresh Nearby identity after a wipe.
        UserDefaults.standard.removeObject(forKey: nearbySuffixKey)
        store.clearAll()
    }

    // MARK: - Helpers (main thread only)

    /// Ensures a peer entry exists for the given MCPeerID. Must be called on main thread.
    private func findOrCreatePeer(for mcPeer: MCPeerID) -> String {
        let peerId = mcPeer.displayName
        if peers.first(where: { $0.id == peerId }) == nil {
            let displayName = NearbyDisplayName.extractDisplayName(from: peerId)
            let peer = NearbyPeer(
                id: peerId,
                displayName: displayName,
                connectionState: .discovered,
                lastSeen: Date(),
                mcPeerID: mcPeer
            )
            peers.append(peer)
        }
        return peerId
    }

    /// Updates a peer's connection state. Must be called on main thread.
    private func updatePeerState(_ mcPeer: MCPeerID, state: NearbyConnectionState) {
        if let index = peers.firstIndex(where: { $0.id == mcPeer.displayName }) {
            peers[index].connectionState = state
            peers[index].lastSeen = Date()
            peers[index].mcPeerID = mcPeer
        }
    }
}

// MARK: - NearbyServiceDelegate
// All delegate callbacks are dispatched to the main thread before
// touching any @Published state. MPC fires these on background threads.

extension NearbyModel: NearbyServiceDelegate {
    func nearbyService(_ service: NearbyService, didDiscover peer: MCPeerID, withInfo info: [String: String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let _ = self.findOrCreatePeer(for: peer)
            self.updatePeerState(peer, state: .discovered)
        }
    }

    func nearbyService(_ service: NearbyService, didLose peer: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let peerId = peer.displayName
            guard let idx = self.peers.firstIndex(where: { $0.id == peerId }) else { return }
            // Don't drop a peer we're actively connected to or have history with;
            // just mark it offline. Otherwise remove the row so a departed
            // discovered-only peer doesn't linger as a ghost (a source of
            // apparent duplicates when it returns under a new name).
            if self.peers[idx].connectionState == .connected || self.conversations[peerId] != nil {
                self.updatePeerState(peer, state: .disconnected)
            } else {
                self.peers.remove(at: idx)
            }
        }
    }

    func nearbyService(_ service: NearbyService, peer: MCPeerID, didChangeState state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let nearbyState: NearbyConnectionState
            switch state {
            case .notConnected: nearbyState = .disconnected
            case .connecting: nearbyState = .connecting
            case .connected: nearbyState = .connected
            @unknown default: nearbyState = .disconnected
            }
            let _ = self.findOrCreatePeer(for: peer)
            self.updatePeerState(peer, state: nearbyState)
        }
    }

    func nearbyService(_ service: NearbyService, didReceive message: NearbyMessage, from peer: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let peerId = self.findOrCreatePeer(for: peer)
            let displayName = NearbyDisplayName.extractDisplayName(from: peer.displayName)

            // Consent gate: a declined peer is ignored; an accepted peer (or one
            // you have history with) goes straight to the conversation; everyone
            // else is held as a message request until the user accepts.
            if self.blockedPeerIds.contains(peerId) {
                return
            }
            if self.isAccepted(peerId) {
                self.addMessageToConversation(message, peerId: peerId, peerDisplayName: displayName)
            } else {
                var req = self.messageRequests[peerId]
                    ?? NearbyMessageRequest(id: peerId, displayName: displayName, messages: [], firstReceived: Date())
                req.messages.append(message)
                self.messageRequests[peerId] = req
            }
        }
    }

    func nearbyService(_ service: NearbyService, didFailToStart what: String, error: Error) {
        DispatchQueue.main.async { [weak self] in
            // MultipeerConnectivity surfaces a denied Local Network permission as
            // a start failure. We can't read the permission state directly (iOS
            // exposes no API), so we give the most actionable guidance.
            self?.lastError = String.localizedStringWithFormat(
                NSLocalizedString("Couldn't start Nearby (%@). Enable Local Network in Settings → Privacy & Security → Local Network, then reopen the app.", comment: "nearby start failure"),
                what
            )
        }
    }
}
