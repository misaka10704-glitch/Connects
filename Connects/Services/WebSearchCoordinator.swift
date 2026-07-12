import Foundation

extension Notification.Name {
    /// userInfo["conversationID"] = String
    static let webSearchDidUpdate = Notification.Name("ConnectsWebSearchDidUpdate")
}

/// Per-conversation web-search jobs so multiple chats can browse in parallel
/// without cancelling or cross-wiring each other.
final class WebSearchCoordinator {
    static let shared = WebSearchCoordinator()

    private let lock = NSLock()
    /// conversationID → generation (bumped on start / cancel).
    private var generations: [String: UInt64] = [:]
    private var active: Set<String> = []

    private init() {}

    func isSearching(_ conversationID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active.contains(conversationID)
    }

    func searchingIDs() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// Begin (or replace) search for one conversation only.
    @discardableResult
    func begin(_ conversationID: String) -> UInt64 {
        lock.lock()
        let next = (generations[conversationID] ?? 0) &+ 1
        generations[conversationID] = next
        active.insert(conversationID)
        lock.unlock()
        postUpdate(conversationID)
        return next
    }

    func isCurrent(_ conversationID: String, generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active.contains(conversationID) && generations[conversationID] == generation
    }

    func finish(_ conversationID: String, generation: UInt64) {
        lock.lock()
        guard generations[conversationID] == generation else {
            lock.unlock()
            return
        }
        active.remove(conversationID)
        lock.unlock()
        postUpdate(conversationID)
    }

    /// Cancel one conversation's search. In-flight callbacks become no-ops.
    func cancel(_ conversationID: String) {
        lock.lock()
        let next = (generations[conversationID] ?? 0) &+ 1
        generations[conversationID] = next
        let wasActive = active.remove(conversationID) != nil
        lock.unlock()
        if wasActive {
            postUpdate(conversationID)
        }
    }

    private func postUpdate(_ conversationID: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .webSearchDidUpdate,
                object: nil,
                userInfo: ["conversationID": conversationID]
            )
        }
    }
}
