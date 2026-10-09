//
//  MeshBleLink.swift
//  ChatFort — Crowd mesh
//
//  Bluetooth LE links for the Crowd mesh, compatible over the air with Android's BleLinkLayer.kt
//  (the link layer is unchanged in wire v2) and with the v2 changes in ios-alignment-2.md §2.
//
//  Every phone is both a GATT server (advertises the mesh service, accepts up to 4 phones) and a
//  GATT client (scans, connects to up to 4 phones). The phone that opened a link writes to RX
//  without response; the other phone answers with notifications on TX. Every frame (router frames
//  0x43…, link frames HELLO/BYE 4C 01 …) is split into `[seq][index][count][data]` fragments that
//  fit one write or notification.
//
//  Where iOS forces a difference from Android:
//  - iOS can't advertise manufacturer data, so an iPhone advertises the service UUID only and
//    tells its token in HELLO. Android v2 always connects to such phones; two iPhones connect after
//    a random 0–3 s delay. HELLO removes the duplicate links this causes.
//  - In the background iOS moves the service UUID to Apple's overflow area, which Android can't
//    read. Android never connects to a background iPhone, so the iPhone then connects to every
//    Android without the lower-token wait.
//  - A peripheral can neither refuse a subscription nor disconnect a central. A full iPhone
//    accepts and sends BYE. A closing incoming link is forgotten once its BYE is out. A phone that
//    still writes without a link gets another BYE.
//  - iOS reports no per-packet completion. Flow control uses canSendWriteWithoutResponse /
//    updateValue and the "ready" callbacks. The notification queue is shared by all centrals, so
//    incoming links are never closed for back-pressure.
//  - In the background iOS suspends the app between Bluetooth events and timers don't run. Overdue
//    housekeeping runs on the next Bluetooth event. After a suspension each link gets one
//    keepalive round before its silence counts.
//  - The token changes only when the host calls rotateToken() (with the mesh identity), never on a
//    timer of its own: token and identity must change together, or one would link the other.
//
//  Not done yet: state restoration (restore identifiers), so the mesh stops if iOS terminates the
//  app in the background.
//
//  Everything runs on the serial queue passed to init: every method, callback and timer.
//

import CoreBluetooth
import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum MeshBleState: Equatable {
    case starting, ready, poweredOff, unauthorized, unsupported
}

protocol MeshLinkLayerDelegate: AnyObject {
    // All calls happen on the `queue` passed to init.
    func linkLayer(linkUp link: MeshLinkID)
    func linkLayer(linkDown link: MeshLinkID)
    /// A reassembled router frame (link frames are consumed internally).
    func linkLayer(received frame: Data, from link: MeshLinkID)
    func linkLayer(stateChanged state: MeshBleState)
    func linkLayer(log line: String)
}

final class MeshBleLinkLayer: NSObject {
    static let serviceUUID = CBUUID(string: "5d8a9e20-3b61-4c7a-9f0e-2a6b1c4d8e70")
    /// The phone that opened the link writes here (write and write without response).
    static let rxUUID = CBUUID(string: "5d8a9e21-3b61-4c7a-9f0e-2a6b1c4d8e70")
    /// The phone that accepted the link notifies here.
    static let txUUID = CBUUID(string: "5d8a9e22-3b61-4c7a-9f0e-2a6b1c4d8e70")

    /// Android's constants (BleLinkLayer.kt, same values in seconds), then the iOS-only ones.
    private enum K {
        /// Links this phone opens itself.
        static let maxClientLinks = 4
        /// Links it accepts. Kept separate, so strangers connecting in can't take every slot.
        static let maxServerLinks = 4
        /// Android rejects attribute values over 512 bytes, whatever the MTU.
        static let maxAttributeValue = 512
        static let connectTimeout: TimeInterval = 15
        static let maxQueuedFrames = 300
        static let maxWriteRetries = 100
        static let retryDelay: TimeInterval = 0.04
        static let housekeeping: TimeInterval = 5
        static let advertiseRetry: TimeInterval = 30
        static let serverRetry: TimeInterval = 30
        static let candidateTTL: TimeInterval = 60
        /// Only connect to phones heard recently: old addresses stop working when a phone re-advertises.
        static let candidateFresh: TimeInterval = 15
        static let symmetryOverride: TimeInterval = 20
        static let rotateEvery: TimeInterval = 120
        static let minAgeToRotate: TimeInterval = 180
        static let rotatedOutBackoff: TimeInterval = 60
        /// A link that stays silent this long is dead (e.g. the other phone's app was killed).
        static let linkSilent: TimeInterval = 90
        /// Idle links send a hello this often, which keeps them provably alive.
        static let keepalive: TimeInterval = 30
        /// A new link must identify itself this quickly.
        static let helloDeadline: TimeInterval = 15
        /// How long a closing incoming link stays around to deliver its bye.
        static let byeGrace: TimeInterval = 2
        /// After a token change: hello over the links first, then re-advertise.
        static let readvertiseDelay: TimeInterval = 2
        static let maxBackoff: TimeInterval = 60

        // iOS only
        /// Two tokenless phones (iPhones) wait a random 0...this before connecting.
        static let tokenlessJitter: TimeInterval = 3
        /// Restart the scan this often: in the background iOS reports each phone once per scan.
        static let scanRefresh: TimeInterval = 10
        /// Longest single (prepared) write accepted on RX, like Android v2.
        static let maxWriteLength = 4096
        /// A housekeeping pass this late means the app was suspended.
        static let resumeGap: TimeInterval = 15
        /// After a suspension, links get this long to be heard from before counting as silent.
        static let resumeGrace: TimeInterval = 30
        /// Don't reconnect to a phone while its cancelled connection is winding down.
        static let cancelSettle: TimeInterval = 5
        /// A closing incoming link is forgotten once its bye went to CoreBluetooth, at the latest after this.
        static let byeMaxWait: TimeInterval = 10
        /// At most one bye this often to a phone that writes to us without a link.
        static let strayByeEvery: TimeInterval = 10
        /// Suspensions at least this long get their own log line (all are counted in the status line).
        static let logSuspensionOver: TimeInterval = 60
        static let statusEvery: TimeInterval = 60
        /// "found …" lines per status period; the status line counts the rest.
        static let foundLogsPerStatus = 20
        static let minFragment = 20
    }

    private final class Link {
        let id: MeshLinkID
        /// "c:<peripheral id>" for links we opened, "s:<central id>" for links we accepted.
        let key: String
        let peer: UUID
        let isClient: Bool
        let peripheral: CBPeripheral?
        let central: CBCentral?
        /// What we connected to ("Android 3f4e", "iPhone 9C1D"); empty for incoming links.
        let target: String
        let createdAt: TimeInterval
        /// Client links: the neighbour's RX characteristic we write to.
        var rx: CBCharacteristic?
        /// Transport ready: fragments can be sent.
        var up = false
        /// The delegate was told linkUp and not yet linkDown.
        var reported = false
        /// An incoming link being wound down: it only carries our bye now.
        var closing = false
        /// An incoming link accepted only to send a bye (no free slot).
        var refused = false
        var closingSince: TimeInterval = 0
        /// The app was suspended and this link got extra time to be heard from; cleared by any receipt.
        var silenceGraceGiven = false
        /// The neighbour's token, from its hello.
        var peerToken: UInt32?
        /// Every token the neighbour has used on this link; stale adverts can still carry an old one.
        var peerTokens = Set<UInt32>()
        var live: [Data] = []
        var bulk: [Data] = []
        var fragments: [Data] = []
        var nextFragment = 0
        var retryScheduled = false
        var writeRetries = 0
        var dropped = 0
        var lastDropLog: TimeInterval = 0
        let fragmenter = MeshFragmenter()
        let reassembler = MeshReassembler()
        var lastReceived: TimeInterval
        var lastSent: TimeInterval

        init(id: MeshLinkID, key: String, peer: UUID, isClient: Bool, peripheral: CBPeripheral?, central: CBCentral?,
             target: String, now: TimeInterval) {
            self.id = id
            self.key = key
            self.peer = peer
            self.isClient = isClient
            self.peripheral = peripheral
            self.central = central
            self.target = target
            createdAt = now
            lastReceived = now
            lastSent = now
        }

        var name: String { (isClient ? "out #" : "in #") + String(id) }
        var hasPendingData: Bool { nextFragment < fragments.count || !live.isEmpty || !bulk.isEmpty }
    }

    private final class Candidate {
        let peripheral: CBPeripheral
        /// From the advert (Android). Nil: the phone advertises no token (an iPhone).
        var token: UInt32?
        /// Tokenless phones: the token from a hello on a link we opened to it, so we know when
        /// we're already linked to it through a link it opened.
        var learnedToken: UInt32?
        var lastSeen: TimeInterval
        let firstSeen: TimeInterval
        /// Tokenless phones: when the random pre-connect delay ends.
        var connectAt: TimeInterval?

        init(peripheral: CBPeripheral, token: UInt32?, now: TimeInterval) {
            self.peripheral = peripheral
            self.token = token
            lastSeen = now
            firstSeen = now
        }

        var linkToken: UInt32? { token ?? learnedToken }
        var label: String {
            if let token { return "phone " + MeshBleLinkLayer.shortHex(token) }
            return "iPhone " + peripheral.identifier.uuidString.prefix(4)
        }
    }

    private enum SendResult { case sent, idle, blocked }

    private let queue: DispatchQueue
    private weak var delegate: MeshLinkLayerDelegate?
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var txCharacteristic: CBMutableCharacteristic?

    /// Random (CSPRNG) and sent in HELLO. The phone with the lower token opens the connection, so
    /// each pair links once. Android also advertises its token; iOS can't.
    private var token = MeshCrypto.randomUInt32()
    private var running = false
    /// Bumped on every start and stop, so timers from an earlier run do nothing.
    private var generation = 0
    private var serviceReady = false
    private var lastServerAttempt: TimeInterval = 0
    private var advertising = false
    private var lastAdvertiseAttempt: TimeInterval = 0
    private var scanning = false
    private var lastScanStart: TimeInterval = 0
    private var lastRotation: TimeInterval = 0
    private var lastTidy: TimeInterval = 0
    private var lastStatus: TimeInterval = 0
    private var reportedState: MeshBleState?
    private var loggedNoAdvertising = false
    private var foundSinceStatus = 0
    private var suspensionsSinceStatus = 0
    private var longestSuspension: TimeInterval = 0
    private var nextLinkId: MeshLinkID = 0
    /// In the background our advert is only in Apple's overflow area, which Android can't read.
    private var appInBackground = false
    private var appStateObservers: [NSObjectProtocol] = []

    private var byKey: [String: Link] = [:]
    private var candidates: [UUID: Candidate] = [:]
    private var backoff: [UUID: (fails: Int, until: TimeInterval)] = [:]
    /// Peripherals whose connection we cancelled, until CoreBluetooth confirms the disconnection.
    private var cancelling: [UUID: TimeInterval] = [:]
    /// Byes from stop() still waiting for room in the notification queue.
    private var stopByes: [(central: CBCentral, fragment: Data)] = []
    /// When we last sent a bye to a phone writing to us without a link.
    private var strayByes: [UUID: TimeInterval] = [:]

    /// `queue` is serial; CoreBluetooth managers are created on it and every callback runs on it.
    init(queue: DispatchQueue, delegate: MeshLinkLayerDelegate) {
        self.queue = queue
        self.delegate = delegate
        super.init()
    }

    deinit {
        appStateObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - API (call on `queue`)

    /// Links that are up (reported to the delegate and not yet down).
    var linkCount: Int {
        assertOnQueue()
        return byKey.values.filter { $0.reported }.count
    }

    var links: [MeshLinkID] {
        assertOnQueue()
        return byKey.values.filter { $0.reported }.map { $0.id }.sorted()
    }

    /// Creates the Bluetooth managers (the first call asks for Bluetooth permission), then scans
    /// and advertises whenever Bluetooth is on.
    func start() {
        assertOnQueue()
        guard !running else { return }
        running = true
        generation += 1
        let t = now()
        lastTidy = t
        lastStatus = t
        lastRotation = 0
        foundSinceStatus = 0
        suspensionsSinceStatus = 0
        longestSuspension = 0
        reportedState = nil
        stopByes.removeAll()
        observeAppState()
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: queue,
                                              options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: queue,
                                                    options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
        }
        log("BLE started (token \(Self.shortHex(token)))")
        updateState()
        centralStateChanged()
        peripheralStateChanged()
        scheduleHousekeeping(generation)
    }

    /// Sends BYE to phones connected to us, stops scanning and advertising and drops every link.
    func stop() {
        assertOnQueue()
        guard running else { return }
        running = false
        generation += 1
        let all = byKey.values.sorted { $0.id < $1.id }
        // A peripheral can't disconnect a central: ask the phones connected to us to close their end.
        // A bye that doesn't fit in the notification queue now goes out when it has room.
        var byes = 0
        stopByes = []
        for link in all where !link.isClient && link.reported {
            guard let c = link.central, let f = byeFragment(link.fragmenter, for: c) else { continue }
            byes += 1
            if !notify(f, to: c) { stopByes.append((c, f)) }
        }
        byKey.removeAll()
        if let cm = centralManager, cm.state == .poweredOn {
            if scanning { cm.stopScan() }
            for link in all where link.isClient {
                if let p = link.peripheral, p.state == .connecting || p.state == .connected {
                    // Remembered, so a restart of this instance ignores the late disconnection.
                    cancelling[link.peer] = now()
                    cm.cancelPeripheralConnection(p)
                }
            }
        }
        scanning = false
        stopAdvertising()
        candidates.removeAll()
        backoff.removeAll()
        reportedState = nil
        for link in all { reportDown(link) }
        log("BLE stopped (bye to \(byes) incoming link\(byes == 1 ? "" : "s")"
            + (stopByes.isEmpty ? ")" : ", \(stopByes.count) waiting for room)"))
        // Keep the GATT service (and this object) a moment longer so the byes go out, then remove it.
        let gen = generation
        queue.asyncAfter(deadline: .now() + K.byeGrace) { [self] in
            guard !running, generation == gen else { return }
            if !stopByes.isEmpty { log("\(stopByes.count) bye(s) not sent before the service was removed") }
            stopByes.removeAll()
            closeServer()
        }
    }

    /// Fragments and queues. bulk = low priority (catch-up); dropped first when the queue is full.
    func send(_ frame: Data, to link: MeshLinkID, bulk: Bool) {
        assertOnQueue()
        guard let l = byKey.values.first(where: { $0.id == link }), l.reported else { return }
        enqueue(l, frame, bulk: bulk)
    }

    /// New CSPRNG token. Tells current neighbours first (HELLO over every link), then re-advertises,
    /// so they don't mistake us for a new phone. The host calls it with every identity rotation.
    func rotateToken() {
        assertOnQueue()
        token = MeshCrypto.randomUInt32()
        log("token rotated (now \(Self.shortHex(token)))")
        guard running else { return }
        let hello = MeshLinkFrame.hello(token: token).encoded()
        for link in byKey.values.sorted(by: { $0.id < $1.id }) where link.reported {
            enqueue(link, hello, bulk: false)
        }
        // Android re-advertises because its advert carries the token. Ours doesn't; kept for parity.
        let gen = generation
        after(K.readvertiseDelay) { s in
            guard s.running, s.generation == gen, s.serviceReady else { return }
            s.startAdvertising()
        }
    }

    // MARK: - Pure helpers (testable without Bluetooth)

    /// Android's advert: manufacturer data = company 0xFFFF (little-endian ff ff) + token (u32 BE).
    static func advertisedToken(_ manufacturerData: Data?) -> UInt32? {
        guard let d = manufacturerData, d.count >= 6 else { return nil }
        let b = [UInt8](d.prefix(6))
        guard b[0] == 0xFF, b[1] == 0xFF else { return nil }
        return UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5])
    }

    /// Android: min(60 s, 2 s << min(failures, 5)).
    static func backoffDelay(failures: Int) -> TimeInterval {
        min(K.maxBackoff, 2 * TimeInterval(1 << min(max(failures, 0), 5)))
    }

    /// Android's duplicate rule, run by both phones on a hello that matches another link to the same
    /// phone. Returns true to close `link` (the one the hello came on), false to close `twin`.
    /// Opposite roles: keep the link opened by the phone with the lower token. Same role: keep the older.
    static func closesNewLink(linkIsClient: Bool, linkCreatedAt: TimeInterval, twinIsClient: Bool,
                              twinCreatedAt: TimeInterval, ourToken: UInt32, peerToken: UInt32) -> Bool {
        let weOpen = ourToken < peerToken
        if linkIsClient != twinIsClient { return linkIsClient != weOpen }
        return linkCreatedAt >= twinCreatedAt
    }

    struct WritePart {
        let central: UUID
        let offset: Int
        let value: Data
    }

    /// One didReceiveWrite batch → whole values. Offset 0 starts a value; a higher offset continues
    /// the previous one (a long/prepared write). Nil values: the batch must be rejected with `error`.
    static func assembleWrites(_ parts: [WritePart]) -> (values: [(central: UUID, data: Data)], error: CBATTError.Code?) {
        var out: [(central: UUID, data: Data)] = []
        for part in parts {
            if part.offset == 0 {
                out.append((part.central, part.value))
            } else if let last = out.last, last.central == part.central, part.offset == last.data.count {
                out[out.count - 1].data.append(part.value)
            } else {
                return ([], .invalidOffset)
            }
            if out[out.count - 1].data.count > K.maxWriteLength { return ([], .invalidAttributeValueLength) }
        }
        return (out, nil)
    }

    static func shortHex(_ token: UInt32) -> String { String(format: "%04x", token >> 16) }

    // MARK: - Queues and sending

    private func enqueue(_ link: Link, _ frame: Data, bulk: Bool) {
        if link.live.count + link.bulk.count >= K.maxQueuedFrames {
            // Shed catch-up traffic first; the minute-by-minute resync recovers anything dropped.
            if !link.bulk.isEmpty {
                link.bulk.removeFirst()
            } else {
                link.dropped += 1
                let t = now()
                if t - link.lastDropLog >= 5 {
                    link.lastDropLog = t
                    log("\(link.name): queue full, \(link.dropped) frame\(link.dropped == 1 ? "" : "s") dropped so far")
                }
                return
            }
        }
        if bulk { link.bulk.append(frame) } else { link.live.append(frame) }
        pump(link)
    }

    private func pump(_ link: Link) {
        while true {
            switch sendNext(link) {
            case .sent: continue
            case .idle: return
            case .blocked:
                // Incoming links resume in peripheralManagerIsReady(toUpdateSubscribers:).
                if link.isClient { retryLater(link) }
                return
            }
        }
    }

    /// Incoming links share one notification queue: when it has room again, serve them in turn,
    /// the least recently served first.
    private func pumpServerLinks() {
        var waiting = byKey.values.filter { !$0.isClient && $0.up && $0.hasPendingData }.sorted { $0.lastSent < $1.lastSent }
        while !waiting.isEmpty {
            var again: [Link] = []
            for link in waiting {
                switch sendNext(link) {
                case .blocked: return
                case .sent: if link.hasPendingData { again.append(link) }
                case .idle: break
                }
            }
            waiting = again
        }
    }

    private func sendNext(_ link: Link) -> SendResult {
        guard link.up, isCurrent(link) else { return .idle }
        while link.nextFragment >= link.fragments.count {
            let frame: Data
            if !link.live.isEmpty {
                frame = link.live.removeFirst()
            } else if !link.bulk.isEmpty {
                frame = link.bulk.removeFirst()
            } else {
                link.fragments = []
                link.nextFragment = 0
                return .idle
            }
            link.fragments = link.fragmenter.split(frame, maxFragment: fragmentLimit(link))
            link.nextFragment = 0
            if link.fragments.isEmpty { log("\(link.name): a \(frame.count)-byte frame doesn't fit in 255 fragments; dropped") }
        }
        guard transmit(link, link.fragments[link.nextFragment]) else { return .blocked }
        link.nextFragment += 1
        link.lastSent = now()
        link.writeRetries = 0
        return .sent
    }

    /// Client links write RX without response; incoming links notify TX. False: no room right now.
    private func transmit(_ link: Link, _ fragment: Data) -> Bool {
        if link.isClient {
            guard let p = link.peripheral, p.state == .connected, let rx = link.rx, p.canSendWriteWithoutResponse
            else { return false }
            p.writeValue(fragment, for: rx, type: .withoutResponse)
            return true
        }
        guard let c = link.central else { return false }
        return notify(fragment, to: c)
    }

    private func notify(_ fragment: Data, to central: CBCentral) -> Bool {
        guard let pm = peripheralManager, pm.state == .poweredOn, let tx = txCharacteristic else { return false }
        return pm.updateValue(fragment, for: tx, onSubscribedCentrals: [central])
    }

    /// The largest single write/notification: MTU − 3, at most 512 (Android's attribute limit).
    private func fragmentLimit(_ link: Link) -> Int {
        let n = link.isClient
            ? link.peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? K.minFragment
            : link.central?.maximumUpdateValueLength ?? K.minFragment
        return max(K.minFragment, min(n, K.maxAttributeValue))
    }

    /// Client links: poll again shortly (peripheralIsReady also resumes them). A link that takes no
    /// data for 100 tries (4 s) is closed, like Android.
    private func retryLater(_ link: Link) {
        guard !link.retryScheduled else { return }
        link.writeRetries += 1
        if link.writeRetries > K.maxWriteRetries {
            closeLink(link, failed: true, why: "stopped accepting data")
            return
        }
        link.retryScheduled = true
        after(K.retryDelay) { s in
            link.retryScheduled = false
            s.pump(link)
        }
    }

    /// A bye as one fragment, for sending straight to CoreBluetooth outside a link's queue.
    private func byeFragment(_ fragmenter: MeshFragmenter, for central: CBCentral) -> Data? {
        let limit = max(K.minFragment, min(central.maximumUpdateValueLength, K.maxAttributeValue))
        return fragmenter.split(MeshLinkFrame.bye(token: token).encoded(), maxFragment: limit).first
    }

    private func flushStopByes() {
        while let bye = stopByes.first, notify(bye.fragment, to: bye.central) {
            stopByes.removeFirst()
        }
    }

    /// A phone that writes to us without a link (its bye got lost, or it was refused and forgotten)
    /// would keep a dead link open until its silence timeout: tell it again, at most every 10 s.
    private func byeToStray(_ central: CBCentral) {
        let t = now()
        if let last = strayByes[central.identifier], t - last < K.strayByeEvery { return }
        strayByes[central.identifier] = t
        guard let f = byeFragment(MeshFragmenter(), for: central), notify(f, to: central) else { return }
        log("a phone with no link to us is still writing; sent bye")
    }

    // MARK: - Link lifecycle

    private func newLink(key: String, peer: UUID, isClient: Bool, peripheral: CBPeripheral?, central: CBCentral?,
                         target: String) -> Link {
        nextLinkId += 1
        let link = Link(id: nextLinkId, key: key, peer: peer, isClient: isClient, peripheral: peripheral,
                        central: central, target: target, now: now())
        byKey[key] = link
        return link
    }

    private func isCurrent(_ link: Link) -> Bool { byKey[link.key] === link }

    private func markUp(_ link: Link) {
        guard !link.up else { return }
        link.up = true
        link.lastReceived = now()
        backoff[link.peer] = nil
        log("\(link.name)\(link.isClient ? " → " + link.target : ""): up, \(fragmentLimit(link))-byte fragments")
        enqueue(link, MeshLinkFrame.hello(token: token).encoded(), bulk: false)
        link.reported = true
        delegate?.linkLayer(linkUp: link.id)
    }

    /// linkDown exactly once per linkUp.
    private func reportDown(_ link: Link) {
        guard link.reported else { return }
        link.reported = false
        delegate?.linkLayer(linkDown: link.id)
    }

    private func closeLink(_ link: Link, failed: Bool, why: String) {
        if link.isClient {
            dropClientLink(link, failed: failed, why: why)
            return
        }
        guard isCurrent(link), !link.closing else { return }
        // A peripheral can't disconnect a central, so ask it to go: stop routing over the link, send
        // a bye (the other phone closes its end and backs off), and forget the link shortly after.
        link.closing = true
        link.closingSince = now()
        reportDown(link)
        link.live.removeAll()
        link.bulk.removeAll()
        log("\(link.name) closed: \(why); sending bye")
        if link.up {
            link.live.append(MeshLinkFrame.bye(token: token).encoded())
            pump(link)
        }
        after(K.byeGrace) { s in s.forgetIfByeSent(link) }
    }

    /// A peripheral can't disconnect a central; the bye is how a closing incoming link ends. Forget
    /// the link once the bye went to CoreBluetooth, at the latest after byeMaxWait. Housekeeping
    /// checks again after the first try (Android forgets it after 2 s).
    private func forgetIfByeSent(_ link: Link) {
        guard isCurrent(link), link.closing else { return }
        if !link.hasPendingData || now() - link.closingSince >= K.byeMaxWait { byKey[link.key] = nil }
    }

    private func dropClientLink(_ link: Link, failed: Bool, why: String) {
        guard isCurrent(link) else { return }
        byKey[link.key] = nil
        if let cm = centralManager, cm.state == .poweredOn, let p = link.peripheral,
           p.state == .connecting || p.state == .connected {
            cancelling[link.peer] = now()
            cm.cancelPeripheralConnection(p)
        }
        reportDown(link)
        if failed {
            log("\(link.name) closed: \(why); next try in \(Int(fail(link.peer))) s")
        } else {
            backoff[link.peer] = nil
            log("\(link.name) closed: \(why)")
        }
    }

    private func dropServerLink(_ link: Link, why: String) {
        guard isCurrent(link) else { return }
        byKey[link.key] = nil
        if link.reported { log("\(link.name) closed: \(why)") }
        reportDown(link)
    }

    /// Returns the wait before the next connection attempt to this phone.
    private func fail(_ peer: UUID) -> TimeInterval {
        let failures = (backoff[peer]?.fails ?? 0) + 1
        let wait = Self.backoffDelay(failures: failures)
        backoff[peer] = (failures, now() + wait)
        return wait
    }

    // MARK: - Receiving

    private func receive(_ link: Link, _ fragment: Data) {
        guard !link.closing else { return }
        if !link.up {
            // A notification can overtake the subscription callback. It proves notifications are on.
            guard link.isClient, link.rx != nil else { return }
            markUp(link)
            guard isCurrent(link), !link.closing else { return }
        }
        let t = now()
        link.lastReceived = t
        link.silenceGraceGiven = false
        guard let frame = link.reassembler.accept(fragment, now: t) else { return }
        if frame.count == MeshLinkFrame.size, frame.first == 0x4C {
            switch MeshLinkFrame.decode(frame) {
            case let .hello(peerToken)?:
                onHello(link, peerToken)
            case .bye?:
                // Only the phone that opened a link acts on a bye: it closes it and stays away a minute.
                if link.isClient {
                    dropClientLink(link, failed: false, why: "the other phone asked (bye); next try in 60 s")
                    backoff[link.peer] = (0, now() + K.rotatedOutBackoff)
                }
            case nil:
                break
            }
            return
        }
        delegate?.linkLayer(received: frame, from: link.id)
    }

    /// Two links to the same phone happen because phones connect from a different address than they
    /// advertise, and because Android always connects to iPhones. Both phones keep the one opened by
    /// the phone with the lower token and close the other.
    private func onHello(_ link: Link, _ peerToken: UInt32) {
        let previous = link.peerToken
        link.peerToken = peerToken
        link.peerTokens.insert(peerToken)
        if link.isClient, let c = candidates[link.peer], c.token == nil { c.learnedToken = peerToken }
        if previous == nil {
            log("\(link.name): hello from \(Self.shortHex(peerToken))")
        } else if previous != peerToken {
            log("\(link.name): the other phone's token is now \(Self.shortHex(peerToken))")
        }
        guard let twin = byKey.values
            .filter({ $0 !== link && !$0.closing && $0.peerTokens.contains(peerToken) })
            .min(by: { $0.id < $1.id })
        else { return }
        let closeNew = Self.closesNewLink(linkIsClient: link.isClient, linkCreatedAt: link.createdAt,
                                          twinIsClient: twin.isClient, twinCreatedAt: twin.createdAt,
                                          ourToken: token, peerToken: peerToken)
        let drop = closeNew ? link : twin
        let keep = closeNew ? twin : link
        log("duplicate links to \(Self.shortHex(peerToken)): keeping \(keep.name), closing \(drop.name)")
        closeLink(drop, failed: false, why: "duplicate of \(keep.name)")
    }

    // MARK: - Connecting (client side)

    private func clientLinkCount() -> Int { byKey.values.filter { $0.isClient }.count }

    /// Phones connect from a different address than they advertise, so match on the token too.
    private func isLinked(_ peer: UUID, _ peerToken: UInt32?) -> Bool {
        let id = peer.uuidString
        if byKey["c:" + id] != nil || byKey["s:" + id] != nil { return true }
        guard let peerToken else { return false }
        return byKey.values.contains { $0.peerTokens.contains(peerToken) }
    }

    private func maybeConnect(_ id: UUID) {
        guard running, let c = candidates[id] else { return }
        let t = now()
        guard let cm = centralManager, cm.state == .poweredOn,
              !isLinked(id, c.linkToken),
              t - c.lastSeen <= K.candidateFresh,
              (backoff[id]?.until ?? 0) <= t,
              cancelling[id].map({ t - $0 >= K.cancelSettle }) ?? true,
              clientLinkCount() < K.maxClientLinks
        else {
            c.connectAt = nil
            return
        }
        if let peerToken = c.token {
            // Android: the lower token connects; the other side takes over if no link has formed after a
            // while. In the background Android can't see our advert (Apple's overflow area) and never
            // connects to us, so don't wait for it.
            let ours = token < peerToken
            guard ours || appInBackground || t - c.firstSeen >= K.symmetryOverride else { return }
            connect(c, why: ours ? "our token is lower"
                : appInBackground ? "it can't see us while we're in the background" : "no link from it after 20 s")
        } else {
            // No token in the advert (an iPhone). Android always connects to such phones; between two
            // iPhones a random delay makes it less likely both connect at once. Hello removes duplicates.
            guard let at = c.connectAt else {
                let delay = Double.random(in: 0...K.tokenlessJitter)
                c.connectAt = t + delay
                after(delay) { s in s.maybeConnect(id) }
                return
            }
            guard t >= at else { return }
            c.connectAt = nil
            connect(c, why: "no token in its advert")
        }
    }

    private func connect(_ c: Candidate, why: String) {
        guard let cm = centralManager else { return }
        let p = c.peripheral
        let link = newLink(key: "c:" + p.identifier.uuidString, peer: p.identifier, isClient: true,
                           peripheral: p, central: nil, target: c.label)
        p.delegate = self
        log("\(link.name) → \(c.label): connecting (\(why))")
        cm.connect(p, options: nil)
        after(K.connectTimeout) { s in
            guard s.isCurrent(link), !link.up else { return }
            s.dropClientLink(link, failed: true, why: "connection timed out")
        }
    }

    private func clientLink(_ p: CBPeripheral) -> Link? {
        guard let link = byKey["c:" + p.identifier.uuidString], link.peripheral === p else { return nil }
        return link
    }

    // MARK: - Scanning, GATT server, advertising

    private func startScan() {
        lastScanStart = now()
        guard let cm = centralManager, cm.state == .poweredOn else { return }
        // The service filter is required in the background (where duplicates are ignored anyway).
        cm.scanForPeripherals(withServices: [Self.serviceUUID],
                              options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        if !scanning { log("scanning") }
        scanning = true
    }

    private func restartScan() {
        guard let cm = centralManager, cm.state == .poweredOn else { return }
        cm.stopScan()
        startScan()
    }

    private func openServer() {
        lastServerAttempt = now()
        serviceReady = false
        guard let pm = peripheralManager, pm.state == .poweredOn else { return }
        let rx = CBMutableCharacteristic(type: Self.rxUUID, properties: [.write, .writeWithoutResponse],
                                         value: nil, permissions: [.writeable])
        // CoreBluetooth adds the CCCD for notify characteristics.
        let tx = CBMutableCharacteristic(type: Self.txUUID, properties: [.notify], value: nil, permissions: [.readable])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [rx, tx]
        txCharacteristic = tx
        pm.add(service)
        // Advertising starts once the service is registered (didAdd).
    }

    private func closeServer() {
        if let pm = peripheralManager, pm.state == .poweredOn { pm.removeAllServices() }
        txCharacteristic = nil
        serviceReady = false
    }

    private func startAdvertising() {
        lastAdvertiseAttempt = now()
        guard let pm = peripheralManager, pm.state == .poweredOn, serviceReady else { return }
        if pm.isAdvertising { pm.stopAdvertising() }
        advertising = false
        // The service UUID only: iOS can't advertise manufacturer data (Android's token), and no name.
        // In the background iOS moves the UUID to its overflow area, which only iPhones scanning for it see.
        pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
    }

    private func stopAdvertising() {
        advertising = false
        if let pm = peripheralManager, pm.state == .poweredOn, pm.isAdvertising { pm.stopAdvertising() }
    }

    // MARK: - Bluetooth state

    private func updateState() {
        guard running else { return }
        let s = combinedState()
        guard s != reportedState else { return }
        reportedState = s
        log("Bluetooth: \(Self.describe(s))")
        delegate?.linkLayer(stateChanged: s)
    }

    private func combinedState() -> MeshBleState {
        let c = centralManager?.state ?? .unknown
        let p = peripheralManager?.state ?? .unknown
        if c == .unauthorized || p == .unauthorized { return .unauthorized }
        if c == .unsupported { return .unsupported }
        if c == .poweredOff || p == .poweredOff { return .poweredOff }
        // A phone that can't advertise can still connect to others.
        if c == .poweredOn && (p == .poweredOn || p == .unsupported) { return .ready }
        return .starting
    }

    private func centralStateChanged() {
        guard running, let cm = centralManager else { return }
        if cm.state == .poweredOn {
            if !scanning { startScan() }
            return
        }
        // Below poweredOn every CBPeripheral from this manager is invalid and every connection gone.
        scanning = false
        for link in byKey.values.filter({ $0.isClient }).sorted(by: { $0.id < $1.id }) {
            dropClientLink(link, failed: false, why: "Bluetooth \(Self.describe(cm.state))")
        }
        candidates.removeAll()
        backoff.removeAll()
        cancelling.removeAll()
    }

    private func peripheralStateChanged() {
        guard running, let pm = peripheralManager else { return }
        switch pm.state {
        case .poweredOn:
            if !serviceReady { openServer() } else if !advertising { startAdvertising() }
        case .unsupported:
            if !loggedNoAdvertising { log("this phone can't advertise over BLE; it can still connect to others") }
            loggedNoAdvertising = true
        default:
            // Below poweredOn advertising has stopped, the GATT database is cleared and every central is gone.
            serviceReady = false
            advertising = false
            txCharacteristic = nil
            for link in byKey.values.filter({ !$0.isClient }).sorted(by: { $0.id < $1.id }) {
                dropServerLink(link, why: "Bluetooth \(Self.describe(pm.state))")
            }
        }
    }

    // MARK: - Housekeeping

    private func scheduleHousekeeping(_ gen: Int) {
        after(K.housekeeping) { s in
            guard s.running, s.generation == gen else { return }
            s.tidy(s.now())
            s.scheduleHousekeeping(gen)
        }
    }

    private func tidy(_ t: TimeInterval) {
        let gap = t - lastTidy
        lastTidy = t
        // In the background iOS suspends the app between Bluetooth events and no timer runs. A suspended
        // iPhone neighbour sends no keepalives either: give each link one keepalive round (sent below) to
        // be heard from again. Once per silence, so a dead link still closes in the background.
        let resumed = gap > K.resumeGap
        if resumed {
            suspensionsSinceStatus += 1
            longestSuspension = max(longestSuspension, gap)
            if gap >= K.logSuspensionOver { log("app was suspended for \(Int(gap)) s") }
            for link in byKey.values where !link.silenceGraceGiven {
                link.silenceGraceGiven = true
                link.lastReceived = max(link.lastReceived, t - K.linkSilent + K.resumeGrace)
            }
        }
        for link in byKey.values.sorted(by: { $0.id < $1.id }) {
            guard isCurrent(link) else { continue }
            link.reassembler.expire(t)
            // In case a "ready" callback never came.
            if link.up, link.hasPendingData, !link.retryScheduled { pump(link) }
            guard isCurrent(link) else { continue }
            if link.closing {
                forgetIfByeSent(link)
                continue
            }
            if !link.up {
                // Also enforced here: the connect timer doesn't run while the app is suspended.
                if link.isClient, t - link.createdAt > K.connectTimeout {
                    dropClientLink(link, failed: true, why: "connection timed out")
                }
                continue
            }
            if !resumed, link.peerToken == nil, t - link.createdAt > K.helloDeadline {
                // Half-open links (refused, or the other app died) would otherwise swallow messages.
                closeLink(link, failed: true, why: "no hello within \(Int(K.helloDeadline)) s")
            } else if t - link.lastReceived > K.linkSilent {
                closeLink(link, failed: true, why: "silent for \(Int(t - link.lastReceived)) s")
            } else if t - link.lastSent > K.keepalive, link.live.isEmpty, link.bulk.isEmpty {
                enqueue(link, MeshLinkFrame.hello(token: token).encoded(), bulk: false)
            }
        }
        candidates = candidates.filter { t - $0.value.lastSeen <= K.candidateTTL }
        cancelling = cancelling.filter { t - $0.value < K.cancelSettle }
        strayByes = strayByes.filter { t - $0.value < K.candidateTTL }
        if backoff.count > 1000 { backoff = backoff.filter { $0.value.until > t } }
        if t - lastRotation > K.rotateEvery {
            lastRotation = t
            rotateLinks(t)
        }
        for id in Array(candidates.keys) { maybeConnect(id) }
        if let cm = centralManager, cm.state == .poweredOn {
            if !scanning { startScan() } else if t - lastScanStart > K.scanRefresh { restartScan() }
        }
        if let pm = peripheralManager, pm.state == .poweredOn {
            if !serviceReady, t - lastServerAttempt > K.serverRetry {
                closeServer()
                openServer()
            } else if serviceReady, !advertising, t - lastAdvertiseAttempt > K.advertiseRetry {
                startAdvertising()
            }
        }
        if t - lastStatus >= K.statusEvery {
            lastStatus = t
            logStatus(t)
        }
    }

    /// In a moving crowd, drop the oldest outgoing link now and then when other phones are waiting,
    /// so the mesh keeps re-forming around people as they move.
    private func rotateLinks(_ t: TimeInterval) {
        let clients = byKey.values.filter { $0.isClient && $0.up }
        guard clients.count >= K.maxClientLinks else { return }
        // A tokenless phone (iPhone) may already be linked to us through a link it opened, from an ID
        // that differs from its advert's. Count one as waiting only if every incoming link is
        // accounted for by some advert (or a token learned from it).
        let known = Set(candidates.values.compactMap { $0.linkToken })
        let unaccountedIncoming = byKey.values.contains { link in
            !link.isClient && link.reported && !(link.peerToken.map { known.contains($0) } ?? false)
        }
        let waiting = candidates.contains { id, c in
            (c.linkToken != nil || !unaccountedIncoming) && !isLinked(id, c.linkToken)
                && t - c.lastSeen < K.candidateFresh && (backoff[id]?.until ?? 0) <= t
        }
        guard waiting, let oldest = clients.min(by: { $0.createdAt < $1.createdAt }),
              t - oldest.createdAt >= K.minAgeToRotate
        else { return }
        dropClientLink(oldest, failed: false, why: "rotated out to reach new neighbours; next try in 60 s")
        backoff[oldest.peer] = (0, t + K.rotatedOutBackoff)
    }

    private func logStatus(_ t: TimeInterval) {
        let all = Array(byKey.values)
        let out = all.filter { $0.isClient && $0.reported }.count
        let inn = all.filter { !$0.isClient && $0.reported }.count
        let connecting = all.filter { $0.isClient && !$0.up }.count
        let nearby = candidates.values.filter { t - $0.lastSeen <= K.candidateFresh }.count
        let suspended = suspensionsSinceStatus == 0 ? ""
            : "; suspended \(suspensionsSinceStatus)x, longest \(Int(longestSuspension)) s"
        log("status: \(out) out, \(inn) in, \(connecting) connecting, \(nearby) nearby (\(foundSinceStatus) new); "
            + (advertising ? "advertising" : "not advertising") + ", " + (scanning ? "scanning" : "not scanning")
            + (appInBackground ? ", background" : "") + suspended)
        foundSinceStatus = 0
        suspensionsSinceStatus = 0
        longestSuspension = 0
    }

    // MARK: - Utilities

    /// Seconds on a clock that keeps counting while the phone sleeps (like Android's elapsedRealtime).
    private func now() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }

    /// Runs `work` on the queue after `delay`. Monotonic, so a clock change can't stall it; it pauses
    /// while the phone sleeps, which catchUp() covers for housekeeping. Never keeps this object alive.
    private func after(_ delay: TimeInterval, _ work: @escaping (MeshBleLinkLayer) -> Void) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            work(self)
        }
    }

    /// In the background iOS suspends the app between Bluetooth events and the phone sleeps, so the
    /// housekeeping timer can be far behind: the first Bluetooth event after a long gap runs it.
    private func catchUp() {
        guard running else { return }
        let t = now()
        if t - lastTidy > 2 * K.housekeeping { tidy(t) }
    }

    /// Follows the app between foreground and background (UIKit posts on the main thread).
    private func observeAppState() {
        #if canImport(UIKit)
        guard appStateObservers.isEmpty else { return }
        let q = queue
        let center = NotificationCenter.default
        appStateObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                q.async { self.setAppInBackground(true) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                q.async { self.setAppInBackground(false) }
            },
        ]
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let background = UIApplication.shared.applicationState == .background
            q.async { self.setAppInBackground(background) }
        }
        #endif
    }

    private func setAppInBackground(_ background: Bool) {
        guard background != appInBackground else { return }
        appInBackground = background
        guard running else { return }
        log(background ? "app in background: most phones can't see this iPhone now; connecting out without waiting"
                       : "app in foreground")
        if background { for id in Array(candidates.keys) { maybeConnect(id) } }
    }

    private func log(_ line: String) { delegate?.linkLayer(log: line) }

    private func assertOnQueue() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
        #endif
    }

    private static func describe(_ s: MeshBleState) -> String {
        switch s {
        case .starting: return "starting"
        case .ready: return "ready"
        case .poweredOff: return "off"
        case .unauthorized: return "not allowed (Settings → ChatFort → Bluetooth)"
        case .unsupported: return "Bluetooth LE unsupported"
        }
    }

    private static func describe(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "on"
        case .poweredOff: return "off"
        case .resetting: return "resetting"
        case .unauthorized: return "not allowed"
        case .unsupported: return "unsupported"
        case .unknown: return "unknown"
        @unknown default: return "state \(s.rawValue)"
        }
    }

    private static func describe(_ error: Error?) -> String {
        guard let e = error as NSError? else { return "no error" }
        let domain = e.domain == CBErrorDomain ? "CB" : e.domain == CBATTErrorDomain ? "ATT" : e.domain
        return "\(domain) \(e.code): \(e.localizedDescription)"
    }
}

// MARK: - Central role (links we open)

extension MeshBleLinkLayer: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateState()
        centralStateChanged()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard running else { return }
        catchUp()
        let peerToken = Self.advertisedToken(advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
        if peerToken == token { return }
        let id = peripheral.identifier
        let t = now()
        if let c = candidates[id] {
            c.lastSeen = t
            if let peerToken { c.token = peerToken }
        } else {
            let c = Candidate(peripheral: peripheral, token: peerToken, now: t)
            candidates[id] = c
            foundSinceStatus += 1
            if foundSinceStatus <= K.foundLogsPerStatus { log("found \(c.label)") }
        }
        maybeConnect(id)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        catchUp()
        guard clientLink(peripheral) != nil else {
            // Dropped while connecting.
            cancelling[peripheral.identifier] = now()
            central.cancelPeripheralConnection(peripheral)
            return
        }
        // iOS negotiates the MTU by itself. Discover → RX, TX → subscribe TX → link up.
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let since = cancelling.removeValue(forKey: peripheral.identifier), now() - since < K.cancelSettle { return }
        guard let link = clientLink(peripheral) else { return }
        dropClientLink(link, failed: true, why: "could not connect (\(Self.describe(error)))")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        catchUp()
        // The end of a connection we cancelled ourselves, not of a newer one.
        if let since = cancelling.removeValue(forKey: peripheral.identifier), now() - since < K.cancelSettle { return }
        guard let link = clientLink(peripheral) else { return }
        // A link that never came up, or one that was cut, backs off before the next try.
        dropClientLink(link, failed: true, why: (link.up ? "disconnected" : "connection failed") + " (\(Self.describe(error)))")
    }
}

extension MeshBleLinkLayer: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let link = clientLink(peripheral) else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            dropClientLink(link, failed: true, why: "no mesh service (\(Self.describe(error)))")
            return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard service.uuid == Self.serviceUUID, let link = clientLink(peripheral) else { return }
        let characteristics = service.characteristics ?? []
        guard error == nil,
              let rx = characteristics.first(where: { $0.uuid == Self.rxUUID }),
              rx.properties.contains(.writeWithoutResponse),
              let tx = characteristics.first(where: { $0.uuid == Self.txUUID }),
              tx.properties.contains(.notify)
        else {
            dropClientLink(link, failed: true, why: "mesh service incomplete (\(Self.describe(error)))")
            return
        }
        link.rx = rx
        // CoreBluetooth writes the CCCD (01 00).
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID, let link = clientLink(peripheral) else { return }
        if error == nil, characteristic.isNotifying {
            markUp(link)
            return
        }
        // An error here means the other phone refused the link (Android answers 0x11 when it's full).
        let full = (error as? CBATTError)?.code == .insufficientResources
        dropClientLink(link, failed: true, why: full ? "the other phone is full (it refused the subscription)"
                                                      : "subscription failed (\(Self.describe(error)))")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        catchUp()
        guard error == nil, characteristic.uuid == Self.txUUID, let value = characteristic.value,
              let link = clientLink(peripheral)
        else { return }
        receive(link, value)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let link = clientLink(peripheral) else { return }
        pump(link)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }), let link = clientLink(peripheral)
        else { return }
        dropClientLink(link, failed: true, why: "the other phone removed its mesh service")
    }
}

// MARK: - Peripheral role (links we accept)

extension MeshBleLinkLayer: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        updateState()
        peripheralStateChanged()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard running, service.uuid == Self.serviceUUID else { return }
        if let error {
            log("GATT service could not be added (\(Self.describe(error))); retrying in \(Int(K.serverRetry)) s")
            return
        }
        serviceReady = true
        log("GATT service ready")
        startAdvertising()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard running else { return }
        if let error {
            advertising = false
            log("advertising failed (\(Self.describe(error))); retrying in \(Int(K.advertiseRetry)) s")
        } else {
            advertising = true
            log("advertising (service UUID only)")
        }
    }

    /// A phone subscribed to TX: the link is up (Android's CCCD write).
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard running, characteristic.uuid == Self.txUUID else { return }
        catchUp()
        let key = "s:" + central.identifier.uuidString
        // A new subscription means the phone's old one ended, even if we haven't heard yet (or its
        // link is closing with a bye still queued, which must not reach the new link): replace it.
        if let old = byKey[key] { dropServerLink(old, why: "the other phone subscribed again") }
        let full = byKey.values.filter { !$0.isClient && !$0.refused }.count >= K.maxServerLinks
        let link = newLink(key: key, peer: central.identifier, isClient: false, peripheral: nil, central: central, target: "")
        if full {
            // Android refuses the CCCD write with an error; iOS can't refuse a subscription. Accept it,
            // send a bye (the other phone closes its end and backs off) and forget the link.
            link.refused = true
            link.closing = true
            link.closingSince = now()
            link.up = true
            log("\(link.name) refused: \(K.maxServerLinks) incoming links already; sending bye")
            link.live.append(MeshLinkFrame.bye(token: token).encoded())
            pump(link)
            after(K.byeGrace) { s in s.forgetIfByeSent(link) }
            return
        }
        markUp(link)
    }

    /// Also called when the central disconnects: a peripheral gets no other disconnection callback.
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.txUUID, let link = byKey["s:" + central.identifier.uuidString] else { return }
        dropServerLink(link, why: "the other phone unsubscribed or disconnected")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        peripheral.respond(to: request, withResult: .readNotPermitted)
    }

    /// Writes to RX. One batch can hold several writes, or the parts of one long (prepared) write at
    /// increasing offsets; each whole value is one fragment. CBATTRequest doesn't tell a write request
    /// from a write command, so answer once, to the first request (Apple's rule for a batch): a write
    /// request left unanswered would stall the other phone's ATT channel until it times out.
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard requests.allSatisfy({ $0.characteristic.uuid == Self.rxUUID }) else {
            peripheral.respond(to: first, withResult: .writeNotPermitted)
            return
        }
        let parts = requests.map { WritePart(central: $0.central.identifier, offset: $0.offset, value: $0.value ?? Data()) }
        let assembled = Self.assembleWrites(parts)
        peripheral.respond(to: first, withResult: assembled.error ?? .success)
        catchUp()
        if let error = assembled.error {
            log("rejected a write on RX (ATT \(error.rawValue))")
            return
        }
        for value in assembled.values {
            if let link = byKey["s:" + value.central.uuidString] {
                receive(link, value.data)
            } else if let central = requests.first(where: { $0.central.identifier == value.central })?.central {
                byeToStray(central)
            }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        if running { pumpServerLinks() } else { flushStopByes() }
    }
}
