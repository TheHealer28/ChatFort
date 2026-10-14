import Foundation
import MultipeerConnectivity
import Combine

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

    private func startNearby() {
        // Use the current SimpleX profile name or fallback
        let profileName = currentProfileName()
        myDisplayName = NearbyDisplayName.create(from: profileName)
        service.start(displayName: myDisplayName)
        isSearching = true
    }

    private func stopNearby() {
        service.stop()
        isSearching = false
        // Mark all peers as disconnected
        for i in peers.indices {
            peers[i].connectionState = .disconnected
        }
        // Save conversations before stopping
        store.saveNow(conversations)
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
            print("NearbyModel: Cannot send — peer '\(toPeerId)' not found or not connected")
            return
        }

        do {
            try service.send(message, to: mcPeer)
            // Add to local conversation
            addMessageToConversation(message, peerId: toPeerId, peerDisplayName: peer.displayName)
        } catch {
            print("NearbyModel: Failed to send message: \(error)")
        }
    }

    // MARK: - Conversation Management (main thread only)

    /// Must be called on the main thread.
    private func addMessageToConversation(_ message: NearbyMessage, peerId: String, peerDisplayName: String) {
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
        store.clearAll()
    }

    // MARK: - Helpers (main thread only)

    private func currentProfileName() -> String {
        // Try to get the current user's display name from ChatModel
        if let user = ChatModel.shared.currentUser {
            return user.displayName
        }
        return "Activist"
    }

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
            self?.updatePeerState(peer, state: .disconnected)
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
            self.addMessageToConversation(message, peerId: peerId, peerDisplayName: displayName)
        }
    }
}
