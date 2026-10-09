//
//  MeshStore.swift
//  ChatFort — Crowd mesh
//
//  Encrypted storage for chats with linked ChatFort contacts and for photos / voice notes (wire v3).
//  Everything is sealed with AES-256-GCM under a random key kept in the Keychain (this device only),
//  in Application Support/CrowdMesh (no backups). The panic wipe, the self-destruct passcode and
//  Delete database erase it. Main actor only.
//

import CryptoKit
import Foundation

/// One linked contact's mesh chat, as saved.
struct MeshContactChatState: Codable, Equatable {
    var messages: [MeshChatMessage] = []
    var unread = 0
    /// Our MESSAGE / MEDIA items not yet acknowledged, by uid (hex). Kept 24 h.
    var outbox: [String: MeshOutboxItem] = [:]
    /// Uids (hex) of items received from this contact, newest last (dedup across resends).
    var receivedUids: [String] = []
}

struct MeshOutboxItem: Codable, Equatable {
    var uid: Data
    var kind: UInt8
    var text: String?
    /// Encoded media header (with its media key) and the file holding the exact bytes sent, so
    /// every resend repeats identical chunks.
    var mediaHeader: Data?
    var mediaFile: String?
    var createdAt: Date
    var lastSentAt: Date
    /// Rounds sent, the first included.
    var sends: Int
}

@MainActor
enum MeshStore {
    private static let keyAccount = "store-key"
    private static let contactsFile = "contacts.bin"
    private static let mediaDir = "media"

    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("CrowdMesh", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir.appendingPathComponent(mediaDir, isDirectory: true), withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var url = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return dir
    }

    /// The sealing key; created on first use. Never replaced when it merely can't be read right now.
    private static func key(create: Bool) -> SymmetricKey? {
        switch MeshKeychain.read(account: keyAccount) {
        case let .found(k) where k.count == 32: return SymmetricKey(data: k)
        case .notFound where create:
            let k = MeshCrypto.randomBytes(32)
            MeshKeychain.save(k, account: keyAccount)
            return SymmetricKey(data: k)
        default: return nil
        }
    }

    private static func seal(_ data: Data) -> Data? {
        guard let key = key(create: true) else { return nil }
        return try? AES.GCM.seal(data, using: key).combined
    }

    private static func open(_ data: Data) -> Data? {
        guard let key = key(create: false), let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    private static func write(_ data: Data, to url: URL) {
        guard let sealed = seal(data) else { return }
        try? sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: contact chats

    /// The saved chats; [:] if there are none yet; nil if they exist but can't be read now (the
    /// Keychain is locked before the first unlock, say). Then nothing may be saved over them.
    static func loadContactChats() -> [String: MeshContactChatState]? {
        guard let url = directory?.appendingPathComponent(contactsFile) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let sealed = try? Data(contentsOf: url), let plain = open(sealed),
              let chats = try? JSONDecoder().decode([String: MeshContactChatState].self, from: plain)
        else { return nil }
        return chats
    }

    static func saveContactChats(_ chats: [String: MeshContactChatState]) {
        guard let url = directory?.appendingPathComponent(contactsFile) else { return }
        if chats.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let plain = try? JSONEncoder().encode(chats) {
            write(plain, to: url)
        }
    }

    // MARK: media files (photos, voice notes)

    /// Saves media bytes, returns the file name.
    static func saveMedia(_ data: Data) -> String? {
        guard let dir = directory?.appendingPathComponent(mediaDir, isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = MeshCrypto.randomBytes(12).meshHex
        write(data, to: dir.appendingPathComponent(name))
        return name
    }

    static func loadMedia(_ name: String) -> Data? {
        guard isSafeName(name), let url = directory?.appendingPathComponent(mediaDir).appendingPathComponent(name),
              let sealed = try? Data(contentsOf: url)
        else { return nil }
        return open(sealed)
    }

    static func deleteMedia(_ name: String) {
        guard isSafeName(name), let url = directory?.appendingPathComponent(mediaDir).appendingPathComponent(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes media files not in `keep` (team media from a previous run, orphans).
    static func deleteMedia(except keep: Set<String>) {
        guard let dir = directory?.appendingPathComponent(mediaDir),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return }
        for name in names where !keep.contains(name) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }

    /// Everything: chats, media and the key.
    static func wipe() {
        if let dir = directory { try? FileManager.default.removeItem(at: dir) }
        MeshKeychain.delete(account: keyAccount)
        deleteVoiceTempFiles()
    }

    /// Voice notes being recorded live in the temporary folder until sent; leftovers (the app was
    /// stopped mid-recording) are removed at launch and by a wipe.
    static func deleteVoiceTempFiles() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix("mesh-") && name.hasSuffix(".m4a") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isHexDigit }
    }
}
