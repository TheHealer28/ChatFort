import Foundation
import MultipeerConnectivity

// MARK: - Connection State

enum NearbyConnectionState: String, Codable, Equatable {
    case discovered
    case connecting
    case connected
    case disconnected
}

// MARK: - Nearby Peer

struct NearbyPeer: Identifiable, Equatable {
    let id: String              // MCPeerID.displayName (includes random suffix)
    let displayName: String     // User-visible name (without suffix)
    var connectionState: NearbyConnectionState
    var lastSeen: Date
    var mcPeerID: MCPeerID?

    static func == (lhs: NearbyPeer, rhs: NearbyPeer) -> Bool {
        lhs.id == rhs.id &&
        lhs.displayName == rhs.displayName &&
        lhs.connectionState == rhs.connectionState
    }
}

// MARK: - Nearby Message

struct NearbyMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let senderDisplayName: String
    let text: String
    let timestamp: Date
    var isOutgoing: Bool

    /// Wire format excludes isOutgoing — it's set locally
    enum CodingKeys: String, CodingKey {
        case id, senderDisplayName, text, timestamp
    }

    init(id: UUID = UUID(), senderDisplayName: String, text: String, timestamp: Date = Date(), isOutgoing: Bool) {
        self.id = id
        self.senderDisplayName = senderDisplayName
        self.text = text
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        senderDisplayName = try container.decode(String.self, forKey: .senderDisplayName)
        text = try container.decode(String.self, forKey: .text)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isOutgoing = false // Default for received messages
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(senderDisplayName, forKey: .senderDisplayName)
        try container.encode(text, forKey: .text)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

// MARK: - Nearby Conversation

struct NearbyConversation: Identifiable, Codable, Equatable {
    let id: String              // Peer ID string
    let peerDisplayName: String
    var messages: [NearbyMessage]
    var unreadCount: Int
    var lastMessageTimestamp: Date?

    init(id: String, peerDisplayName: String, messages: [NearbyMessage] = [], unreadCount: Int = 0, lastMessageTimestamp: Date? = nil) {
        self.id = id
        self.peerDisplayName = peerDisplayName
        self.messages = messages
        self.unreadCount = unreadCount
        self.lastMessageTimestamp = lastMessageTimestamp
    }

    mutating func addMessage(_ message: NearbyMessage) {
        messages.append(message)
        lastMessageTimestamp = message.timestamp
        if !message.isOutgoing {
            unreadCount += 1
        }
        // Keep only last 500 messages
        if messages.count > 500 {
            messages = Array(messages.suffix(500))
        }
    }

    mutating func markRead() {
        unreadCount = 0
    }
}

// MARK: - Persistence Container

struct NearbyConversationsContainer: Codable {
    var conversations: [String: NearbyConversation]
    var lastSaved: Date

    init(conversations: [String: NearbyConversation] = [:]) {
        self.conversations = conversations
        self.lastSaved = Date()
    }
}

// MARK: - Display Name Utilities

enum NearbyDisplayName {
    /// Create a peer-safe display name with random suffix to avoid MCPeerID conflicts
    static func create(from profileName: String) -> String {
        let suffix = String((0..<4).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let truncated = String(profileName.prefix(11)) // MCPeerID has 63 char limit, leave room
        return "\(truncated)-\(suffix)"
    }

    /// Extract the user-visible display name (without suffix)
    static func extractDisplayName(from peerIDName: String) -> String {
        if let lastDash = peerIDName.lastIndex(of: "-"),
           peerIDName.distance(from: lastDash, to: peerIDName.endIndex) == 5 {
            return String(peerIDName[..<lastDash])
        }
        return peerIDName
    }
}
