package chat.simplex.common.views.call

import chat.simplex.common.model.ChatController.appPrefs
import chat.simplex.common.model.Contact
import chat.simplex.common.platform.Log
import chat.simplex.common.platform.TAG
import chat.simplex.common.platform.chatModel
import chat.simplex.common.views.helpers.withBGApi

//
// One WebRTC leg of a group call. Kotlin port of the per-leg machinery in
// apps/ios/Shared/Views/Call/GroupCallCoordinator.swift (class GroupCallLeg).
//
// CRITICAL Android difference from iOS: iOS gives each leg its own native
// WebRTCClient. Android has ONE WebView running call.js, so a leg does NOT own a
// client — it multiplexes the shared WebView by `legId`. It enqueues commands
// tagged with its legId into chatModel.groupCallCommand, and the coordinator
// routes legId-tagged WVAPIMessage responses back to handleResponse().
//
// The response loop mirrors ActiveCallView's 1:1 processRtcMessage, but bound to
// this leg's Contact (capabilities → invitation, offer → sendOffer, etc.).
//
class GroupCallLeg(
  val contact: Contact,
  val memberId: String,
  val media: CallMediaType,
  /** True when the deterministic glare rule says WE send the invitation. */
  val outgoing: Boolean,
) {
  /** Unique per-leg key within the call: the leg contact's apiId, as a string.
   *  Tags every command/response so the shared WebView routes to this leg. */
  val legId: String = contact.apiId.toString()

  private val rh: Long? get() = chatModel.remoteHostId()
  private var sharedKey: String? = null
  private var started = false
  private var shuttingDown = false
  var isConnected = false
    private set

  private fun send(command: WCallCommand) {
    // Tag with legId so call.js routes to this leg's RTCPeerConnection, not the
    // 1:1 activeCall. Enqueued on the parallel group queue (1:1 queue untouched).
    chatModel.groupCallCommand.add(WVAPICall(legId = legId, command = command))
  }

  // MARK: - Outbound setup

  /** We invite: capabilities → (response) apiSendCallInvitation(contact). */
  fun startOutgoing() {
    if (started) return
    started = true
    send(WCallCommand.Capabilities(media = media))
  }

  /** They invited: start WebRTC → (response) offer → apiSendCallOffer(contact). */
  fun startIncoming(invitation: RcvCallInvitation) {
    if (started) return
    started = true
    sharedKey = invitation.sharedKey
    send(WCallCommand.Start(
      media = invitation.callType.media,
      aesKey = invitation.sharedKey,
      iceServers = getIceServers(),
      relay = appPrefs.webrtcPolicyRelay.get(),
    ))
  }

  /** Their WebRTC offer arrived (we are the inviter side of this leg). */
  fun handleRemoteOffer(offer: WebRTCSession, sharedKey: String?) {
    this.sharedKey = sharedKey
    send(WCallCommand.Offer(
      offer = offer.rtcSession,
      iceCandidates = offer.rtcIceCandidates,
      media = media,
      aesKey = sharedKey,
      iceServers = getIceServers(),
      relay = appPrefs.webrtcPolicyRelay.get(),
    ))
  }

  fun handleRemoteAnswer(answer: WebRTCSession) {
    send(WCallCommand.Answer(answer = answer.rtcSession, iceCandidates = answer.rtcIceCandidates))
  }

  fun handleRemoteIce(extraInfo: WebRTCExtraInfo) {
    send(WCallCommand.Ice(iceCandidates = extraInfo.rtcIceCandidates))
  }

  fun setAudioEnabled(enabled: Boolean) {
    send(WCallCommand.Media(source = CallMediaSource.Mic, enable = enabled))
  }

  /** Close this leg. Tears down its peer connection in call.js (legId-scoped, so
   *  the shared mic/output and other legs are untouched) and optionally tells the
   *  peer via the 1:1 end API. */
  fun shutdown(notifyPeer: Boolean) {
    if (shuttingDown) return
    shuttingDown = true
    send(WCallCommand.End)
    if (notifyPeer) {
      val c = contact
      withBGApi { chatModel.controller.apiEndCall(rh, c) }
    }
  }

  // MARK: - Per-leg response loop (mirrors ActiveCallView.processRtcMessage)

  fun handleResponse(resp: WCallResponse) {
    if (shuttingDown) return
    when (resp) {
      is WCallResponse.Capabilities -> {
        val callType = CallType(media = media, capabilities = resp.capabilities)
        val c = contact
        withBGApi { chatModel.controller.apiSendCallInvitation(rh, c, callType) }
      }
      is WCallResponse.Offer -> {
        val c = contact
        withBGApi { chatModel.controller.apiSendCallOffer(rh, c, resp.offer, resp.iceCandidates, media, resp.capabilities) }
      }
      is WCallResponse.Answer -> {
        val c = contact
        withBGApi { chatModel.controller.apiSendCallAnswer(rh, c, resp.answer, resp.iceCandidates) }
      }
      is WCallResponse.Ice -> {
        val c = contact
        withBGApi { chatModel.controller.apiSendCallExtraInfo(rh, c, resp.iceCandidates) }
      }
      is WCallResponse.Connection -> {
        val state = resp.state.connectionState
        when (state) {
          "connected" -> { isConnected = true; GroupCallCoordinator.legConnected(this) }
          "failed", "closed" -> GroupCallCoordinator.legClosed(this, failed = state == "failed")
        }
        val status = when (state) {
          "connected" -> WebRTCCallStatus.Connected
          "connecting" -> WebRTCCallStatus.Connecting
          "disconnected" -> WebRTCCallStatus.Disconnected
          "failed" -> WebRTCCallStatus.Failed
          else -> null
        }
        if (status != null) {
          val c = contact
          withBGApi { chatModel.controller.apiCallStatus(rh, c, status) }
        }
      }
      is WCallResponse.Connected -> { isConnected = true; GroupCallCoordinator.legConnected(this) }
      is WCallResponse.Ended -> GroupCallCoordinator.legClosed(this, failed = false)
      is WCallResponse.Ok, is WCallResponse.PeerMedia, is WCallResponse.End -> {}
      is WCallResponse.Error -> Log.e(TAG, "GroupCallLeg[$legId]: command error: ${resp.message}")
    }
  }
}
