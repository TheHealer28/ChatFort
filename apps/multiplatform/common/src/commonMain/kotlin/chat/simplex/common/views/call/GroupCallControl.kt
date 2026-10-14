package chat.simplex.common.views.call

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

//
// Group-call control plane — the hidden coordination signal that lets every
// member independently establish its mesh legs.
//
// WIRE-FORMAT CONTRACT (must stay byte-compatible with the iOS app —
// apps/ios/InqalaabChat/CallTypes.swift). iOS↔Android group calls only
// interoperate if both sides produce/parse the IDENTICAL marker + JSON:
//
//   <U+200B>ICF-GC1 {"kind":"start","instanceId":"...","groupId":123,
//                    "fromMemberId":"...","media":"audio",
//                    "participantMemberIds":["...","..."]}
//
// Transport: a normal `.text` group message. One apiSendMessages(group) fans it
// to every member via the existing group-send path; on receive it is intercepted
// at the NewChatItems chokepoint and hidden (no bubble, no notification).
// Riding `.text` (not an unknown MsgContent, which the encoder downgrades)
// guarantees a lossless round-trip.
//
// The leading zero-width space + namespaced tag means that if the item is ever
// shown raw (e.g. by a non-ChatFort client in the group) it reads as innocuous
// rather than as garbage.
//

@Serializable
enum class GroupCallControlKind {
  @SerialName("start") Start,   // announces a new call instance + participant roster
  @SerialName("join") Join,     // a member announces they are joining
  @SerialName("leave") Leave    // a member announces they are leaving / declining
}

@Serializable
data class GroupCallControl(
  val kind: GroupCallControlKind,
  // Unique per call session — distinguishes concurrent/sequential calls in one group.
  val instanceId: String,
  val groupId: Long,
  // Sender's stable memberId within the group.
  val fromMemberId: String,
  // Present on `.start`.
  val media: CallMediaType? = null,
  // Roster of participant memberIds, present on `.start`.
  val participantMemberIds: List<String>? = null
) {
  /** Serialize to the sentinel-prefixed text payload carried by a `.text` message. */
  fun encodedText(): String = "$MARKER ${groupCallControlJson.encodeToString(this)}"

  companion object {
    /** Zero-width space (U+200B) + namespaced, versioned tag. Bump GC1→GC2 on format change.
     *  Written as an escape so the invisible char can't be lost/corrupted by an editor. */
    const val MARKER = "​ICF-GC1"

    /**
     * Parse a received message's text. Returns null for any normal message — the
     * receive interceptor uses null to mean "not a control message, leave it
     * alone", so this must never match ordinary user text (the marker guards that).
     */
    fun parse(text: String): GroupCallControl? {
      if (!text.startsWith(MARKER)) return null
      val jsonPart = text.substring(MARKER.length).trim()
      return try {
        groupCallControlJson.decodeFromString<GroupCallControl>(jsonPart)
      } catch (e: Exception) {
        null
      }
    }
  }
}

// Dedicated JSON config so the output matches Swift's JSONEncoder, which OMITS
// nil optionals. explicitNulls=false drops null media/participantMemberIds on
// .join/.leave; ignoreUnknownKeys tolerates forward-compatible additions.
private val groupCallControlJson = Json {
  encodeDefaults = false
  explicitNulls = false
  ignoreUnknownKeys = true
}
