import Foundation

/// Lightweight JSON file persistence for Nearby conversations.
/// Uses Documents directory (no size limit, sandboxed, encrypted at rest with iOS Data Protection).
class NearbyStore {
    static let shared = NearbyStore()

    private let fileName = "inqalaab_nearby_conversations.json"
    private var saveWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "chat.inqalaab.nearby.store", qos: .utility)

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(fileName)
    }

    private init() {}

    // MARK: - Load

    func load() -> [String: NearbyConversation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let container = try decoder.decode(NearbyConversationsContainer.self, from: data)
            return container.conversations
        } catch {
            print("NearbyStore: Failed to load conversations: \(error)")
            return [:]
        }
    }

    // MARK: - Save (Debounced)

    /// Schedule a save after 1 second of inactivity. Multiple rapid calls coalesce into one write.
    func scheduleSave(_ conversations: [String: NearbyConversation]) {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveSync(conversations)
        }
        saveWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    /// Immediately save (used on app background or panic wipe).
    func saveNow(_ conversations: [String: NearbyConversation]) {
        saveWorkItem?.cancel()
        queue.sync {
            saveSync(conversations)
        }
    }

    private func saveSync(_ conversations: [String: NearbyConversation]) {
        do {
            let container = NearbyConversationsContainer(conversations: conversations)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(container)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            print("NearbyStore: Failed to save conversations: \(error)")
        }
    }

    // MARK: - Clear All (Panic Mode)

    func clearAll() {
        saveWorkItem?.cancel()
        try? FileManager.default.removeItem(at: fileURL)
        print("NearbyStore: All nearby conversations cleared")
    }
}
