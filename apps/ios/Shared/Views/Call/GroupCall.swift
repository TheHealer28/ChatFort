//
//  GroupCall.swift
//  Inqalaab (iOS)
//
//  Small group calls (up to 5 participants) over a full WebRTC mesh,
//  SCOPED TO A SIMPLEX GROUP (see tasks/group-call.md).
//
//  Why group-scoped (vs loose contacts): a symmetric mesh needs every pair of
//  participants to (a) identify each other and (b) be reachable by the call API.
//  SimpleX deliberately makes direct contacts non-correlatable across people, so
//  loose-contact meshes can't choreograph. A SimpleX *group* solves both:
//    - `GroupMember.memberId` (ChatTypes.swift:2510) is a STABLE, group-wide
//      identity every member's app agrees on → the roster key and the
//      deterministic offer-ordering operand (glare avoidance).
//    - `GroupMember.memberContactId` (ChatTypes.swift:2519), when set, gives the
//      contactId the existing 1:1 call API needs. A participant is callable only
//      when it is a mutual member-contact; pairs without one are surfaced as
//      "not reachable" rather than silently creating persistent contacts.
//
//  Backend: NO change, NO Nix rebuild. The engine stores calls per-contact
//  (`currentCalls :: TMap ContactId Call`, Controller.hs:239), so N independent
//  legs already coexist. Signaling reuses the existing per-contact APIs verbatim.
//
//  THIS FILE IS PHASE 1a/1b SCAFFOLD: the additive state model + group-scoped
//  roster construction only. It does NOT touch the live 1:1 path
//  (ChatModel.activeCall, ActiveCallView, CallController, CallManager) and is not
//  wired into any running UI. WebRTCClient/signaling wiring lands in Phase 1c
//  behind a feature gate.
//

import Foundation
import SwiftUI
import AVFoundation
import InqalaabChat

/// Hard cap on mesh participants, including the local user.
/// Above ~5 a full mesh (N-1 uplinks per device) collapses on weak networks.
let GROUP_CALL_MAX_PARTICIPANTS = 5

/// Lifecycle of a single pairwise leg within a group call. Mirrors the 1:1
/// `CallState` machine but tracked per-participant so the coordinator can show
/// "3 of 4 connected" and drive per-leg retries independently.
enum GroupCallLegState: Equatable {
    case invited        // in the roster, no media negotiation started yet
    case connecting     // offer/answer/ICE in flight for this leg
    case connected      // media flowing with this participant
    case reconnecting   // was connected, leg dropped, attempting to re-establish
    case failed         // this leg could not be established
    case left           // this participant left (or we removed them)
    case unreachable    // no member-contact to this participant — cannot mesh

    var text: LocalizedStringKey {
        switch self {
        case .invited: return "invited…"
        case .connecting: return "connecting…"
        case .connected: return "connected"
        case .reconnecting: return "reconnecting…"
        case .failed: return "failed"
        case .left: return "left"
        case .unreachable: return "not connected"
        }
    }

    var isLive: Bool { self == .connected || self == .reconnecting }
}

/// One remote participant in a group call, keyed by the stable group `memberId`.
class GroupCallParticipant: ObservableObject, Identifiable {
    /// Stable, group-wide-consistent identity. Every member's app agrees on this
    /// value for the same person → roster key + deterministic offer ordering.
    let memberId: String
    /// Local DB id of this member within the group (member-scoped APIs).
    let groupMemberId: Int64
    var id: String { memberId }

    /// Direct-contact view of this member, when a member-contact exists. The
    /// existing 1:1 call API requires a Contact, so a participant is callable
    /// only when this is non-nil. nil → mutually-unconnected in the group.
    let contact: Contact?
    let displayName: String

    /// The underlying 1:1 call leg to this participant. Assigned when the leg's
    /// WebRTC session is created in Phase 1c; nil while only invited.
    @Published var leg: Call?
    @Published var state: GroupCallLegState
    @Published var connectionInfo: ConnectionInfo?
    @Published var peerMediaSources: CallMediaSources = CallMediaSources()

    init(
        memberId: String,
        groupMemberId: Int64,
        contact: Contact?,
        displayName: String,
        state: GroupCallLegState? = nil
    ) {
        self.memberId = memberId
        self.groupMemberId = groupMemberId
        self.contact = contact
        self.displayName = displayName
        // Unreachable members can't mesh; everyone else starts as invited.
        self.state = state ?? (contact == nil ? .unreachable : .invited)
    }

    /// Reachable for a mesh leg: must be a mutual member-contact.
    var isCallable: Bool { contact != nil }
    var hasVideo: Bool { peerMediaSources.hasVideo }
}

/// Coordinates a small group call as a mesh of per-member legs. This is the
/// aggregate a future `ChatModel.activeGroupCall` will hold, parallel to (and
/// never replacing) the 1:1 `activeCall`.
class GroupCall: ObservableObject {
    /// Stable id for this group-call session, surfaced to CallKit as a single
    /// synthetic call handle (one CXCall for the whole group — Phase 1d).
    let groupCallUUID: String
    let groupId: Int64
    /// Display name of the group, for the call screen / CallKit.
    let groupName: String
    /// This device's own memberId in the group.
    let localMemberId: String
    /// The host's memberId (the call initiator). Topology is a STAR: every
    /// participant has exactly one leg, to the host; the host forwards audio so
    /// everyone hears everyone. For the host, hostMemberId == localMemberId.
    let hostMemberId: String
    let localInitiated: Bool
    let initialMedia: CallMediaType

    @Published var participants: [GroupCallParticipant]
    @Published var localMediaSources: CallMediaSources
    @Published var speakerEnabled = false
    @Published var startedAt: Date? = nil

    init(
        groupCallUUID: String,
        groupId: Int64,
        groupName: String,
        localMemberId: String,
        hostMemberId: String,
        localInitiated: Bool,
        initialMedia: CallMediaType,
        participants: [GroupCallParticipant] = []
    ) {
        self.groupCallUUID = groupCallUUID
        self.groupId = groupId
        self.groupName = groupName
        self.localMemberId = localMemberId
        self.hostMemberId = hostMemberId
        self.localInitiated = localInitiated
        self.initialMedia = initialMedia
        self.participants = participants
        self.localMediaSources = CallMediaSources(
            mic: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            camera: initialMedia == .video && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        )
    }

    // MARK: - Roster

    /// Total people on the call including the local user.
    var totalCount: Int { participants.count + 1 }

    var canAddParticipant: Bool { totalCount < GROUP_CALL_MAX_PARTICIPANTS }

    /// Participants we can actually mesh with (have a member-contact).
    var callableParticipants: [GroupCallParticipant] { participants.filter { $0.isCallable } }

    /// Roster entries that can't be reached (no member-contact) — surfaced in UI.
    var unreachableParticipants: [GroupCallParticipant] { participants.filter { !$0.isCallable } }

    /// Participants currently exchanging media (connected or reconnecting).
    var liveParticipants: [GroupCallParticipant] { participants.filter { $0.state.isLive } }

    var connectedCount: Int { participants.filter { $0.state == .connected }.count }

    /// True once at least one leg is connected — used to start the call timer.
    var anyConnected: Bool { connectedCount > 0 }

    /// Participants in a stable display order for the grid (by name, then memberId).
    var orderedParticipants: [GroupCallParticipant] {
        participants.sorted {
            let l = $0.displayName.lowercased(), r = $1.displayName.lowercased()
            return l == r ? $0.memberId < $1.memberId : l < r
        }
    }

    func participant(memberId: String) -> GroupCallParticipant? {
        participants.first { $0.memberId == memberId }
    }

    /// Add a participant if under the cap and not already present.
    @discardableResult
    func addParticipant(_ p: GroupCallParticipant) -> Bool {
        guard participant(memberId: p.memberId) == nil, canAddParticipant else { return false }
        participants.append(p)
        return true
    }

    /// Deterministic glare rule: for any pair, the lower memberId sends the
    /// offer. Every device agrees on memberIds, so exactly one side initiates.
    func localInitiatesOffer(to participant: GroupCallParticipant) -> Bool {
        localMemberId < participant.memberId
    }

    func updateLegState(memberId: String, _ state: GroupCallLegState) {
        guard let p = participant(memberId: memberId) else { return }
        p.state = state
        if state == .connected && startedAt == nil {
            startedAt = Date()
        }
    }

    /// Mark a participant as gone. Leaves the entry in `.left` so the UI can
    /// briefly show it before the coordinator prunes it (Phase 1b/1d).
    func markLeft(memberId: String) {
        participant(memberId: memberId)?.state = .left
    }

    func removeParticipant(memberId: String) {
        participants.removeAll { $0.memberId == memberId }
    }

    /// True when every reachable participant's leg has settled (connected, or
    /// failed/left) — i.e. no callable leg is still negotiating.
    var allLegsSettled: Bool {
        callableParticipants.allSatisfy { p in
            switch p.state {
            case .connected, .failed, .left: return true
            case .invited, .connecting, .reconnecting, .unreachable: return false
            }
        }
    }
}

extension GroupCall {
    /// Build a group call from resolved (member, contact?) pairs. Contact
    /// resolution (memberContactId → Contact) is done by the caller (e.g. via
    /// `ChatModel.getContactChat`) to keep this model free of global coupling
    /// and unit-testable. Members without a member-contact are included as
    /// `.unreachable` so the UI can explain why they aren't on the call.
    static func make(
        groupCallUUID: String,
        groupId: Int64,
        groupName: String,
        localMemberId: String,
        hostMemberId: String,
        localInitiated: Bool,
        media: CallMediaType,
        members: [(member: GroupMember, contact: Contact?)]
    ) -> GroupCall {
        let capped = members.prefix(GROUP_CALL_MAX_PARTICIPANTS - 1)
        let parts = capped.map { entry in
            GroupCallParticipant(
                memberId: entry.member.memberId,
                groupMemberId: entry.member.groupMemberId,
                contact: entry.contact,
                displayName: entry.member.displayName
            )
        }
        return GroupCall(
            groupCallUUID: groupCallUUID,
            groupId: groupId,
            groupName: groupName,
            localMemberId: localMemberId,
            hostMemberId: hostMemberId,
            localInitiated: localInitiated,
            initialMedia: media,
            participants: Array(parts)
        )
    }
}

// MARK: - Coordination signal (Phase 1b)
//
// Per-leg WebRTC reuses the existing 1:1 call API. What members still need is a
// lightweight coordination signal — "a call is starting on this group / I'm
// joining / I'm leaving" — carrying the call instance id and roster of member
// ids so every device can independently establish its legs (ordered by the
// `localInitiatesOffer` rule).
//
// Transport (verified, NO backend change): a normal `.text` group message
// carrying a namespaced sentinel marker. One `apiSendMessages(type: .group …)`
// fans out to every member via the existing group-send path. On receive it is
// intercepted at the `m.addChatItem` chokepoint (SimpleXAPI.swift:2381) — if
// `GroupCallControl.parse` returns non-nil the item is routed to the coordinator
// and NOT shown as a bubble or notified. Riding `.text` (not `.unknown`, which
// the Swift encoder silently downgrades) guarantees lossless round-trip.
//
// The marker is a leading zero-width space + tag so that, in the unlikely event
// the item is ever shown raw (e.g. a non-ChatFort client in the group), it reads
// as innocuous rather than as garbage.

// NOTE: GroupCallControlKind + GroupCallControl moved to the InqalaabChat
// framework (CallTypes.swift) so the NSE can also parse control messages —
// it must suppress them / surface an incoming-call notification, and persist
// a cold-start handoff record when the app is killed.

enum GroupCallSignaling {
    /// Broadcast a control signal to every member of the group in a single send.
    /// Returns true if the backend accepted the message. Additive: this is the
    /// only wire side-effect of the group-call layer so far; it does not touch
    /// the 1:1 call path.
    @discardableResult
    static func broadcast(_ control: GroupCallControl) async -> Bool {
        let sent = await apiSendMessages(
            type: .group,
            id: control.groupId,
            scope: nil,
            composedMessages: [ComposedMessage(msgContent: .text(control.encodedText()))]
        )
        // Purge our own copy of the control message — it must never appear as a
        // bubble when this chat's history loads (it already fanned out on send).
        if let items = sent, !items.isEmpty {
            let ids = items.map { $0.id }
            do { _ = try await apiDeleteChatItems(type: .group, id: control.groupId, scope: nil, itemIds: ids, mode: .cidmInternal) }
            catch { logger.error("group-call control snd item delete error: \(responseError(error))") }
        }
        return sent != nil
    }
}
