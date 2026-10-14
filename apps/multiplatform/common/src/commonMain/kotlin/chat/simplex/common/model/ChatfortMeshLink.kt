package chat.simplex.common.model

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * ChatFort crowd mesh (wire v3): hidden messages that swap offline-contact seeds inside a contact's
 * chat, so the two phones recognise each other on the Bluetooth mesh later. They are never shown,
 * notified or counted: the receiving app hands them to [onReceived] and deletes them. Older apps show
 * [FALLBACK_TEXT]. The mesh is Android-only here, so the Android app sets the hooks.
 *
 * Content: {"type":"chatfortMeshLink","text":<FALLBACK_TEXT>,"v":3,"seed":<base64url>,"day":<UTC day>,"ack":<bool>}
 */
object ChatfortMeshLink {
  const val TYPE = "chatfortMeshLink"
  const val VERSION = 3

  /**
   * What other apps show instead. English, not translated, and the same on iOS: it is shown on the
   * other person's phone, and must not name ChatFort (that would tell them, or whoever reads their
   * phone, that this person uses it). Receivers recognise link messages by [TYPE], never by the text.
   */
  const val FALLBACK_TEXT = "This message needs a newer app version."

  /**
   * Texts of link messages that an older ChatFort may have shown, searched for once per profile after
   * the update: [FALLBACK_TEXT], and what Android test builds sent (English and Urdu).
   */
  val SHOWN_TEXTS = listOf(
    FALLBACK_TEXT,
    "Offline contact link (update ChatFort to use it)",
    "آف لائن رابطہ لنک (استعمال کے لیے چیٹ فورٹ اپ ڈیٹ کریں)"
  )

  @Volatile
  var onReceived: (suspend (rhId: Long?, user: UserLike, contact: Contact, itemId: Long, json: JsonObject) -> Unit)? = null

  /** A chat profile was deleted: its contacts' links and mesh chats go too. */
  @Volatile
  var onProfileDeleted: ((userId: Long) -> Unit)? = null

  /** The chat database was deleted: every contact's link and mesh chat goes. */
  @Volatile
  var onDatabaseDeleted: (() -> Unit)? = null

  fun isLink(item: ChatItem): Boolean = (item.content.msgContent as? MsgContent.MCUnknown)?.type == TYPE

  fun json(item: ChatItem): JsonObject? = (item.content.msgContent as? MsgContent.MCUnknown)?.json as? JsonObject

  fun content(seed: String, day: Long, ack: Boolean): MsgContent.MCUnknown =
    MsgContent.MCUnknown(
      type = TYPE,
      text = FALLBACK_TEXT,
      json = buildJsonObject {
        put("type", TYPE)
        put("text", FALLBACK_TEXT)
        put("v", VERSION)
        put("seed", seed)
        put("day", day)
        put("ack", ack)
      }
    )
}
