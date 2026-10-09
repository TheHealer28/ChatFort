import Foundation
import MultipeerConnectivity

/// Delegate protocol for NearbyService to communicate events to NearbyModel
protocol NearbyServiceDelegate: AnyObject {
    func nearbyService(_ service: NearbyService, didDiscover peer: MCPeerID, withInfo info: [String: String]?)
    func nearbyService(_ service: NearbyService, didLose peer: MCPeerID)
    func nearbyService(_ service: NearbyService, peer: MCPeerID, didChangeState state: MCSessionState)
    func nearbyService(_ service: NearbyService, didReceive message: NearbyMessage, from peer: MCPeerID)
    /// Advertising or browsing failed to start. The most common cause is the
    /// Local Network permission being denied — surfaced so the UI can stop
    /// spinning forever and tell the user what to fix.
    func nearbyService(_ service: NearbyService, didFailToStart what: String, error: Error)
}

/// Wraps MultipeerConnectivity for peer-to-peer messaging without internet.
/// Both advertises and browses simultaneously. Auto-connects with tie-breaking.
///
/// Consent model: the *connection* is automatic (peers link up on discovery).
/// The consent gate lives one layer up, in NearbyModel: a peer's FIRST inbound
/// message becomes a "message request" that the user must accept before any
/// conversation opens. So linking is frictionless, but nobody can actually
/// message you without your approval.
class NearbyService: NSObject {
    static let shared = NearbyService()

    private let serviceType = "inqalaab-p2p" // 14 chars, lowercase + hyphen, valid for MPC

    private var myPeerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private(set) var isRunning = false
    weak var delegate: NearbyServiceDelegate?

    private override init() {
        super.init()
    }

    // MARK: - Start / Stop

    /// Start advertising and browsing for nearby peers.
    /// - Parameter displayName: The name to advertise (should include random suffix via NearbyDisplayName.create)
    func start(displayName: String) {
        guard !isRunning else { return }

        let peerID = MCPeerID(displayName: displayName)
        myPeerID = peerID

        let mcSession = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required // All sessions encrypted
        )
        mcSession.delegate = self
        session = mcSession

        // Advertise ourselves
        let mcAdvertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["app": "inqalaab", "v": "1"],
            serviceType: serviceType
        )
        mcAdvertiser.delegate = self
        mcAdvertiser.startAdvertisingPeer()
        advertiser = mcAdvertiser

        // Browse for others
        let mcBrowser = MCNearbyServiceBrowser(
            peer: peerID,
            serviceType: serviceType
        )
        mcBrowser.delegate = self
        mcBrowser.startBrowsingForPeers()
        browser = mcBrowser

        isRunning = true
        logger.debug("NearbyService: started advertising + browsing")
    }

    /// Stop all MultipeerConnectivity activity.
    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()

        advertiser = nil
        browser = nil
        session = nil
        myPeerID = nil
        isRunning = false
        logger.debug("NearbyService: stopped")
    }

    // MARK: - Send Message

    /// Send a message to a specific peer.
    func send(_ message: NearbyMessage, to peerID: MCPeerID) throws {
        guard let session = session else {
            throw NearbyError.notConnected
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)
        try session.send(data, toPeers: [peerID], with: .reliable)
    }

    /// Send a message to all connected peers.
    func broadcast(_ message: NearbyMessage) throws {
        guard let session = session, !session.connectedPeers.isEmpty else {
            throw NearbyError.notConnected
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)
        try session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    // MARK: - Connected Peers

    var connectedPeers: [MCPeerID] {
        session?.connectedPeers ?? []
    }

    func peerID(forDisplayName name: String) -> MCPeerID? {
        session?.connectedPeers.first { $0.displayName == name }
    }

    // MARK: - Tie-breaking

    /// Determines if we should invite a discovered peer (to avoid duplicate invitations).
    /// Rule: the peer with the lexicographically smaller displayName sends the invitation.
    private func shouldInvite(_ discoveredPeer: MCPeerID) -> Bool {
        guard let myName = myPeerID?.displayName else { return false }
        return myName < discoveredPeer.displayName
    }
}

// MARK: - MCSessionDelegate

extension NearbyService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        // Note: peer display names are intentionally NOT logged (they carry the
        // user's profile name — a metadata leak in the unified log / sysdiagnose).
        logger.debug("NearbyService: a peer changed session state (\(state.rawValue))")
        delegate?.nearbyService(self, peer: peerID, didChangeState: state)
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var message = try decoder.decode(NearbyMessage.self, from: data)
            message.isOutgoing = false // We received it
            delegate?.nearbyService(self, didReceive: message, from: peerID)
        } catch {
            logger.error("NearbyService: failed to decode a received message: \(error.localizedDescription)")
        }
    }

    // Unused stream/resource methods — required by protocol
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceBrowserDelegate

extension NearbyService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        logger.debug("NearbyService: discovered a peer")
        delegate?.nearbyService(self, didDiscover: peerID, withInfo: info)

        // Auto-connect using tie-breaking rule. The conversation-level consent
        // gate (first-message acceptance) lives in NearbyModel, not here.
        if shouldInvite(peerID), let session = session {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        logger.debug("NearbyService: lost a peer")
        delegate?.nearbyService(self, didLose: peerID)
    }

    /// Fires when browsing can't start — most often Local Network permission denied.
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        logger.error("NearbyService: browsing failed to start: \(error.localizedDescription)")
        delegate?.nearbyService(self, didFailToStart: NSLocalizedString("browsing", comment: "nearby failure"), error: error)
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension NearbyService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Accept the link automatically — consent is enforced at the message layer
        // (NearbyModel holds a peer's first message as a request until approved).
        logger.debug("NearbyService: accepted a peer link (message consent gated in model)")
        invitationHandler(true, session)
    }

    /// Fires when advertising can't start — most often Local Network permission denied.
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        logger.error("NearbyService: advertising failed to start: \(error.localizedDescription)")
        delegate?.nearbyService(self, didFailToStart: NSLocalizedString("advertising", comment: "nearby failure"), error: error)
    }
}

// MARK: - Errors

enum NearbyError: LocalizedError {
    case notConnected
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to any peers"
        case .encodingFailed: return "Failed to encode message"
        }
    }
}
