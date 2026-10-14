package chat.simplex.common.views.call

import androidx.compose.runtime.*
import androidx.compose.runtime.snapshots.SnapshotStateList
import chat.simplex.common.model.Contact
import chat.simplex.common.model.GroupMember
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant

//
// Small group calls (up to 5) over a full WebRTC mesh, SCOPED TO A SIMPLEX GROUP.
// Kotlin port of apps/ios/Shared/Views/Call/GroupCall.swift — see tasks/group-call.md.
//
// Why group-scoped (vs loose contacts): a symmetric mesh needs every pair to
// (a) identify each other and (b) be reachable by the call API. SimpleX makes
// direct contacts non-correlatable across people, so loose-contact meshes can't
// choreograph. A SimpleX group solves both:
//   - GroupMember.memberId is a STABLE, group-wide identity every member agrees
//     on → the roster key and the deterministic offer-ordering operand.
//   - GroupMember.memberContactId, when set, gives the contactId the existing
//     1:1 call API needs. A participant is callable only when it is a mutual
//     member-contact; pairs without one are surfaced as "not connected".
//
// Backend: NO change. The engine stores calls per-contact, so N independent legs
// already coexist. Signaling reuses the existing per-contact call APIs verbatim.
//
// This is the additive state model only. It does NOT touch the live 1:1 path
// (ChatModel.activeCall, CallView, CallManager). WebRTC wiring lands in Phase 2
// behind the group-calls feature flag.
//

/** Hard cap on mesh participants, including the local user. Above ~5 a full
 *  mesh (N-1 uplinks/device) collapses on weak networks. */
const val GROUP_CALL_MAX_PARTICIPANTS = 5

/** Lifecycle of a single pairwise leg within a group call. Mirrors the 1:1
 *  CallState machine but tracked per-participant so the coordinator can show
 *  "3 of 4 connected" and drive per-leg retries independently. */
enum class GroupCallLegState {
  Invited,        // in the roster, no media negotiation started yet
  Connecting,     // offer/answer/ICE in flight for this leg
  Connected,      // media flowing with this participant
  Reconnecting,   // was connected, leg dropped, attempting to re-establish
  Failed,         // this leg could not be established
  Left,           // this participant left (or we removed them)
  Unreachable;    // no member-contact to this participant — cannot mesh

  val isLive: Boolean get() = this == Connected || this == Reconnecting
}

/** One remote participant in a group call, keyed by the stable group memberId.
 *  Reactive fields are Compose state so the call UI recomposes on change. */
class GroupCallParticipant(
  /** Stable, group-wide-consistent identity. Every member's app agrees on this
   *  value for the same person → roster key + deterministic offer ordering. */
  val memberId: String,
  /** Local DB id of this member within the group (member-scoped APIs). */
  val groupMemberId: Long,
  /** Direct-contact view of this member, when a member-contact exists. The
   *  existing 1:1 call API requires a Contact, so a participant is callable only
   *  when this is non-null. null → mutually-unconnected in the group. */
  val contact: Contact?,
  val displayName: String,
  state: GroupCallLegState? = null,
) {
  val id: String get() = memberId

  // Unreachable members can't mesh; everyone else starts as invited.
  var state: GroupCallLegState by mutableStateOf(
    state ?: if (contact == null) GroupCallLegState.Unreachable else GroupCallLegState.Invited
  )

  /** Reachable for a mesh leg: must be a mutual member-contact. */
  val isCallable: Boolean get() = contact != null
}

/** Coordinates a small group call as a mesh of per-member legs. This is the
 *  aggregate a future ChatModel.activeGroupCall holds, parallel to (and never
 *  replacing) the 1:1 activeCall. */
class GroupCall(
  /** Stable id for this group-call session (the control-message instanceId). */
  val groupCallUUID: String,
  val groupId: Long,
  /** Display name of the group, for the call screen. */
  val groupName: String,
  /** This device's own memberId — the left operand of the deterministic
   *  offer-ordering rule (glare avoidance). */
  val localMemberId: String,
  val localInitiated: Boolean,
  val initialMedia: CallMediaType,
  initialParticipants: List<GroupCallParticipant> = emptyList(),
) {
  val participants: SnapshotStateList<GroupCallParticipant> =
    mutableStateListOf<GroupCallParticipant>().apply { addAll(initialParticipants) }

  var startedAt: Instant? by mutableStateOf(null)   // time of first connected leg (call timer base)

  /** Total people on the call including the local user. */
  val totalCount: Int get() = participants.size + 1
  val canAddParticipant: Boolean get() = totalCount < GROUP_CALL_MAX_PARTICIPANTS

  /** Participants we can actually mesh with (have a member-contact). */
  val callableParticipants: List<GroupCallParticipant> get() = participants.filter { it.isCallable }
  /** Roster entries that can't be reached (no member-contact) — surfaced in UI. */
  val unreachableParticipants: List<GroupCallParticipant> get() = participants.filter { !it.isCallable }
  /** Participants currently exchanging media. */
  val liveParticipants: List<GroupCallParticipant> get() = participants.filter { it.state.isLive }
  val connectedCount: Int get() = participants.count { it.state == GroupCallLegState.Connected }
  /** True once at least one leg is connected — used to start the call timer. */
  val anyConnected: Boolean get() = connectedCount > 0

  /** Participants in a stable display order (by name, then memberId). */
  val orderedParticipants: List<GroupCallParticipant>
    get() = participants.sortedWith(compareBy({ it.displayName.lowercase() }, { it.memberId }))

  fun participant(memberId: String): GroupCallParticipant? = participants.firstOrNull { it.memberId == memberId }

  /** Add a participant if under the cap and not already present. */
  fun addParticipant(p: GroupCallParticipant): Boolean {
    if (participant(p.memberId) != null || !canAddParticipant) return false
    participants.add(p)
    return true
  }

  /** Deterministic glare rule: for any pair, the lower memberId sends the offer.
   *  Every device agrees on memberIds, so exactly one side initiates. */
  fun localInitiatesOffer(to: GroupCallParticipant): Boolean = localMemberId < to.memberId

  fun updateLegState(memberId: String, state: GroupCallLegState) {
    val p = participant(memberId) ?: return
    p.state = state
    if (state == GroupCallLegState.Connected && startedAt == null) {
      startedAt = Clock.System.now()
    }
  }

  /** Mark a participant as gone. Leaves the entry in Left so the UI can briefly
   *  show it before the coordinator prunes it. */
  fun markLeft(memberId: String) {
    participant(memberId)?.state = GroupCallLegState.Left
  }

  fun removeParticipant(memberId: String) {
    participants.removeAll { it.memberId == memberId }
  }

  /** True when every reachable participant's leg has settled (connected, or
   *  failed/left) — i.e. no callable leg is still negotiating. */
  val allLegsSettled: Boolean
    get() = callableParticipants.all { p ->
      when (p.state) {
        GroupCallLegState.Connected, GroupCallLegState.Failed, GroupCallLegState.Left -> true
        GroupCallLegState.Invited, GroupCallLegState.Connecting,
        GroupCallLegState.Reconnecting, GroupCallLegState.Unreachable -> false
      }
    }

  companion object {
    /** Build a group call from resolved (member, contact?) pairs. Contact
     *  resolution (memberContactId → Contact) is done by the caller to keep this
     *  model free of global coupling. Members without a member-contact are
     *  included as Unreachable so the UI can explain why they aren't on the call. */
    fun make(
      groupCallUUID: String,
      groupId: Long,
      groupName: String,
      localMemberId: String,
      localInitiated: Boolean,
      media: CallMediaType,
      members: List<Pair<GroupMember, Contact?>>,
    ): GroupCall {
      val capped = members.take(GROUP_CALL_MAX_PARTICIPANTS - 1)
      val parts = capped.map { (member, contact) ->
        GroupCallParticipant(
          memberId = member.memberId,
          groupMemberId = member.groupMemberId,
          contact = contact,
          displayName = member.displayName,
        )
      }
      return GroupCall(
        groupCallUUID = groupCallUUID,
        groupId = groupId,
        groupName = groupName,
        localMemberId = localMemberId,
        localInitiated = localInitiated,
        initialMedia = media,
        initialParticipants = parts,
      )
    }
  }
}
