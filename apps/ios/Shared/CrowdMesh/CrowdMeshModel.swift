//
//  CrowdMeshModel.swift
//  ChatFort — Crowd mesh
//
//  Types the Crowd mesh screens read from `CrowdMesh` (the controller). Persisted only where
//  CrowdMesh saves them: nickname and teams (Keychain), and chats with linked ChatFort contacts
//  (encrypted, see MeshStore).
//

import Foundation

enum CrowdMeshStatus: Equatable {
    case stopped
    case starting
    case running
    /// Bluetooth is switched off in Settings / Control Centre.
    case bluetoothOff
    /// The user denied Bluetooth permission (Settings → ChatFort → Bluetooth).
    case unauthorized
    /// No Bluetooth LE on this device (simulator).
    case unsupported
}

enum MeshDeliveryStatus: String, Codable, Equatable {
    /// Mine, private: sent, not yet acknowledged.
    case onItsWay
    /// Mine, private: the recipient's phone acknowledged it.
    case delivered
    /// Mine, public or team: handed to the mesh (no receipts there).
    case sent
    /// Someone else's.
    case received
}

struct MeshChatMessage: Identifiable, Equatable, Codable {
    /// Message ID (hex); unique per message (for contact chats: the item's uid).
    let id: String
    let senderName: String
    /// Peer ID (hex) of the sender's key when it was received; "" for mine.
    let senderId: String
    let text: String
    let date: Date
    let isMine: Bool
    /// Received messages: how many phones it passed through (0 = right next to you). Nil for mine.
    let hops: Int?
    var status: MeshDeliveryStatus
    /// A photo or voice note (wire v3); `text` is its caption.
    var media: MeshMediaInfo? = nil
}

/// A photo or voice note in a chat. The bytes live in an encrypted file (MeshStore).
struct MeshMediaInfo: Equatable, Codable {
    enum Kind: UInt8, Codable { case photo = 1, voice = 2 }

    /// Media ID (hex), the chunks' target.
    let mediaId: String
    let kind: Kind
    var durationMs: UInt32
    var width: UInt16
    var height: UInt16
    /// MeshStore file name once complete (or, for mine, from the start).
    var file: String?
    var received: Int
    var total: Int
    var failed = false

    var isComplete: Bool { file != nil }
}

/// A ChatFort contact of the active profile, linked for the mesh (offline contact).
struct MeshLinkedContact: Identifiable, Equatable {
    /// "u<userId>:c<contactId>@<createdAt ms>" (never sent).
    let id: String
    var name: String
    /// A fresh PING, PONG or any packet heard from them in the last 5 minutes.
    var isNearby: Bool
    var lastHeard: Date?
    var unread: Int
    var lastMessage: MeshChatMessage?
}

struct MeshTeamInfo: Identifiable, Equatable {
    /// Local only (never sent).
    let id: String
    var name: String
    var unread: Int
    var lastMessage: MeshChatMessage?
}

/// Someone seen recently through an announcement or a message.
struct MeshPerson: Identifiable, Equatable {
    /// Peer ID (hex) of their current key.
    let id: String
    var nickname: String
    /// 0 = right next to you, n = through n phones.
    var hops: Int
    var lastSeen: Date
}

/// A private (end-to-end encrypted) conversation. Survives the other side's key rotations.
struct MeshPrivateChat: Identifiable, Equatable {
    /// Local only.
    let id: String
    var nickname: String
    /// Peer ID (hex) of their current key; used to match `MeshPerson`.
    var peerId: String
    var unread: Int
    var lastMessage: MeshChatMessage?
    /// Seen within the last few minutes (announcement or message).
    var isNearby: Bool
}

enum CrowdMeshError: Error, Equatable {
    case invalidTeamCode
    case alreadyInTeam
    case notRunning
    case tooLong
}
