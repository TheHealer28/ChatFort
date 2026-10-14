package chat.simplex.common.views.safetyhub

import chat.simplex.common.model.*
import chat.simplex.common.model.ChatController.appPrefs
import chat.simplex.common.platform.*
import chat.simplex.common.views.helpers.*
import chat.simplex.res.MR
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.*

/**
 * ChatFort: contacts the user marks as trusted (chat list long-press → "Mark as trusted").
 * They receive the Safety Hub "I'm safe" message.
 *
 * Stored in [AppPreferences.inqTrustedContacts] per chat profile as "contactId@createdAtMillis",
 * so a new contact that later reuses a deleted contact's ID is never trusted by accident.
 * The list is cleared together with the database (Emergency Wipe, self-destruct passcode, delete database).
 */
object TrustedContacts {
  private fun load(raw: String?): Map<String, Set<String>> =
    if (raw == null) emptyMap()
    else try {
      json.decodeFromString<Map<String, List<String>>>(raw).mapValues { it.value.toSet() }
    } catch (e: Exception) {
      Log.e(TAG, "TrustedContacts: bad stored value: ${e.message}")
      emptyMap()
    }

  private fun key(contact: Contact) = "${contact.contactId}@${contact.createdAt.toEpochMilliseconds()}"

  private fun userKey(): String? = chatModel.currentUser.value?.userId?.toString()

  /** [raw] is the preference value; pass `appPrefs.inqTrustedContacts.state.value` from composables to recompose on change. */
  fun isTrusted(contact: Contact, raw: String? = appPrefs.inqTrustedContacts.get()): Boolean {
    val u = userKey() ?: return false
    return load(raw)[u]?.contains(key(contact)) == true
  }

  fun setTrusted(contact: Contact, trusted: Boolean) {
    val u = userKey() ?: return
    val all = load(appPrefs.inqTrustedContacts.get()).toMutableMap()
    val mine = (all[u] ?: emptySet()).let { if (trusted) it + key(contact) else it - key(contact) }
    if (mine.isEmpty()) all.remove(u) else all[u] = mine
    appPrefs.inqTrustedContacts.set(if (all.isEmpty()) null else json.encodeToString(all.mapValues { it.value.sorted() }))
  }

  /** Trusted contacts of the current profile that still exist, in chat-list order. */
  fun trustedChats(raw: String? = appPrefs.inqTrustedContacts.get()): List<Chat> {
    val u = userKey() ?: return emptyList()
    val keys = load(raw)[u] ?: return emptyList()
    if (keys.isEmpty()) return emptyList()
    return chatModel.chats.value.filter { chat ->
      val cInfo = chat.chatInfo
      cInfo is ChatInfo.Direct && keys.contains(key(cInfo.contact))
    }
  }

  /** Direct contacts that can be picked as emergency contacts (connected, not pending requests), by name. */
  fun selectableChats(): List<Chat> =
    chatModel.chats.value.filter { chat ->
      val c = (chat.chatInfo as? ChatInfo.Direct)?.contact
      c != null && c.active && c.activeConn != null && !c.nextAcceptContactRequest
    }.sortedBy { it.chatInfo.displayName.lowercase() }

  /** The check-in text: the user's own, or the localized default. */
  fun checkInMessage(raw: String? = appPrefs.inqCheckInMessage.get()): String =
    raw?.takeIf { it.isNotBlank() } ?: generalGetString(MR.strings.inq_checkin_default)

  /** Sends [text] to every trusted contact that can receive messages. Returns (sent, notSent). */
  suspend fun sendCheckIn(text: String = checkInMessage()): Pair<Int, Int> {
    var sent = 0
    var notSent = 0
    for (chat in trustedChats()) {
      val contact = (chat.chatInfo as? ChatInfo.Direct)?.contact
      if (contact == null || !contact.active || !contact.sndReady) {
        notSent++
        continue
      }
      val items = try {
        chatModel.controller.apiSendMessages(
          rh = chat.remoteHostId,
          type = ChatType.Direct,
          id = contact.contactId,
          scope = null,
          composedMessages = listOf(ComposedMessage(fileSource = null, quotedItemId = null, msgContent = MsgContent.MCText(text), mentions = emptyMap()))
        )
      } catch (e: Exception) {
        Log.e(TAG, "TrustedContacts: send failed: ${e.message}")
        null
      }
      if (items.isNullOrEmpty()) {
        notSent++
      } else {
        sent++
        withContext(Dispatchers.Main) {
          items.forEach { chatModel.chatsContext.addChatItem(chat.remoteHostId, it.chatInfo, it.chatItem) }
        }
      }
    }
    return sent to notSent
  }
}
