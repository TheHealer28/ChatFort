//
//  CallIceServers.swift
//  ChatFort
//
//  The STUN/TURN servers for calls come from our web service, with relay logins that expire, so call
//  servers can be added or replaced without an app update. The list is fetched only around calls
//  and kept for a day.
//

import Foundation
import UIKit

final class CallIceServers {
    static let shared = CallIceServers()

    /// Public STUN of last resort: finds the phone's public address, never relays.
    static let publicStun = RTCIceServer(urls: ["stun:stun.cloudflare.com:3478"])

    private struct Response: Decodable {
        let ice_servers: [RTCIceServer]
        let ttl: Int
    }

    private struct Cached: Codable {
        var servers: [RTCIceServer]
        var fetchedAt: Date
        var ttl: TimeInterval
    }

    private let cacheKey = "inqalaab_call_ice_servers_v1"
    /// Fetch again after a day; the service's logins last 48 hours, so a cached one stays valid until then.
    private let refreshAfter: TimeInterval = 24 * 3600
    private let lock = NSLock()
    private var inFlight: Task<Void, Never>?
    /// Bumped by the wipe, so a fetch already under way can't save its result afterwards.
    private var generation = 0

    /// Servers for a call. The user's own (Settings › Calls) are handled by the caller; this gives ours
    /// while the login is valid, otherwise STUN only (calls still connect directly, as before).
    func current() -> [RTCIceServer] {
        if let c = cached(), Date() < c.fetchedAt.addingTimeInterval(c.ttl - 600) {
            return c.servers
        }
        return InqalaabServers.FALLBACK_CALL_STUN_SERVERS.map { RTCIceServer(urls: [$0]) } + [CallIceServers.publicStun]
    }

    /// When a call starts or rings: refresh a stale list in the background.
    func refreshIfStale() {
        if isStale() { _ = startFetch() }
    }

    /// Just before the call needs its servers: refresh a stale list, waiting at most `maxWait`.
    func prepareForCall(maxWait: TimeInterval = 2) async {
        guard isStale() else { return }
        await wait(for: startFetch(), upTo: maxWait)
    }

    /// Emergency wipe.
    func clear() {
        lock.lock()
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }

    private func isStale() -> Bool {
        guard let c = cached() else { return true }
        let age = Date().timeIntervalSince(c.fetchedAt)
        return age < -300 || age > min(refreshAfter, c.ttl / 2)
    }

    private func cached() -> Cached? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    private func startFetch() -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let t = inFlight { return t }
        let gen = generation
        let t = Task { [weak self] in
            await self?.fetch(gen)
            self?.fetchFinished(gen)
        }
        inFlight = t
        return t
    }

    private func fetchFinished(_ gen: Int) {
        lock.lock()
        if gen == generation { inFlight = nil }
        lock.unlock()
    }

    /// Saves a fetched list, unless the wipe ran since the fetch started.
    private func save(_ c: Cached, _ gen: Int) {
        guard let encoded = try? JSONEncoder().encode(c) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard gen == generation else { return }
        UserDefaults.standard.set(encoded, forKey: cacheKey)
    }

    private func fetch(_ gen: Int) async {
        guard let url = URL(string: InqalaabServers.CALL_SERVERS_ENDPOINT) else { return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                logger.warning("CallIceServers: non-200 response, keeping the current list")
                return
            }
            let r = try JSONDecoder().decode(Response.self, from: data)
            guard let servers = CallIceServers.validated(r.ice_servers), (600...7 * 86400).contains(r.ttl) else {
                logger.error("CallIceServers: invalid list, keeping the current one")
                return
            }
            save(Cached(servers: servers, fetchedAt: Date(), ttl: TimeInterval(r.ttl)), gen)
            logger.debug("CallIceServers: \(servers.count) servers, valid for \(r.ttl) s")
        } catch {
            logger.warning("CallIceServers: fetch failed, keeping the current list: \(error.localizedDescription)")
        }
    }

    /// Only STUN/TURN URLs, within sane limits.
    static func validated(_ servers: [RTCIceServer]) -> [RTCIceServer]? {
        let schemes = ["stun:", "stuns:", "turn:", "turns:"]
        guard !servers.isEmpty, servers.count <= 10 else { return nil }
        for s in servers {
            guard !s.urls.isEmpty, s.urls.count <= 10,
                  s.urls.allSatisfy({ u in u.count <= 256 && schemes.contains { u.hasPrefix($0) } }),
                  (s.username?.count ?? 0) <= 256, (s.credential?.count ?? 0) <= 256
            else { return nil }
        }
        return servers
    }

    private func wait(for task: Task<Void, Never>, upTo seconds: TimeInterval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(cont)
            Task { await task.value; once.resume() }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.resume() }
        }
    }

    /// Resumes the continuation once, whichever comes first (the lock makes it safe across threads).
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Void, Never>?
        init(_ cont: CheckedContinuation<Void, Never>) { self.cont = cont }
        func resume() {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume()
        }
    }
}

/// "Always use relay" is on but no relay server is available: asks before connecting directly, which
/// shows the user's IP address to the other person and to anyone watching the network. Calls (or group
/// legs) that need it at the same time share one question. It closes by itself, as "End call", when no
/// call needs it any more or after 30 seconds. If the app isn't in front, it shows as soon as it is.
@MainActor final class RelayFallbackPrompt {
    static let shared = RelayFallbackPrompt()
    private var waiters: [@MainActor () -> Bool] = []
    private var pending: Task<Bool, Never>?

    /// True: connect directly. False: end the call. `stillNeeded` is checked while the question is open.
    func ask(while stillNeeded: @escaping @MainActor () -> Bool) async -> Bool {
        waiters.append(stillNeeded)
        let task: Task<Bool, Never>
        if let p = pending {
            task = p
        } else {
            task = Task { await self.present() }
            pending = task
        }
        let answer = await task.value
        if pending == task {
            pending = nil
            waiters = []
        }
        return answer
    }

    private final class Choice { var value: Bool? }

    private func present() async -> Bool {
        let deadline = Date().addingTimeInterval(30)
        let choice = Choice()
        var alert: UIAlertController?
        while choice.value == nil {
            if Date() >= deadline || !waiters.contains(where: { $0() }) {
                alert?.dismiss(animated: true)
                return false
            }
            if alert == nil, let top = getTopViewController() {
                let a = UIAlertController(
                    title: NSLocalizedString("Relay not available", comment: "call alert title"),
                    message: NSLocalizedString("This call can't go through the relay right now. If you connect directly, the other person and anyone watching the network can see your IP address.", comment: "call alert message"),
                    preferredStyle: .alert
                )
                a.addAction(UIAlertAction(title: NSLocalizedString("End call", comment: "call alert action"), style: .cancel) { _ in choice.value = false })
                a.addAction(UIAlertAction(title: NSLocalizedString("Connect directly", comment: "call alert action"), style: .destructive) { _ in choice.value = true })
                top.present(a, animated: true)
                alert = a
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return choice.value ?? false
    }
}
