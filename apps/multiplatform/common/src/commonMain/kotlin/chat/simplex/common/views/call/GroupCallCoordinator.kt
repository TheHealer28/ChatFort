package chat.simplex.common.views.call

import androidx.compose.runtime.*
import chat.simplex.common.model.*
import chat.simplex.common.platform.Log
import chat.simplex.common.platform.TAG
import chat.simplex.common.platform.chatModel
import chat.simplex.common.views.helpers.withBGApi
import kotlinx.coroutines.*
import kotlinx.datetime.Clock

//
// Orchestrates a group-scoped mesh call (Kotlin port of
// apps/ios/Shared/Views/Call/GroupCallCoordinator.swift — see tasks/group-call.md).
//
// PHASE 1 (this file): the CONTROL PLANE only — hidden control messages,
// ring/accept/decline consent, the roster, and the start/join/leave choreography.
// The per-leg WebRTC media plane (legs, audio forwarding) is Phase 2 and is
// marked with TODO(phase2). No media flows yet; nothing here touches the live
// 1:1 call path. Everything is gated behind appPrefs.groupCallsEnabled (OFF).
//
// Inbound 1:1 call events (offer/answer/ice/end/invitation) are routed through
// the claim* hooks first; in Phase 1 they all return false (unclaimed → normal
// 1:1 handling) because no group legs exist yet. Phase 2 wires them to legs.
//

/** Broadcast a control signal to every member of the group in a single send. */
object GroupCallSignaling {
  suspend fun broadcast(control: GroupCallControl): Boolean {
    val rh = chatModel.remoteHostId()
    val sent = chatModel.controller.apiSendMessages(
      rh = rh,
      type = ChatType.Group,
      id = control.groupId,
      scope = null,
      composedMessages = listOf(
        ComposedMessage(fileSource = null, quotedItemId = null, msgContent = MsgContent.MCText(control.encodedText()), mentions = emptyMap())
      )
    )
    // Purge our own copy — the control message must never appear as a bubble when
    // this chat's history loads (it already fanned out to members on send).
    if (sent != null && sent.isNotEmpty()) {
      val ids = sent.map { it.chatItem.id }
      try {
        chatModel.controller.apiDeleteChatItems(rh, ChatType.Group, control.groupId, null, ids, CIDeleteMode.cidmInternal)
      } catch (e: Exception) {
        Log.e(TAG, "GroupCall: control snd item delete error: ${e.message}")
      }
    }
    return sent != null
  }
}

/** An incoming group call ringing, awaiting the user's Accept/Decline. */
data class PendingGroupCall(
  val control: GroupCallControl,
  val groupInfo: GroupInfo,
  val groupName: String,
  val callerName: String,
  val heldInvitations: MutableMap<Long, RcvCallInvitation> = mutableMapOf(),
)

object GroupCallCoordinator {
  /** Emergency kill-switch + on-device gate. The 1:1 path is untouched while OFF. */
  val isEnabled: Boolean get() = chatModel.controller.appPrefs.groupCallsEnabled.get()

  /** Ignore `.start` controls older than this (delivered late after offline). */
  private const val START_CONTROL_MAX_AGE_MS = 120_000L
  /** Auto-decline an unanswered incoming call after this long. */
  private const val RING_TIMEOUT_MS = 60_000L

  /** The group call currently in progress, if any. */
  var activeGroupCall: GroupCall? by mutableStateOf(null)
    private set
  /** An incoming group call ringing, awaiting Accept/Decline. */
  var pendingIncomingCall: PendingGroupCall? by mutableStateOf(null)
    private set
  var callViewCollapsed: Boolean by mutableStateOf(false)
  var micEnabled: Boolean by mutableStateOf(true)
    private set
  var speakerEnabled: Boolean by mutableStateOf(false)
    private set

  /** The call's group roster, fetched directly via apiListMembers (never from
   *  ChatModel.groupMembers, which is only populated when that group's chat is
   *  open on screen — on a cold ring that silently yields an empty roster). */
  private var currentMembers: List<GroupMember> = emptyList()
  private var ringTimeoutJob: Job? = null

  /** Live WebRTC legs keyed by legId (= leg contact's apiId as a string). */
  private val legs = mutableMapOf<String, GroupCallLeg>()

  // MARK: - Host: start a group call

  fun startGroupCall(groupInfo: GroupInfo, media: CallMediaType) {
    if (!isEnabled || activeGroupCall != null || pendingIncomingCall != null) return
    withBGApi {
      val members = chatModel.controller.apiListMembers(chatModel.remoteHostId(), groupInfo.groupId)
      withContext(Dispatchers.Main) {
        currentMembers = members
        startGroupCallWithRoster(groupInfo, media)
      }
    }
  }

  private fun startGroupCallWithRoster(groupInfo: GroupInfo, media: CallMediaType) {
    if (activeGroupCall != null || pendingIncomingCall != null) return
    val localMemberId = groupInfo.membership.memberId
    val instanceId = "${groupInfo.groupId}-$localMemberId-${Clock.System.now().toEpochMilliseconds()}"
    val resolved = resolveCurrentMembers(localMemberId)

    val call = GroupCall.make(
      groupCallUUID = instanceId,
      groupId = groupInfo.groupId,
      groupName = groupInfo.displayName,
      localMemberId = localMemberId,
      localInitiated = true,
      media = media,
      members = resolved,
    )
    resetCallUIState()
    activeGroupCall = call

    val control = GroupCallControl(
      kind = GroupCallControlKind.Start,
      instanceId = instanceId,
      groupId = groupInfo.groupId,
      fromMemberId = localMemberId,
      media = media,
      participantMemberIds = resolved.map { it.first.memberId },
    )
    Log.d(TAG, "GroupCall: starting (${resolved.size} participants, ${resolved.count { it.second != null }} callable)")
    withBGApi {
      GroupCallSignaling.broadcast(control)
      // Give the control a head start over the per-leg invitations (different
      // connections); held-invitation handling covers the remaining race.
      delay(1_500)
      withContext(Dispatchers.Main) { establishLegs() }
    }
  }

  // MARK: - Inbound control

  /** Handle a hidden group-call control message. `tsMs` is the message time
   *  (stale starts ignored). Called from the NewChatItems interceptor. */
  fun handleControl(control: GroupCallControl, groupInfo: GroupInfo?, tsMs: Long = Clock.System.now().toEpochMilliseconds()) {
    if (!isEnabled || groupInfo == null) return
    val localMemberId = groupInfo.membership.memberId
    if (control.fromMemberId == localMemberId) return // ignore our own echo

    when (control.kind) {
      GroupCallControlKind.Start -> {
        if (Clock.System.now().toEpochMilliseconds() - tsMs > START_CONTROL_MAX_AGE_MS) {
          Log.d(TAG, "GroupCall: ignoring stale start")
          return
        }
        if (activeGroupCall != null || pendingIncomingCall != null) return
        withBGApi {
          val members = chatModel.controller.apiListMembers(chatModel.remoteHostId(), groupInfo.groupId)
          withContext(Dispatchers.Main) {
            currentMembers = members
            ringIncomingCall(control, groupInfo)
          }
        }
      }
      GroupCallControlKind.Join -> {
        val call = activeGroupCall ?: return
        if (call.groupCallUUID != control.instanceId) return
        if (call.participant(control.fromMemberId) == null) {
          memberForId(control.fromMemberId)?.let { gm ->
            call.addParticipant(GroupCallParticipant(gm.memberId, gm.groupMemberId, contactFor(gm), gm.displayName))
          }
        }
        establishLegs()
      }
      GroupCallControlKind.Leave -> {
        // Caller hung up while we were still ringing → missed call.
        val pending = pendingIncomingCall
        if (pending != null && pending.control.instanceId == control.instanceId && pending.control.fromMemberId == control.fromMemberId) {
          cancelPendingCall(remoteEnded = true)
          return
        }
        val call = activeGroupCall ?: return
        if (call.groupCallUUID != control.instanceId) return
        call.markLeft(control.fromMemberId)
        // Tear down the departed participant's leg.
        val legId = call.participant(control.fromMemberId)?.contact?.apiId?.toString()
        if (legId != null) legs.remove(legId)?.shutdown(notifyPeer = false)
        // TODO(phase2 forwarding): recompute host audio forwarding table.
        finishCallIfNoLegs()
      }
    }
  }

  // MARK: - Ring / Accept / Decline (consent)

  private fun ringIncomingCall(control: GroupCallControl, groupInfo: GroupInfo) {
    if (activeGroupCall != null || pendingIncomingCall != null) return
    val callerName = memberForId(control.fromMemberId)?.displayName ?: "Group member"
    pendingIncomingCall = PendingGroupCall(control, groupInfo, groupInfo.displayName, callerName)
    Log.d(TAG, "GroupCall: ringing incoming group call")
    ringTimeoutJob?.cancel()
    ringTimeoutJob = withBGApi {
      delay(RING_TIMEOUT_MS)
      withContext(Dispatchers.Main) { missPendingCall() }
    }
  }

  /** User accepted (in-app button). */
  fun acceptPendingCall() {
    val pending = pendingIncomingCall ?: return
    ringTimeoutJob?.cancel()
    pendingIncomingCall = null
    resetCallUIState()
    joinCall(pending.control, pending.groupInfo)   // builds roster + establishLegs()
    // Absorb leg invitations that arrived while ringing into their (now created) legs.
    val call = activeGroupCall
    for ((apiId, inv) in pending.heldInvitations) {
      val leg = legs[apiId.toString()]
      if (leg != null) {
        leg.startIncoming(inv)
        call?.participants?.firstOrNull { it.contact?.apiId == apiId }
          ?.let { call.updateLegState(it.memberId, GroupCallLegState.Connecting) }
      }
    }
    Log.d(TAG, "GroupCall: accepted incoming group call")
  }

  /** User declined (in-app button). */
  fun declinePendingCall() {
    val pending = pendingIncomingCall ?: return
    ringTimeoutJob?.cancel()
    pendingIncomingCall = null
    rejectHeldInvitations(pending)
    val control = GroupCallControl(
      kind = GroupCallControlKind.Leave,
      instanceId = pending.control.instanceId,
      groupId = pending.groupInfo.groupId,   // local groupId (see joinCall note)
      fromMemberId = pending.groupInfo.membership.memberId,
    )
    withBGApi { GroupCallSignaling.broadcast(control) }
    Log.d(TAG, "GroupCall: declined incoming group call")
  }

  /** Ring timed out unanswered. */
  private fun missPendingCall() {
    val pending = pendingIncomingCall ?: return
    pendingIncomingCall = null
    rejectHeldInvitations(pending)
    Log.d(TAG, "GroupCall: incoming group call missed (timeout)")
  }

  /** Caller hung up while we were ringing. */
  private fun cancelPendingCall(remoteEnded: Boolean) {
    val pending = pendingIncomingCall ?: return
    ringTimeoutJob?.cancel()
    pendingIncomingCall = null
    rejectHeldInvitations(pending)
    Log.d(TAG, "GroupCall: incoming group call cancelled by caller")
  }

  private fun rejectHeldInvitations(pending: PendingGroupCall) {
    val held = pending.heldInvitations.values.toList()
    if (held.isEmpty()) return
    withBGApi {
      for (inv in held) {
        chatModel.controller.apiRejectCall(inv.remoteHostId, inv.contact)
      }
    }
  }

  /** Build the call state for an accepted `.start` and join it. */
  private fun joinCall(control: GroupCallControl, groupInfo: GroupInfo) {
    if (activeGroupCall != null) return
    val localMemberId = groupInfo.membership.memberId
    val ids = ((control.participantMemberIds ?: emptyList()) + control.fromMemberId)
      .filter { it != localMemberId }
      .toSet()
    val resolved = ids.mapNotNull { id ->
      memberForId(id)?.let { gm -> gm to contactFor(gm) }
    }
    // IMPORTANT: groupId is device-LOCAL. The call + all our broadcasts must use
    // OUR local groupInfo.groupId, never the sender's control.groupId (that id
    // doesn't exist in our DB → "store group not found"). instanceId is the
    // cross-device call identifier and is preserved.
    val call = GroupCall.make(
      groupCallUUID = control.instanceId,
      groupId = groupInfo.groupId,
      groupName = groupInfo.displayName,
      localMemberId = localMemberId,
      localInitiated = false,
      media = control.media ?: CallMediaType.Audio,
      members = resolved,
    )
    activeGroupCall = call
    Log.d(TAG, "GroupCall: joined group call (${resolved.size} participants)")
    val join = GroupCallControl(
      kind = GroupCallControlKind.Join,
      instanceId = control.instanceId,
      groupId = groupInfo.groupId,
      fromMemberId = localMemberId,
    )
    withBGApi { GroupCallSignaling.broadcast(join) }
    establishLegs()
  }

  // MARK: - Leg establishment

  /** For each callable participant without a leg: if the deterministic rule says
   *  we initiate, start an outgoing leg (capabilities → invitation); otherwise
   *  register a passive leg and absorb an already-arrived invitation. The shared
   *  WebView (call.js) drives the actual WebRTC, multiplexed by legId. */
  private fun establishLegs() {
    val call = activeGroupCall ?: return
    for (p in call.callableParticipants) {
      val contact = p.contact ?: continue
      val legId = contact.apiId.toString()
      if (legs[legId] != null) continue
      val outgoing = call.localInitiatesOffer(p)
      val leg = GroupCallLeg(contact = contact, memberId = p.memberId, media = call.initialMedia, outgoing = outgoing)
      legs[legId] = leg
      if (outgoing) {
        leg.startOutgoing()
        call.updateLegState(p.memberId, GroupCallLegState.Connecting)
      } else {
        // Their invitation may have beaten the control message — absorb it.
        val inv = chatModel.callInvitations.remove(contact.id)
        if (inv != null) {
          leg.startIncoming(inv)
          call.updateLegState(p.memberId, GroupCallLegState.Connecting)
        }
        // else passive — claimInvitation() starts it when theirs arrives.
      }
    }
  }

  private fun finishCallIfNoLegs() {
    val call = activeGroupCall ?: return
    if (legs.isNotEmpty()) return
    val anyPending = call.callableParticipants.any {
      it.state == GroupCallLegState.Invited || it.state == GroupCallLegState.Connecting || it.state == GroupCallLegState.Connected
    }
    if (!anyPending) {
      Log.d(TAG, "GroupCall: all legs closed, finishing call")
      cleanupAfterCall()
    }
  }

  // MARK: - Leg lifecycle feedback (called from GroupCallLeg)

  fun legConnected(leg: GroupCallLeg) {
    val call = activeGroupCall ?: return
    call.updateLegState(leg.memberId, GroupCallLegState.Connected)
    // Apply current mute state to legs that connect later.
    if (!micEnabled) leg.setAudioEnabled(false)
    // TODO(phase2 forwarding): host recomputes audio forwarding so everyone hears everyone.
  }

  fun legClosed(leg: GroupCallLeg, failed: Boolean) {
    if (activeGroupCall == null) return
    if (legs[leg.legId] === leg) legs.remove(leg.legId)
    activeGroupCall?.updateLegState(leg.memberId, if (failed) GroupCallLegState.Failed else GroupCallLegState.Left)
    finishCallIfNoLegs()
  }

  /** Route a legId-tagged WebView response to its leg (called from WebRTCView). */
  fun routeResponse(legId: String, resp: WCallResponse) {
    legs[legId]?.handleResponse(resp)
  }

  // MARK: - Inbound 1:1 call-event claim hooks (called from SimpleXAPI)
  // Each returns true when the event belongs to a group-call leg (1:1 handling
  // is then skipped). All are no-ops unless a group call is pending/active, so
  // the 1:1 path is untouched in normal operation (and entirely while flag OFF).

  fun claimInvitation(invitation: RcvCallInvitation): Boolean {
    if (!isEnabled) return false
    val apiId = invitation.contact.apiId
    // While ringing, hold leg invitations from expected members so they never
    // ring as 1:1 (absorbed on accept, rejected on decline).
    val pending = pendingIncomingCall
    if (pending != null && isMemberOf(pending, apiId)) {
      pending.heldInvitations[apiId] = invitation
      Log.d(TAG, "GroupCall: held a leg invitation while ringing")
      return true
    }
    val call = activeGroupCall ?: return false
    val p = call.participants.firstOrNull { it.contact?.apiId == apiId } ?: return false
    val legId = apiId.toString()
    val leg = legs[legId] ?: GroupCallLeg(invitation.contact, p.memberId, call.initialMedia, outgoing = false).also { legs[legId] = it }
    leg.startIncoming(invitation)   // no-op if already started (duplicate invitation)
    call.updateLegState(p.memberId, GroupCallLegState.Connecting)
    return true
  }

  fun claimOffer(contact: Contact, offer: WebRTCSession, sharedKey: String?): Boolean {
    if (!isEnabled || activeGroupCall == null) return false
    val leg = legs[contact.apiId.toString()] ?: return false
    leg.handleRemoteOffer(offer, sharedKey)
    return true
  }

  fun claimAnswer(contact: Contact, answer: WebRTCSession): Boolean {
    if (!isEnabled || activeGroupCall == null) return false
    val leg = legs[contact.apiId.toString()] ?: return false
    leg.handleRemoteAnswer(answer)
    return true
  }

  fun claimExtraInfo(contact: Contact, extraInfo: WebRTCExtraInfo): Boolean {
    if (!isEnabled || activeGroupCall == null) return false
    val leg = legs[contact.apiId.toString()] ?: return false
    leg.handleRemoteIce(extraInfo)
    return true
  }

  fun claimCallEnded(contact: Contact): Boolean {
    if (!isEnabled || activeGroupCall == null) return false
    val leg = legs.remove(contact.apiId.toString()) ?: return false
    leg.shutdown(notifyPeer = false)
    activeGroupCall?.markLeft(leg.memberId)
    finishCallIfNoLegs()
    return true
  }

  private fun isMemberOf(pending: PendingGroupCall, contactApiId: Long): Boolean {
    val ids = (pending.control.participantMemberIds ?: emptyList()) + pending.control.fromMemberId
    return ids.any { id -> memberForId(id)?.memberContactId == contactApiId }
  }

  // MARK: - In-call controls

  fun setMic(enabled: Boolean) {
    micEnabled = enabled
    for (leg in legs.values) leg.setAudioEnabled(enabled)
  }

  fun setSpeaker(enabled: Boolean) {
    speakerEnabled = enabled
    // TODO(phase2 audio): route through the shared CallAudioDeviceManager once per session.
  }

  // MARK: - End (local user hangs up)

  fun endGroupCall() {
    val call = activeGroupCall ?: return
    val control = GroupCallControl(
      kind = GroupCallControlKind.Leave,
      instanceId = call.groupCallUUID,
      groupId = call.groupId,
      fromMemberId = call.localMemberId,
    )
    withBGApi { GroupCallSignaling.broadcast(control) }
    for (leg in legs.values) leg.shutdown(notifyPeer = true)
    legs.clear()
    cleanupAfterCall()
    Log.d(TAG, "GroupCall: ended group call")
  }

  private fun cleanupAfterCall() {
    for (leg in legs.values) leg.shutdown(notifyPeer = false)
    legs.clear()
    activeGroupCall = null
    currentMembers = emptyList()
    resetCallUIState()
    // TODO(phase2 audio): restore the shared audio session to defaults.
  }

  private fun resetCallUIState() {
    callViewCollapsed = false
    micEnabled = true
    speakerEnabled = false
  }

  // MARK: - Member / contact resolution

  private fun resolveCurrentMembers(localMemberId: String): List<Pair<GroupMember, Contact?>> =
    currentMembers
      .filter { it.memberId != localMemberId && it.memberCurrent }
      .map { it to contactFor(it) }

  private fun memberForId(memberId: String): GroupMember? =
    currentMembers.firstOrNull { it.memberId == memberId }
      ?: chatModel.groupMembers.value.firstOrNull { it.memberId == memberId }

  private fun contactFor(member: GroupMember): Contact? {
    val cid = member.memberContactId ?: return null
    val chat = chatModel.getContactChat(cid) ?: return null
    val info = chat.chatInfo
    return if (info is ChatInfo.Direct) info.contact else null
  }
}
