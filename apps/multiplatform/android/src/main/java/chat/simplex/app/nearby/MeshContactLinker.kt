package chat.simplex.app.nearby

import android.content.Context
import chat.simplex.common.model.*
import chat.simplex.common.platform.Log
import chat.simplex.common.platform.TAG
import chat.simplex.common.platform.androidAppContext
import chat.simplex.common.platform.chatModel
import chat.simplex.mesh.CrowdMesh
import chat.simplex.mesh.core.ContactLinks
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * Crowd mesh wire v3: links the current profile's ChatFort contacts for offline messaging.
 *
 * - Tells the mesh who the current profile's contacts are (so their mesh chats show their names).
 * - Swaps a seed with each contact inside their SimpleX chat (hidden link messages, see
 *   [ChatfortMeshLink]); after that, their phones recognise each other on the Bluetooth mesh.
 * - Sends mesh messages that a contact never confirmed through SimpleX instead, once they have waited
 *   [FALLBACK_AFTER_MS] (SimpleX queues them until there is internet).
 *
 * A contact is bound as "u<userId>:c<contactId>@<createdAt ms>", so a new contact that reuses a
 * deleted one's ID is never mistaken for it.
 */
object MeshContactLinker {
  private const val LOOP_MS = 20_000L
  private const val SEND_GAP_MS = 2_000L
  private const val FALLBACK_AFTER_MS = 2 * 60_000L
  /** Link message items already handled, so one handled twice (live and by a sweep) gets one answer. */
  private const val MAX_HANDLED_ITEMS = 2_000
  private const val PREFS = "chatfort_mesh_links"
  private const val PREF_SCANNED = "scannedProfiles"

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
  private val sending = Mutex()
  @Volatile
  private var started = false
  /** Profiles whose deep scan ran this app run (a failed one is tried again on the next start, not every loop). */
  private val scanTried = HashSet<Long>()
  private val handledItems = object : LinkedHashMap<Long, Unit>() {
    override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, Unit>?) = size > MAX_HANDLED_ITEMS
  }

  fun start() {
    if (started) return
    started = true
    ChatfortMeshLink.onReceived = { rhId, user, contact, itemId, json -> onLinkMessage(rhId, user, contact, itemId, json) }
    ChatfortMeshLink.onProfileDeleted = { userId ->
      CrowdMesh.forgetContacts("u$userId:")
      setScanned(userId, false)
    }
    ChatfortMeshLink.onDatabaseDeleted = {
      CrowdMesh.forgetContacts(null)
      prefs().edit().remove(PREF_SCANNED).apply()
    }
    scope.launch {
      while (true) {
        try {
          if (chatModel.chatRunning.value == true) refresh()
        } catch (e: Exception) {
          Log.e(TAG, "MeshContactLinker: ${e.message}")
        }
        delay(LOOP_MS)
      }
    }
  }

  fun binding(user: UserLike, contact: Contact): String =
    "u${user.userId}:c${contact.contactId}@${contact.createdAt.toEpochMilliseconds()}"

  private suspend fun refresh() {
    val user = chatModel.currentUser.value ?: return
    val rhId = chatModel.remoteHostId()
    if (rhId != null) return
    val contacts = chatModel.chats.value.mapNotNull { (it.chatInfo as? ChatInfo.Direct)?.contact }.filter { it.active && !it.chatDeleted }
    CrowdMesh.setDirectory(contacts.associate { binding(user, it) to it.displayName })
    sending.withLock {
      // Once per profile after the update: link messages an older ChatFort showed as text, read or not.
      if (!isScanned(user.userId) && scanTried.add(user.userId)) deepScan(rhId, user)
      // Link messages that arrived while this profile wasn't the active one.
      for (chat in chatModel.chats.value) {
        val contact = (chat.chatInfo as? ChatInfo.Direct)?.contact ?: continue
        val last = chat.chatItems.lastOrNull() ?: continue
        if (!ChatfortMeshLink.isLink(last)) continue
        if (last.chatDir is CIDirection.DirectRcv) ChatfortMeshLink.json(last)?.let { handleOnce(rhId, user, contact, last.id, it) }
        deleteHidden(rhId, contact, listOf(last.id))
        withContext(Dispatchers.Main) { chatModel.chatsContext.removeChatItem(rhId, chat.chatInfo, last) }
      }
      val byBinding = contacts.associateBy { binding(user, it) }
      // Answers whose sending failed earlier.
      for ((b, answer) in CrowdMesh.unsentLinkAnswers()) {
        val contact = byBinding[b] ?: continue
        if (!contact.sndReady || !isCurrent(user)) continue
        if (sendLink(rhId, contact, answer)) CrowdMesh.linkAnswerSent(b)
        delay(SEND_GAP_MS)
      }
      // Offers to contacts not linked yet (each at most twice, days apart, see ContactLinks). An offer
      // counts only once it was sent.
      for (contact in contacts) {
        if (!contact.ready || !contact.sndReady || !isCurrent(user)) continue
        val b = binding(user, contact)
        val offer = CrowdMesh.linkOffer(b) ?: continue
        if (!sendLink(rhId, contact, offer)) CrowdMesh.linkOfferFailed(b)
        delay(SEND_GAP_MS)
      }
      // Mesh messages a contact never confirmed: send them through SimpleX.
      for (f in CrowdMesh.internetFallbacks(FALLBACK_AFTER_MS)) {
        val contact = byBinding[f.contactId] ?: continue
        if (!contact.sndReady) continue
        val items = send(rhId, contact, MsgContent.MCText(f.text)) ?: continue
        CrowdMesh.markSentViaInternet(f.contactId, f.messageId)
        withContext(Dispatchers.Main) { items.forEach { chatModel.chatsContext.addChatItem(rhId, it.chatInfo, it.chatItem) } }
      }
    }
  }

  private fun isCurrent(user: UserLike): Boolean = chatModel.currentUser.value?.userId == user.userId

  /**
   * Searches every direct chat of the profile for the texts older apps showed for link messages,
   * handles the link messages found (oldest first) and deletes them. Marked done only if every
   * search worked.
   */
  private suspend fun deepScan(rhId: Long?, user: UserLike) {
    var ok = true
    for (chat in chatModel.chats.value) {
      val contact = (chat.chatInfo as? ChatInfo.Direct)?.contact ?: continue
      if (!isCurrent(user)) return
      val found = HashMap<Long, ChatItem>()
      for (text in ChatfortMeshLink.SHOWN_TEXTS) {
        val items = search(rhId, contact, text)
        if (items == null) ok = false else items.filter { ChatfortMeshLink.isLink(it) }.forEach { found[it.id] = it }
      }
      if (found.isEmpty()) continue
      val sorted = found.values.sortedBy { it.id }
      for (item in sorted) {
        if (item.chatDir is CIDirection.DirectRcv) ChatfortMeshLink.json(item)?.let { handleOnce(rhId, user, contact, item.id, it) }
      }
      deleteHidden(rhId, contact, sorted.map { it.id })
      withContext(Dispatchers.Main) { sorted.forEach { chatModel.chatsContext.removeChatItem(rhId, chat.chatInfo, it) } }
    }
    if (ok) setScanned(user.userId, true)
  }

  private suspend fun search(rhId: Long?, contact: Contact, text: String): List<ChatItem>? = try {
    val r = chatModel.controller.sendCmd(rhId, CC.ApiGetChat(ChatType.Direct, contact.contactId, null, null, ChatPagination.Last(100), text), log = false)
    if (r is API.Result && r.res is CR.ApiChat) (r.res as CR.ApiChat).chat.chatItems else null
  } catch (e: Exception) {
    Log.e(TAG, "MeshContactLinker: search failed: ${e.message}")
    null
  }

  private suspend fun onLinkMessage(rhId: Long?, user: UserLike, contact: Contact, itemId: Long, json: JsonObject) {
    sending.withLock { handleOnce(rhId, user, contact, itemId, json) }
  }

  private suspend fun handleOnce(rhId: Long?, user: UserLike, contact: Contact, itemId: Long, json: JsonObject) {
    if (handledItems.containsKey(itemId)) return
    handledItems[itemId] = Unit
    if (json["v"]?.jsonPrimitive?.intOrNull != ChatfortMeshLink.VERSION) return
    val seed = json["seed"]?.jsonPrimitive?.content?.let { ContactLinks.decodeSeed(it) } ?: return
    val day = json["day"]?.jsonPrimitive?.longOrNull ?: return
    val ack = json["ack"]?.jsonPrimitive?.booleanOrNull ?: return
    val b = binding(user, contact)
    val reply = CrowdMesh.onLinkMessage(b, seed, day, ack) ?: return
    // If this fails, the answer stays in unsentLinkAnswers and goes on the next refresh.
    if (contact.sndReady && sendLink(rhId, contact, reply)) CrowdMesh.linkAnswerSent(b)
  }

  /** True once the message was sent (and hidden from our own chat). */
  private suspend fun sendLink(rhId: Long?, contact: Contact, offer: ContactLinks.Offer): Boolean {
    val mc = ChatfortMeshLink.content(ContactLinks.encodeSeed(offer.seed), offer.day, offer.ack)
    val items = send(rhId, contact, mc) ?: return false
    deleteHidden(rhId, contact, items.map { it.chatItem.id })
    return true
  }

  private suspend fun send(rhId: Long?, contact: Contact, mc: MsgContent): List<AChatItem>? = try {
    chatModel.controller.apiSendMessages(
      rh = rhId,
      type = ChatType.Direct,
      id = contact.contactId,
      scope = null,
      composedMessages = listOf(ComposedMessage(fileSource = null, quotedItemId = null, msgContent = mc, mentions = emptyMap()))
    )?.takeIf { it.isNotEmpty() }
  } catch (e: Exception) {
    Log.e(TAG, "MeshContactLinker: send failed: ${e.message}")
    null
  }

  private suspend fun deleteHidden(rhId: Long?, contact: Contact, itemIds: List<Long>) {
    try {
      chatModel.controller.apiDeleteChatItems(rhId, ChatType.Direct, contact.contactId, null, itemIds, CIDeleteMode.cidmInternal)
    } catch (e: Exception) {
      Log.e(TAG, "MeshContactLinker: delete failed: ${e.message}")
    }
  }

  private fun prefs() = androidAppContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  private fun isScanned(userId: Long): Boolean = prefs().getStringSet(PREF_SCANNED, emptySet())!!.contains(userId.toString())

  private fun setScanned(userId: Long, scanned: Boolean) {
    val set = prefs().getStringSet(PREF_SCANNED, emptySet())!!.toMutableSet()
    if (scanned) set.add(userId.toString()) else set.remove(userId.toString())
    prefs().edit().putStringSet(PREF_SCANNED, set).apply()
  }
}
