//
//  GroupCallCoordinator.swift
//  Inqalaab (iOS)
//
//  Orchestrates a group-scoped mesh call (see tasks/group-call.md).
//
//  INCREMENT 3: consent + call experience.
//  - Incoming group calls RING and require Accept (CallKit when available —
//    one CXCall for the whole group — otherwise an in-app ring screen with
//    ringtone). No more auto-join.
//  - Leg invitations that arrive while ringing are HELD (never ring as 1:1)
//    and absorbed on accept / rejected on decline — this also closes the
//    control-vs-invitation ordering race from increment 2.
//  - Mute + speaker controls, collapsible full call screen (GroupCallView).
//  - Stale `.start` controls (delivered late, e.g. after offline) are ignored.
//
//  Audio: WebRTC auto-mixes remote audio tracks. With CallKit, the session is
//  CallKit-managed (legs keep useManualAudio=true from init; didActivate
//  enables audio). Without CallKit the coordinator drives the session manually
//  and restores defaults after the last leg closes. Legs never deactivate the
//  shared session (WebRTCClient.groupLegMode).
//
//  Hard safety rule: everything is gated behind `isEnabled` (default OFF) and
//  inbound 1:1 events are only claimed when a group call is pending/active —
//  the live 1:1 call path is otherwise untouched.
//

import Foundation
import SwiftUI
import AVFoundation
import CallKit
import WebRTC
import InqalaabChat

/// Thread-safe registry of CallKit UUIDs that belong to group calls, so
/// CXProvider delegate methods (nonisolated) can route actions without
/// hopping to the main actor first.
enum GroupCallKitRegistry {
    private static let lock = NSLock()
    private static var uuids = Set<UUID>()

    static func register(_ u: UUID) { lock.lock(); uuids.insert(u); lock.unlock() }
    static func unregister(_ u: UUID) { lock.lock(); uuids.remove(u); lock.unlock() }
    static func contains(_ u: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return uuids.contains(u) }
}

/// An incoming group call waiting for the user's Accept/Decline.
struct PendingGroupCall {
    let control: GroupCallControl
    let groupInfo: GroupInfo
    let groupName: String
    let callerName: String
    let callKitUUID: UUID?
    var heldInvitations: [Int64: RcvCallInvitation] = [:]
}

@MainActor
final class GroupCallCoordinator: ObservableObject {
    static let shared = GroupCallCoordinator()

    /// Group calls are generally available (production since v1.6.0). The flag
    /// structure is kept as an emergency kill-switch seam: set this to read the
    /// UserDefaults key again to gate the feature off in a hotfix.
    static let featureKey = "inqalaab_group_calls_enabled"
    static var isEnabled: Bool { true }

    /// Group calls deliberately do NOT use CallKit. CallKit-as-one-call broke
    /// the shared audio-session handoff (connected but silent, then stuck
    /// connecting) — the manual coordinator-owned session from increment 2 gave
    /// confirmed two-way audio. Group calls use the in-app ring + manual audio;
    /// 1:1 calls keep CallKit untouched. Re-enabling this needs on-device proof
    /// that audio survives the CallKit activate/deactivate handoff for N legs.
    static var usesCallKit: Bool { false }

    /// Ignore `.start` controls older than this (delivered late after offline).
    static let startControlMaxAge: TimeInterval = 120
    /// Auto-decline an unanswered incoming call after this long.
    static let ringTimeout: TimeInterval = 60

    /// The group call currently in progress, if any.
    @Published var activeGroupCall: GroupCall?
    /// An incoming group call ringing, awaiting Accept/Decline.
    @Published var pendingIncomingCall: PendingGroupCall?
    /// Full call screen collapsed to the compact panel.
    @Published var callViewCollapsed = false
    @Published var micEnabled = true
    @Published var speakerEnabled = false

    /// Live WebRTC legs keyed by the leg contact's apiId.
    private var legs: [Int64: GroupCallLeg] = [:]
    /// Invitations that arrived before the cold-start ring was set up
    /// (NSE handoff path) — moved into the pending call once it rings.
    private var earlyHeldInvitations: [Int64: RcvCallInvitation] = [:]
    /// True between consuming the cold-start handoff record and the ring being
    /// set up (member loading is async) — invitations arriving in that window
    /// are buffered, not treated as 1:1 calls.
    private var coldStartRingInFlight = false
    /// The call's group roster, fetched directly via apiListMembers. NEVER use
    /// ChatModel.groupMembers here: ChatModel.loadGroupMembers only populates
    /// it when that group's chat is OPEN on screen (ChatModel.swift `chatId ==
    /// groupInfo.id` guard) — on cold start that silently yielded an empty
    /// roster ("1 of 1 on the call", no legs, stuck connecting).
    private var currentMembers: [GroupMember] = []
    /// CallKit UUID of the active group call (one CXCall for the whole group).
    private var groupCallKitUUID: UUID?
    private var reportedConnectedToCallKit = false
    private var ringTimeoutTask: Task<Void, Never>? = nil

    private init() {}

    // MARK: - Host: start a group call

    /// Fetch the group roster (directly — not via ChatModel, see currentMembers
    /// note), then build the call, broadcast the start signal, and establish legs.
    func startGroupCall(groupInfo: GroupInfo, media: CallMediaType) {
        guard Self.isEnabled, activeGroupCall == nil, pendingIncomingCall == nil else { return }
        Task {
            let members = await apiListMembers(groupInfo.groupId)
            await MainActor.run {
                self.currentMembers = members
                self.startGroupCallWithRoster(groupInfo: groupInfo, media: media)
            }
        }
    }

    private func startGroupCallWithRoster(groupInfo: GroupInfo, media: CallMediaType) {
        guard activeGroupCall == nil, pendingIncomingCall == nil else { return }
        let localMemberId = groupInfo.membership.memberId
        let instanceId = "\(groupInfo.groupId)-\(localMemberId)-\(Int(Date().timeIntervalSince1970))"
        let resolved = resolveCurrentMembers(excluding: localMemberId)

        let call = GroupCall.make(
            groupCallUUID: instanceId,
            groupId: groupInfo.groupId,
            groupName: groupInfo.displayName,
            localMemberId: localMemberId,
            hostMemberId: localMemberId,
            localInitiated: true,
            media: media,
            members: resolved
        )
        resetCallUIState()
        activeGroupCall = call

        // One CXCall for the whole group (system treats user as on a call).
        if Self.usesCallKit {
            let uuid = UUID()
            groupCallKitUUID = uuid
            GroupCallKitRegistry.register(uuid)
            CallController.shared.startGroupCallKit(uuid: uuid, groupId: groupInfo.groupId, groupName: groupInfo.displayName)
        } else {
            // Manual session like increment 2 (confirmed two-way audio).
            configureAudioSessionForGroupCall()
        }

        let control = GroupCallControl(
            kind: .start,
            instanceId: instanceId,
            groupId: groupInfo.groupId,
            fromMemberId: localMemberId,
            media: media,
            participantMemberIds: resolved.map { $0.member.memberId }
        )
        logger.debug("GroupCallCoordinator: starting group call (\(resolved.count) participants, \(resolved.filter { $0.contact != nil }.count) callable)")
        Task {
            await GroupCallSignaling.broadcast(control)
            // Give the control message a head start over the per-leg invitations
            // (they travel over different connections). Held-invitation handling
            // on the callee side covers the remaining race.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { self.establishLegs() }
        }
    }

    // MARK: - Inbound control

    /// Handle a hidden group-call control message received over the group.
    /// `ts` is the message timestamp (stale starts are ignored).
    func handleControl(_ control: GroupCallControl, groupInfo: GroupInfo?, at ts: Date = Date()) {
        guard Self.isEnabled, let groupInfo else { return }
        let localMemberId = groupInfo.membership.memberId
        // Ignore our own broadcasts echoed back.
        guard control.fromMemberId != localMemberId else { return }

        switch control.kind {
        case .start:
            guard ts.timeIntervalSinceNow > -Self.startControlMaxAge else {
                logger.debug("GroupCallCoordinator: ignoring stale group-call start")
                return
            }
            guard activeGroupCall == nil, pendingIncomingCall == nil else { return }
            Task {
                // Fetch the roster directly (see currentMembers note).
                let members = await apiListMembers(groupInfo.groupId)
                await MainActor.run {
                    self.currentMembers = members
                    self.ringIncomingCall(control, groupInfo: groupInfo)
                }
            }

        case .join:
            guard let call = activeGroupCall, call.groupCallUUID == control.instanceId else { return }
            if call.participant(memberId: control.fromMemberId) == nil,
               let gm = member(forMemberId: control.fromMemberId) {
                let joiner = GroupCallParticipant(
                    memberId: gm.memberId,
                    groupMemberId: gm.groupMemberId,
                    contact: contact(for: gm),
                    displayName: gm.displayName
                )
                // On a participant (non-host), other members have no direct leg —
                // if my host leg is already up, the joiner is reachable via the
                // host, so show them connected.
                if !call.localInitiated,
                   legs[call.participant(memberId: call.hostMemberId)?.contact?.apiId ?? -1]?.client != nil {
                    joiner.state = .connected
                }
                call.addParticipant(joiner)
            }
            // Host: dial the new participant. (No-op for participants.)
            establishLegs()

        case .leave:
            // Caller hung up while we were still ringing → missed call.
            if let pending = pendingIncomingCall,
               pending.control.instanceId == control.instanceId,
               pending.control.fromMemberId == control.fromMemberId {
                cancelPendingCall(remoteEnded: true)
                return
            }
            guard let call = activeGroupCall, call.groupCallUUID == control.instanceId else { return }
            call.markLeft(memberId: control.fromMemberId)
            if let p = call.participant(memberId: control.fromMemberId),
               let apiId = p.contact?.apiId,
               let leg = legs.removeValue(forKey: apiId) {
                leg.shutdown(notifyPeer: false)
            }
            scheduleAudioForwardingUpdate()
            finishCallIfNoLegs()
        }
    }

    // MARK: - Cold start (app was killed; NSE persisted the start control)

    /// Ring a group call whose `.start` arrived while the app was killed — the
    /// NSE persisted it to group defaults. Called on app activation and lazily
    /// from claimInvitation. Safe to call repeatedly.
    func checkPersistedGroupCallStart() {
        guard Self.isEnabled, activeGroupCall == nil, pendingIncomingCall == nil, !coldStartRingInFlight else { return }
        guard let (control, _) = takePendingGroupCallStart(maxAge: Self.startControlMaxAge) else {
            rejectEarlyInvitations()
            return
        }
        guard let chat = ChatModel.shared.getGroupChat(control.groupId),
              case let .group(groupInfo, _) = chat.chatInfo else {
            rejectEarlyInvitations()
            return
        }
        logger.debug("GroupCallCoordinator: ringing persisted (cold-start) group call")
        coldStartRingInFlight = true
        Task {
            // Fetch the roster directly (see currentMembers note).
            let members = await apiListMembers(groupInfo.groupId)
            await MainActor.run {
                self.currentMembers = members
                self.coldStartRingInFlight = false
                self.ringIncomingCall(control, groupInfo: groupInfo)
                if self.pendingIncomingCall == nil && self.activeGroupCall == nil {
                    // Ring couldn't be set up — don't leave buffered invitations dangling.
                    self.rejectEarlyInvitations()
                }
            }
        }
    }

    // MARK: - Ring / Accept / Decline (consent)

    private func ringIncomingCall(_ control: GroupCallControl, groupInfo: GroupInfo) {
        guard activeGroupCall == nil, pendingIncomingCall == nil else { return }
        let callerName = member(forMemberId: control.fromMemberId)?.displayName
            ?? NSLocalizedString("Group member", comment: "group call caller fallback")
        var callKitUUID: UUID? = nil
        if Self.usesCallKit {
            let uuid = UUID()
            callKitUUID = uuid
            GroupCallKitRegistry.register(uuid)
            CallController.shared.reportNewIncomingGroupCall(
                uuid: uuid,
                groupName: groupInfo.displayName,
                callerName: callerName
            ) { error in
                if let error {
                    logger.error("GroupCallCoordinator: CallKit incoming report failed: \(error.localizedDescription)")
                }
            }
        }
        var pending = PendingGroupCall(
            control: control,
            groupInfo: groupInfo,
            groupName: groupInfo.displayName,
            callerName: callerName,
            callKitUUID: callKitUUID
        )
        // Absorb leg invitations that arrived before this ring was set up
        // (cold-start handoff path).
        if !earlyHeldInvitations.isEmpty {
            for (apiId, inv) in earlyHeldInvitations where isMember(of: pending, contactApiId: apiId) {
                pending.heldInvitations[apiId] = inv
            }
            earlyHeldInvitations.removeAll()
        }
        pendingIncomingCall = pending
        logger.debug("GroupCallCoordinator: ringing incoming group call")
        // Auto-decline if unanswered.
        ringTimeoutTask?.cancel()
        ringTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.ringTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.missPendingCall() }
        }
    }

    /// User accepted (in-app button or CallKit answer action).
    func acceptPendingCall() {
        guard let pending = pendingIncomingCall else { return }
        ringTimeoutTask?.cancel()
        pendingIncomingCall = nil
        resetCallUIState()
        groupCallKitUUID = pending.callKitUUID
        joinCall(pending.control, groupInfo: pending.groupInfo)
        // Absorb leg invitations that arrived while ringing.
        for (apiId, inv) in pending.heldInvitations {
            if let leg = legs[apiId], leg.client == nil {
                leg.startIncoming(inv)
                activeGroupCall?.updateLegState(memberId: leg.memberId, .connecting)
            }
        }
        logger.debug("GroupCallCoordinator: accepted incoming group call")
    }

    /// User declined (in-app button or CallKit end action while ringing).
    func declinePendingCall(fromCallKit: Bool = false) {
        guard let pending = pendingIncomingCall else { return }
        ringTimeoutTask?.cancel()
        pendingIncomingCall = nil
        rejectHeldInvitations(pending)
        if let uuid = pending.callKitUUID {
            GroupCallKitRegistry.unregister(uuid)
            if !fromCallKit {
                CallController.shared.reportGroupCallEnded(uuid: uuid, reason: .declinedElsewhere)
            }
        }
        // Tell the group we're not joining (callers see us as "left").
        let control = GroupCallControl(
            kind: .leave,
            instanceId: pending.control.instanceId,
            groupId: pending.control.groupId,
            fromMemberId: pending.groupInfo.membership.memberId
        )
        Task { await GroupCallSignaling.broadcast(control) }
        logger.debug("GroupCallCoordinator: declined incoming group call")
    }

    /// Ring timed out unanswered.
    private func missPendingCall() {
        guard let pending = pendingIncomingCall else { return }
        pendingIncomingCall = nil
        rejectHeldInvitations(pending)
        if let uuid = pending.callKitUUID {
            GroupCallKitRegistry.unregister(uuid)
            CallController.shared.reportGroupCallEnded(uuid: uuid, reason: .unanswered)
        }
        logger.debug("GroupCallCoordinator: incoming group call missed (timeout)")
    }

    /// Caller hung up while we were ringing.
    private func cancelPendingCall(remoteEnded: Bool) {
        guard let pending = pendingIncomingCall else { return }
        ringTimeoutTask?.cancel()
        pendingIncomingCall = nil
        rejectHeldInvitations(pending)
        if let uuid = pending.callKitUUID {
            GroupCallKitRegistry.unregister(uuid)
            CallController.shared.reportGroupCallEnded(uuid: uuid, reason: remoteEnded ? .remoteEnded : .failed)
        }
        logger.debug("GroupCallCoordinator: incoming group call cancelled by caller")
    }

    private func rejectEarlyInvitations() {
        let held = earlyHeldInvitations
        earlyHeldInvitations.removeAll()
        guard !held.isEmpty else { return }
        Task {
            for inv in held.values {
                do { try await apiRejectCall(inv.contact) }
                catch { logger.error("GroupCallCoordinator: apiRejectCall error: \(responseError(error))") }
            }
        }
    }

    private func rejectHeldInvitations(_ pending: PendingGroupCall) {
        let held = pending.heldInvitations
        guard !held.isEmpty else { return }
        Task {
            for inv in held.values {
                do { try await apiRejectCall(inv.contact) }
                catch { logger.error("GroupCallCoordinator: apiRejectCall error: \(responseError(error))") }
            }
        }
    }

    /// Build the call state for an accepted `.start` and join it.
    private func joinCall(_ control: GroupCallControl, groupInfo: GroupInfo) {
        guard activeGroupCall == nil else { return }
        let localMemberId = groupInfo.membership.memberId
        var ids = control.participantMemberIds ?? []
        ids.append(control.fromMemberId) // the host is a participant too
        let uniqueIds = Array(Set(ids.filter { $0 != localMemberId }))
        let resolved = uniqueIds.compactMap { id -> (member: GroupMember, contact: Contact?)? in
            guard let gm = member(forMemberId: id) else { return nil }
            return (gm, contact(for: gm))
        }
        let call = GroupCall.make(
            groupCallUUID: control.instanceId,
            groupId: control.groupId,
            groupName: groupInfo.displayName,
            localMemberId: localMemberId,
            hostMemberId: control.fromMemberId,
            localInitiated: false,
            media: control.media ?? .audio,
            members: resolved
        )
        activeGroupCall = call
        logger.debug("GroupCallCoordinator: joined group call (\(resolved.count) participants)")
        // Tell others we're in (lets late legs establish).
        let join = GroupCallControl(
            kind: .join,
            instanceId: control.instanceId,
            groupId: control.groupId,
            fromMemberId: localMemberId
        )
        Task { await GroupCallSignaling.broadcast(join) }
        establishLegs()
    }

    // MARK: - Leg establishment (STAR topology)

    /// ONLY THE HOST dials, and it dials EVERY callable participant. Participants
    /// never establish legs to each other — they accept the host's invitation
    /// (claimInvitation) and nothing else. This is the whole point of the star:
    /// running a participant↔participant mesh AND host forwarding at once made
    /// remote audio arrive twice (robotic), and the two mechanisms raced on
    /// connect. With the star, each participant has exactly one leg (to the
    /// host) and the host forwards everyone to everyone.
    private func establishLegs() {
        guard let call = activeGroupCall, call.localInitiated else { return }
        for p in call.callableParticipants {
            guard let contact = p.contact, legs[contact.apiId] == nil else { continue }
            let leg = GroupCallLeg(
                contact: contact,
                memberId: p.memberId,
                media: call.initialMedia,
                outgoing: true,
                coordinator: self
            )
            legs[contact.apiId] = leg
            leg.startOutgoing()
            call.updateLegState(memberId: p.memberId, .connecting)
        }
    }

    // MARK: - Inbound 1:1 call events (claim hooks, called from SimpleXAPI)
    // Each returns true when the event belongs to a group-call leg (the normal
    // 1:1 handling must then be skipped). All are no-ops unless a group call
    // is pending/active, so the 1:1 path is untouched in normal operation.

    func claimInvitation(_ invitation: RcvCallInvitation) -> Bool {
        guard Self.isEnabled else { return false }
        let apiId = invitation.contact.apiId
        // Cold-start handoff: a fresh group-call start was persisted by the NSE
        // but the ring isn't set up yet. Buffer this invitation (it's most
        // likely a leg of that call) and kick off the ring — it is absorbed
        // when the ring appears, or rejected if the record turns out stale.
        if activeGroupCall == nil, pendingIncomingCall == nil,
           coldStartRingInFlight || hasFreshPendingGroupCallStart(maxAge: Self.startControlMaxAge) {
            earlyHeldInvitations[apiId] = invitation
            checkPersistedGroupCallStart()
            return true
        }
        // While ringing: hold leg invitations from expected members so they
        // never ring as 1:1 calls; absorbed on accept, rejected on decline.
        if var pending = pendingIncomingCall {
            if isMember(of: pending, contactApiId: apiId) {
                pending.heldInvitations[apiId] = invitation
                pendingIncomingCall = pending
                logger.debug("GroupCallCoordinator: held a leg invitation while ringing")
                return true
            }
            return false
        }
        guard let call = activeGroupCall else { return false }
        guard let p = call.participants.first(where: { $0.contact?.apiId == apiId }) else { return false }
        let leg: GroupCallLeg
        if let existing = legs[apiId] {
            guard existing.client == nil else { return true } // duplicate invitation; claim + ignore
            leg = existing
        } else {
            leg = GroupCallLeg(contact: invitation.contact, memberId: p.memberId, media: call.initialMedia, outgoing: false, coordinator: self)
            legs[apiId] = leg
        }
        leg.startIncoming(invitation)
        call.updateLegState(memberId: p.memberId, .connecting)
        return true
    }

    private func isMember(of pending: PendingGroupCall, contactApiId: Int64) -> Bool {
        var ids = pending.control.participantMemberIds ?? []
        ids.append(pending.control.fromMemberId)
        return ids.contains { id in
            member(forMemberId: id)?.memberContactId == contactApiId
        }
    }

    func claimOffer(_ contact: Contact, offer: WebRTCSession, sharedKey: String?) -> Bool {
        guard Self.isEnabled, activeGroupCall != nil, let leg = legs[contact.apiId] else { return false }
        leg.handleRemoteOffer(offer, sharedKey: sharedKey)
        return true
    }

    func claimAnswer(_ contact: Contact, answer: WebRTCSession) -> Bool {
        guard Self.isEnabled, activeGroupCall != nil, let leg = legs[contact.apiId] else { return false }
        leg.handleRemoteAnswer(answer)
        return true
    }

    func claimExtraInfo(_ contact: Contact, extraInfo: WebRTCExtraInfo) -> Bool {
        guard Self.isEnabled, activeGroupCall != nil, let leg = legs[contact.apiId] else { return false }
        leg.handleRemoteIce(extraInfo)
        return true
    }

    func claimCallEnded(_ contact: Contact) -> Bool {
        guard Self.isEnabled, activeGroupCall != nil, let leg = legs[contact.apiId] else { return false }
        legs.removeValue(forKey: contact.apiId)
        leg.shutdown(notifyPeer: false)
        activeGroupCall?.markLeft(memberId: leg.memberId)
        scheduleAudioForwardingUpdate()
        finishCallIfNoLegs()
        return true
    }

    // MARK: - Host audio forwarding (everyone hears everyone)

    /// The HOST receives each participant's audio on its own leg, and forwards
    /// every participant's live track into every other leg's pre-negotiated
    /// forward slots (see WebRTCClient.setForwardedAudioTracks). Mix-minus is
    /// inherent: a participant's own track is never forwarded back to them.
    /// Participants need nothing — incoming audio tracks auto-play and mix at
    /// playout. Recomputed whenever a leg connects or goes away.
    private func updateAudioForwarding() {
        guard let call = activeGroupCall, call.localInitiated else { return }
        let live = legs.values.filter { $0.client?.remoteAudioTrackForForwarding != nil }
        for leg in legs.values {
            guard let client = leg.client else { continue }
            let others = live
                .filter { $0 !== leg }
                .compactMap { $0.client?.remoteAudioTrackForForwarding }
            client.setForwardedAudioTracks(Array(others.prefix(GROUP_CALL_MAX_PARTICIPANTS - 2)))
        }
    }

    /// Remote tracks can land moments after ICE reports connected — re-run the
    /// forwarding table shortly after every change so late tracks get picked up.
    private func scheduleAudioForwardingUpdate() {
        updateAudioForwarding()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.updateAudioForwarding() }
        }
    }

    // MARK: - Leg lifecycle feedback

    func legConnected(_ leg: GroupCallLeg, info: ConnectionInfo?) {
        guard let call = activeGroupCall else { return }
        call.updateLegState(memberId: leg.memberId, .connected)
        if let p = call.participant(memberId: leg.memberId) {
            p.connectionInfo = info ?? p.connectionInfo
        }
        // Apply current mute state to legs that connect later.
        if !micEnabled {
            leg.client?.setAudioEnabled(false)
        }
        // Report the group call connected to CallKit once (outgoing side).
        if call.localInitiated, !reportedConnectedToCallKit, let uuid = groupCallKitUUID {
            reportedConnectedToCallKit = true
            CallController.shared.reportGroupCallConnected(uuid: uuid)
        }
        // Host: route this participant's audio to everyone else (and vice versa).
        scheduleAudioForwardingUpdate()
        // Participant: my one leg is to the host. Once it's up, the other members
        // are reachable through the host's forwarding — show them as connected
        // (they have no direct leg on my device in the star topology).
        if !call.localInitiated, leg.memberId == call.hostMemberId {
            for p in call.participants where p.memberId != call.hostMemberId {
                if p.state != .connected { call.updateLegState(memberId: p.memberId, .connected) }
            }
        }
    }

    func legClosed(_ leg: GroupCallLeg, failed: Bool) {
        guard activeGroupCall != nil else { return }
        if legs[leg.contact.apiId] === leg {
            legs.removeValue(forKey: leg.contact.apiId)
        }
        activeGroupCall?.updateLegState(memberId: leg.memberId, failed ? .failed : .left)
        // Host: stop forwarding the departed participant's audio.
        scheduleAudioForwardingUpdate()
        finishCallIfNoLegs()
    }

    private func finishCallIfNoLegs() {
        guard let call = activeGroupCall, legs.isEmpty else { return }
        let anyPending = call.callableParticipants.contains { p in
            p.state == .invited || p.state == .connecting || p.state == .connected
        }
        if !anyPending {
            logger.debug("GroupCallCoordinator: all legs closed, finishing call")
            cleanupAfterCall(callKitReason: .remoteEnded)
        }
    }

    // MARK: - In-call controls

    func setMicEnabled(_ enabled: Bool) {
        micEnabled = enabled
        for leg in legs.values {
            leg.client?.setAudioEnabled(enabled)
        }
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        speakerEnabled = enabled
        legs.values.compactMap { $0.client }.first?.setSpeakerEnabledAndConfigureSession(enabled)
    }

    // MARK: - End (local user hangs up)

    func endGroupCall(fromCallKit: Bool = false) {
        guard let call = activeGroupCall else { return }
        // Route through CallKit so the system call ends too; its end action
        // calls back here with fromCallKit=true to do the actual teardown.
        if !fromCallKit, let uuid = groupCallKitUUID {
            CallController.shared.requestEndGroupCallKit(uuid: uuid)
            return
        }
        let control = GroupCallControl(
            kind: .leave,
            instanceId: call.groupCallUUID,
            groupId: call.groupId,
            fromMemberId: call.localMemberId
        )
        Task { await GroupCallSignaling.broadcast(control) }
        for leg in legs.values {
            leg.shutdown(notifyPeer: true)
        }
        legs.removeAll()
        cleanupAfterCall(callKitReason: nil, reportToCallKit: false)
        logger.debug("GroupCallCoordinator: ended group call")
    }

    /// CallKit routed an end/decline action for one of our UUIDs.
    /// Returns true when handled.
    func handleCallKitEnd(uuid: UUID) -> Bool {
        if let pending = pendingIncomingCall, pending.callKitUUID == uuid {
            declinePendingCall(fromCallKit: true)
            return true
        }
        if groupCallKitUUID == uuid {
            endGroupCall(fromCallKit: true)
            return true
        }
        return false
    }

    private func cleanupAfterCall(callKitReason: CXCallEndedReason?, reportToCallKit: Bool = true) {
        if let uuid = groupCallKitUUID {
            GroupCallKitRegistry.unregister(uuid)
            if reportToCallKit, let reason = callKitReason {
                CallController.shared.reportGroupCallEnded(uuid: uuid, reason: reason)
            }
        }
        let wasCallKitManaged = groupCallKitUUID != nil && Self.usesCallKit
        groupCallKitUUID = nil
        reportedConnectedToCallKit = false
        activeGroupCall = nil
        currentMembers = []
        resetCallUIState()
        // We own the session (group calls don't use CallKit) — restore defaults.
        if !wasCallKitManaged {
            restoreAudioSession()
        }
    }

    private func resetCallUIState() {
        callViewCollapsed = false
        micEnabled = true
        speakerEnabled = false
    }

    // MARK: - Shared audio session (coordinator-owned, non-CallKit mode)

    /// Group calls don't use CallKit (see `usesCallKit`), so drive the shared
    /// session manually — exactly the increment-2 path that gave confirmed
    /// two-way audio. Idempotent; safe to call as legs come up.
    func configureAudioSessionForGroupCall() {
        guard !Self.usesCallKit else { return }
        let s = RTCAudioSession.sharedInstance()
        s.useManualAudio = false
        s.isAudioEnabled = true
    }

    /// Mirror of WebRTCClient.audioSessionToDefaults(), run exactly once after
    /// the last leg closes (legs themselves never touch the session).
    private func restoreAudioSession() {
        DispatchQueue.global(qos: .utility).async {
            let s = RTCAudioSession.sharedInstance()
            s.lockForConfiguration()
            defer { s.unlockForConfiguration() }
            do {
                try s.setCategory(AVAudioSession.Category.ambient.rawValue)
                try s.setMode(AVAudioSession.Mode.default.rawValue)
                try s.overrideOutputAudioPort(.none)
                try s.setActive(false)
                logger.debug("GroupCallCoordinator: audio session restored to defaults")
            } catch {
                logger.error("GroupCallCoordinator: restore audio session error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Member / contact resolution

    private func resolveCurrentMembers(excluding localMemberId: String) -> [(member: GroupMember, contact: Contact?)] {
        currentMembers
            .filter { $0.memberId != localMemberId && $0.memberCurrent }
            .map { (member: $0, contact: contact(for: $0)) }
    }

    private func member(forMemberId memberId: String) -> GroupMember? {
        currentMembers.first { $0.memberId == memberId }
            ?? ChatModel.shared.groupMembers.first { $0.wrapped.memberId == memberId }?.wrapped
    }

    private func contact(for member: GroupMember) -> Contact? {
        guard let cid = member.memberContactId,
              let chat = ChatModel.shared.getContactChat(cid),
              case let .direct(contact) = chat.chatInfo else { return nil }
        return contact
    }
}

// MARK: - GroupCallLeg

/// One WebRTC leg of a group call: its own WebRTCClient (groupLegMode) + its
/// own command processor, driven by the same loop as a 1:1 call but bound to
/// this leg's contact.
@MainActor
final class GroupCallLeg {
    let contact: Contact
    let memberId: String
    let media: CallMediaType
    /// True when the deterministic rule says WE send the invitation for this pair.
    let outgoing: Bool
    let processor = WebRTCCommandProcessor()
    private(set) var client: WebRTCClient?
    private(set) var sharedKey: String?
    private weak var coordinator: GroupCallCoordinator?
    private var shuttingDown = false
    private var isConnected = false
    /// Lost after connecting; shown as failed if the leg then closes.
    private var dropped = false
    private var connectTimeoutTask: Task<Void, Never>? = nil

    /// Withdraw an unanswered outgoing leg after this long, so a callee who
    /// opens the app much later doesn't find a dangling invitation that rings
    /// (and connects) as a 1:1 call.
    static let connectTimeout: TimeInterval = 90

    init(contact: Contact, memberId: String, media: CallMediaType, outgoing: Bool, coordinator: GroupCallCoordinator) {
        self.contact = contact
        self.memberId = memberId
        self.media = media
        self.outgoing = outgoing
        self.coordinator = coordinator
    }

    private func makeClient() {
        guard client == nil else { return }
        // groupLegMode at init: the client must never mutate the shared audio
        // session (flags or teardown) — see the no-audio bug this caused.
        let c = WebRTCClient({ [weak self] msg in
            await MainActor.run { self?.handleResponse(msg) }
        }, .constant(nil), groupLegMode: true)
        client = c
        coordinator?.configureAudioSessionForGroupCall()
        Task { await processor.setClient(c) }
    }

    /// We invite: capabilities → (response) apiSendCallInvitation(contact).
    func startOutgoing() {
        makeClient()
        Task { await processor.processCommand(.capabilities(media: media)) }
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.connectTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isConnected, !self.shuttingDown else { return }
                logger.debug("GroupCallLeg: outgoing leg timed out, withdrawing invitation")
                self.coordinator?.legClosed(self, failed: true)
                self.shutdown(notifyPeer: true) // apiEndCall withdraws the invitation
            }
        }
    }

    /// They invited: start WebRTC → (response) offer → apiSendCallOffer(contact).
    func startIncoming(_ invitation: RcvCallInvitation) {
        sharedKey = invitation.sharedKey
        makeClient()
        let useRelay = UserDefaults.standard.bool(forKey: DEFAULT_WEBRTC_POLICY_RELAY)
        let iceServers = getIceServers()
        Task {
            await processor.processCommand(.start(
                media: invitation.callType.media,
                aesKey: invitation.sharedKey,
                iceServers: iceServers,
                relay: useRelay
            ))
        }
    }

    /// Their WebRTC offer arrived (we are the inviter side of this leg).
    func handleRemoteOffer(_ offer: WebRTCSession, sharedKey: String?) {
        self.sharedKey = sharedKey
        let useRelay = UserDefaults.standard.bool(forKey: DEFAULT_WEBRTC_POLICY_RELAY)
        let iceServers = getIceServers()
        Task {
            await processor.processCommand(.offer(
                offer: offer.rtcSession,
                iceCandidates: offer.rtcIceCandidates,
                media: media,
                aesKey: sharedKey,
                iceServers: iceServers,
                relay: useRelay
            ))
        }
    }

    func handleRemoteAnswer(_ answer: WebRTCSession) {
        Task { await processor.processCommand(.answer(answer: answer.rtcSession, iceCandidates: answer.rtcIceCandidates)) }
    }

    func handleRemoteIce(_ extraInfo: WebRTCExtraInfo) {
        Task { await processor.processCommand(.ice(iceCandidates: extraInfo.rtcIceCandidates)) }
    }

    /// Close this leg. Never touches the shared audio session (groupLegMode).
    func shutdown(notifyPeer: Bool) {
        guard !shuttingDown else { return }
        shuttingDown = true
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        let contact = self.contact
        let client = self.client
        Task {
            await processor.processCommand(.end)
            await processor.setClient(nil)
            client?.endCall()
            if notifyPeer {
                do { try await apiEndCall(contact) }
                catch { logger.error("GroupCallLeg: apiEndCall error: \(responseError(error))") }
            }
        }
    }

    // MARK: per-leg response loop (mirrors ActiveCallView.processRtcMessage)

    private func handleResponse(_ msg: WVAPIMessage) {
        guard !shuttingDown else { return }
        switch msg.resp {
        case let .capabilities(capabilities):
            let callType = CallType(media: media, capabilities: capabilities)
            Task {
                do { try await apiSendCallInvitation(contact, callType) }
                catch { logger.error("GroupCallLeg: apiSendCallInvitation error: \(responseError(error))") }
            }
        case let .offer(offer, iceCandidates, capabilities):
            Task {
                do { try await apiSendCallOffer(contact, offer, iceCandidates, media: media, capabilities: capabilities) }
                catch { logger.error("GroupCallLeg: apiSendCallOffer error: \(responseError(error))") }
            }
        case let .answer(answer, iceCandidates):
            Task {
                do { try await apiSendCallAnswer(contact, answer, iceCandidates) }
                catch { logger.error("GroupCallLeg: apiSendCallAnswer error: \(responseError(error))") }
            }
        case let .ice(iceCandidates):
            Task {
                do { try await apiSendCallExtraInfo(contact, iceCandidates) }
                catch { logger.error("GroupCallLeg: apiSendCallExtraInfo error: \(responseError(error))") }
            }
        case let .connection(state):
            let status = state.connectionState
            if status == "connected" {
                isConnected = true
                dropped = false
                connectTimeoutTask?.cancel()
                coordinator?.legConnected(self, info: nil)
            } else if isConnected && (status == "disconnected" || status == "failed") {
                // A drop the leg may recover from: the client waits 30 s (restarting
                // ICE) and closes the leg if it doesn't recover.
                dropped = true
            } else if status == "failed" || status == "closed" {
                coordinator?.legClosed(self, failed: status == "failed" || dropped)
            }
            // Same call-history rule as 1:1 calls (see ActiveCallView).
            let reportedStatus: String? =
                status == "disconnected" || (status == "failed" && isConnected)
                ? nil
                : status == "closed" ? "disconnected" : status
            if let reportedStatus {
                Task { try? await apiCallStatus(contact, reportedStatus) }
            }
        case let .connected(connectionInfo):
            isConnected = true
            connectTimeoutTask?.cancel()
            coordinator?.legConnected(self, info: connectionInfo)
        case .ended:
            coordinator?.legClosed(self, failed: false)
        case .peerMedia, .ok:
            ()
        case let .error(message):
            logger.error("GroupCallLeg: command error: \(message)")
        case let .invalid(type):
            logger.error("GroupCallLeg: invalid response: \(type)")
        }
    }
}
