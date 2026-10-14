package chat.simplex.mesh

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import chat.simplex.mesh.ble.BleLinkLayer
import chat.simplex.mesh.ble.MeshThread
import chat.simplex.mesh.core.ContactChannel
import chat.simplex.mesh.core.ContactLinks
import chat.simplex.mesh.core.LinkSender
import chat.simplex.mesh.core.MediaConversation
import chat.simplex.mesh.core.MeshEvent
import chat.simplex.mesh.core.MeshRouter
import chat.simplex.mesh.core.TeamChannel
import chat.simplex.mesh.protocol.ContactBody
import chat.simplex.mesh.protocol.MediaHeader
import chat.simplex.mesh.protocol.MediaType
import chat.simplex.mesh.protocol.MeshCrypto
import chat.simplex.mesh.protocol.MeshIdentity
import chat.simplex.mesh.protocol.MessageBody
import chat.simplex.mesh.protocol.toHex
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * ChatFort's crowd mesh: multi-hop Bluetooth messaging with no internet or mobile network.
 * Public crowd chat, encrypted team channels (joined by code) and encrypted private messages.
 *
 * Public, team and stranger messages live in memory only and are cleared when the mesh stops. The
 * mesh identity is new every time the mesh starts and rotates every [IDENTITY_ROTATE_MS] while it runs
 * (people you're in a private conversation with get an encrypted handover), so nobody can follow a
 * phone by its ID. The nickname is random per session unless the user picks one. Team keys and a
 * chosen nickname are kept, encrypted with a Keystore key.
 *
 * Wire v3: linked ChatFort contacts. The app swaps a seed with each contact inside their SimpleX chat
 * ([linkOffer], [onLinkMessage]); after that their phones recognise each other on the mesh with no
 * setup. Chats with contacts (and their photos and voice notes) are kept, encrypted, until Emergency
 * Wipe; undelivered items are retried for [OUTBOX_MS] whenever the contact is in reach.
 */
object CrowdMesh {
    private const val TAG = "CrowdMesh"
    private const val MAX_MESSAGES = 500
    private const val PEER_TIMEOUT_MS = 5 * 60_000L
    private const val ANNOUNCE_EVERY_MS = 120_000L
    private const val TICK_MS = 5_000L
    /** Refreshed every tick, so it lapses by itself if the mesh thread ever stalls. */
    private const val WAKE_LOCK_MS = 60_000L
    private const val TEAM_CODE_PREFIX = "CFTEAM2"
    /** How often the mesh identity (and Bluetooth token) changes while running. */
    private const val IDENTITY_ROTATE_MS = 15 * 60_000L
    private const val MAX_NICKNAME_CHARS = 24
    private const val MAX_TEAM_NAME_CHARS = 40
    private const val MESSAGES_CHANNEL = "chatfort_crowd_messages"
    private const val MESSAGE_NOTIFICATION_ID = 10_302
    /** Undelivered items to contacts are retried for this long, ... */
    const val OUTBOX_MS = 24 * 60 * 60_000L
    /** ... at most this often each, whenever the contact is in reach ... */
    private const val RESEND_EVERY_MS = 5 * 60_000L
    /** ... and photos / voice notes at most this many times (they are heavy). */
    private const val MAX_MEDIA_RESENDS = 2
    /** While anything waits for a contact, ask it "are you there?" this often. */
    private const val PENDING_PING_EVERY_MS = 5 * 60_000L
    /** A contact counts as nearby for this long after its last packet. */
    private const val NEARBY_MS = 10 * 60_000L
    /** Team photos and voice notes are kept in memory only, up to this much. */
    private const val MAX_TEAM_MEDIA_BYTES = 16 * 1024 * 1024

    const val PUBLIC_CONVERSATION = "public"
    fun teamConversation(teamId: String) = "team:$teamId"
    fun directConversation(peerId: String) = "dm:$peerId"
    fun contactConversation(contactId: String) = "contact:$contactId"

    class Peer(val peerId: String, val nickname: String, val hops: Int, val lastSeen: Long)

    data class Message(
        val id: String,
        val peerId: String,
        val nickname: String,
        val text: String,
        val timestamp: Long,
        val isMine: Boolean,
        val hops: Int,
        val delivered: Boolean = false,
        /** A photo or voice note (its bytes: [mediaData]). */
        val media: MediaInfo? = null,
        /** Sent through the internet (SimpleX) after the mesh couldn't deliver it. */
        val viaInternet: Boolean = false
    )

    data class MediaInfo(
        val type: MediaType,
        val durationMs: Int,
        val width: Int,
        val height: Int,
        val caption: String,
        val received: Int,
        val total: Int,
        /** Own items: the media key and ID (hex), so a resend is byte-identical to the first send. */
        val mediaKey: String? = null,
        val mediaId: String? = null
    ) {
        val complete: Boolean get() = received >= total
    }

    /** A linked ChatFort contact of the current profile. [nearbyHops] is null if not heard from lately. */
    data class LinkedContact(val id: String, val name: String, val nearbyHops: Int?, val lastNearby: Long)

    /** An undelivered message the app can send through SimpleX instead. */
    class InternetFallback(val contactId: String, val messageId: String, val text: String, val timestamp: Long)

    data class Team(val id: String, val name: String)

    data class Status(val running: Boolean = false, val linkedPhones: Int = 0, val bluetoothOff: Boolean = false)

    private val _status = MutableStateFlow(Status())
    val status: StateFlow<Status> = _status.asStateFlow()
    private val _peers = MutableStateFlow<List<Peer>>(emptyList())
    val peers: StateFlow<List<Peer>> = _peers.asStateFlow()
    private val _publicMessages = MutableStateFlow<List<Message>>(emptyList())
    val publicMessages: StateFlow<List<Message>> = _publicMessages.asStateFlow()
    private val _teams = MutableStateFlow<List<Team>>(emptyList())
    val teams: StateFlow<List<Team>> = _teams.asStateFlow()
    private val _teamMessages = MutableStateFlow<Map<String, List<Message>>>(emptyMap())
    val teamMessages: StateFlow<Map<String, List<Message>>> = _teamMessages.asStateFlow()
    private val _directMessages = MutableStateFlow<Map<String, List<Message>>>(emptyMap())
    val directMessages: StateFlow<Map<String, List<Message>>> = _directMessages.asStateFlow()
    /** Unread counts by conversation key ([teamConversation] / [directConversation]). */
    private val _unread = MutableStateFlow<Map<String, Int>>(emptyMap())
    val unread: StateFlow<Map<String, Int>> = _unread.asStateFlow()
    private val _contacts = MutableStateFlow<List<LinkedContact>>(emptyList())
    val contacts: StateFlow<List<LinkedContact>> = _contacts.asStateFlow()
    private val _contactMessages = MutableStateFlow<Map<String, List<Message>>>(emptyMap())
    val contactMessages: StateFlow<Map<String, List<Message>>> = _contactMessages.asStateFlow()
    /** Recent diagnostic lines, for field testing. Never includes message text. */
    private val _log = MutableStateFlow<List<String>>(emptyList())
    val log: StateFlow<List<String>> = _log.asStateFlow()

    /** The conversation on screen: no notification or unread badge for it. */
    @Volatile
    var visibleConversation: String? = null

    private lateinit var app: Context
    private lateinit var store: MeshStore
    private val thread by lazy { MeshThread() }

    // Owned by the mesh thread
    private var router: MeshRouter? = null
    private var ble: BleLinkLayer? = null
    @Volatile
    private var identity: MeshIdentity? = null
    private var identitySince = 0L
    private var session = 0
    private var lastAnnounce = 0L
    /** Random nickname for this run, used unless the user chose one. */
    @Volatile
    private var sessionNickname: String? = null
    private var bluetoothReceiver: BroadcastReceiver? = null
    private var wakeLock: PowerManager.WakeLock? = null

    // Written on the mesh thread, read from the UI. Keyed by conversation ID: a peer's first peer ID
    // this session; after a handover, its new IDs map to it through [aliases].
    private val knownKeys = ConcurrentHashMap<String, ByteArray>()
    private val allPeers = ConcurrentHashMap<String, Peer>()
    private val aliases = ConcurrentHashMap<String, String>()

    @Volatile
    private var channels: List<TeamChannel> = emptyList()

    // Wire v3: linked contacts. [links] is guarded by itself.
    private val links = ContactLinks(System::currentTimeMillis)
    /** The current profile's contacts: binding -> display name (set by the app). */
    @Volatile
    private var directory: Map<String, String> = emptyMap()
    /** Contact -> (hops, when last heard). */
    private val nearby = ConcurrentHashMap<String, Pair<Int, Long>>()
    /** Message ID -> when last (re)sent on the mesh, and how often a photo / voice note was resent. */
    private val lastSent = ConcurrentHashMap<String, Long>()
    private val mediaResends = ConcurrentHashMap<String, Int>()
    private val teamMedia = ConcurrentHashMap<String, ByteArray>()
    private var lastPendingPing = 0L
    /** Bluetooth links at the last tick: a new one may bring a contact something is waiting for. */
    private var lastLinkCount = 0
    @Volatile
    private var chatsSaveScheduled = false

    /** Call once from Application.onCreate. No Bluetooth activity until [start]. */
    fun init(context: Context) {
        app = context.applicationContext
        store = MeshStore(app)
        channels = store.loadChannels()
        // Ratchets and saves only if there are teams whose day has moved on (no Keystore work otherwise).
        advanceTeams()
        publishTeams()
        // Linked contacts and their chats: decrypted off the main thread.
        thread.post {
            synchronized(links) {
                links.load(store.loadLinks())
                if (links.advance()) store.saveLinks(links.toJson())
            }
            _contactMessages.value = chatsFromJson(store.loadContactChats())
            publishContacts()
        }
    }

    /** Start relaying. Needs the Bluetooth permissions (and location on Android 11 and older). */
    fun start() {
        if (!::app.isInitialized) return
        startEngine()
        CrowdMeshService.start(app)
    }

    /** Called by [CrowdMeshService] when Android restarts it after the process was killed. */
    internal fun startEngine() {
        thread.post {
            if (router != null) return@post
            val id = MeshIdentity.generate().also { identity = it }
            identitySince = System.currentTimeMillis()
            val r = MeshRouter(
                identity = id,
                sender = LinkSender { link, data, bulk -> ble?.send(link, data, bulk) },
                scheduler = thread,
                clock = System::currentTimeMillis,
                onEvent = ::onEvent,
                log = ::log,
                knownUid = ::isKnownContactItem
            )
            r.nickname = nickname()
            advanceTeams()
            r.setChannels(channels)
            r.setContacts(activeContactChannels())
            router = r
            val b = BleLinkLayer(app, thread, r, ::log)
            ble = b
            b.start()
            r.announce()
            lastAnnounce = System.currentTimeMillis()
            registerBluetoothReceiver()
            holdWakeLock()
            val s = ++session
            thread.schedule(TICK_MS) { tick(s) }
            _status.value = Status(running = true, linkedPhones = 0, bluetoothOff = !b.isRunning)
        }
    }

    /** Mesh thread: stops Bluetooth and forgets everyone. The identity goes too; the next start makes a new one. */
    private fun shutDown() {
        session++
        ble?.stop()
        ble = null
        router?.clear()
        router = null
        identity = null
        sessionNickname = null
        knownKeys.clear()
        allPeers.clear()
        aliases.clear()
        unregisterBluetoothReceiver()
        releaseWakeLock()
        _peers.value = emptyList()
        _status.value = Status(running = false)
    }

    /** Stops relaying and forgets this session's messages and contacts (they live in memory only). */
    fun stop() {
        if (!::app.isInitialized) return
        thread.post {
            shutDown()
            clearMessages()
        }
        CrowdMeshService.stop(app)
    }

    /** Session messages only: chats with linked contacts are kept (until Emergency Wipe). */
    private fun clearMessages() {
        _publicMessages.value = emptyList()
        _teamMessages.value = emptyMap()
        _directMessages.value = emptyMap()
        _unread.update { u -> u.filterKeys { it.startsWith("contact:") } }
        teamMedia.clear()
        nearby.clear()
        publishContacts()
    }

    val myPeerId: String? get() = identity?.peerIdHex

    /** The chosen nickname, or this session's random one. */
    fun nickname(): String =
        store.nickname ?: sessionNickname ?: MeshStore.randomNickname().also { sessionNickname = it }

    /** Keeps [value] as the user's nickname, unless it's just this session's random one left unchanged. */
    fun setNickname(value: String) {
        val clean = MessageBody.truncateChars(value.trim(), MAX_NICKNAME_CHARS)
        if (clean.isEmpty()) return
        if (store.nickname == null && clean == sessionNickname) return
        store.nickname = clean
        thread.post {
            router?.nickname = clean
            router?.announce()
            lastAnnounce = System.currentTimeMillis()
        }
    }

    // ---- Sending ----

    /** Longest text a mesh message carries; the screens limit input to it, and longer text is cut here too. */
    const val MAX_TEXT_BYTES = MessageBody.MAX_TEXT_BYTES

    /** What will actually be sent: the local copy must show the same (no silent truncation). */
    fun fitText(text: String): String = String(MessageBody.truncateUtf8(text, MAX_TEXT_BYTES), Charsets.UTF_8)

    fun sendPublic(text: String) = withRouter { r, me ->
        val sent = fitText(text)
        val packet = r.sendPublic(sent)
        _publicMessages.update { add(it, Message(packet.messageId.toHex(), me, r.nickname, sent, packet.timestamp, true, 0)) }
    }

    fun sendTeam(teamId: String, text: String) = withRouter { r, me ->
        advanceTeams()
        val channel = channels.firstOrNull { it.localId == teamId } ?: return@withRouter
        val sent = fitText(text)
        val packet = r.sendChannel(channel, sent) ?: return@withRouter
        val message = Message(packet.messageId.toHex(), me, r.nickname, sent, packet.timestamp, true, 0)
        _teamMessages.update { it + (teamId to add(it[teamId].orEmpty(), message)) }
    }

    fun sendDirect(peerId: String, text: String) = withRouter { r, me ->
        val key = knownKeys[peerId] ?: return@withRouter
        val sent = fitText(text)
        val packet = r.sendDirect(key, sent) ?: return@withRouter
        val message = Message(packet.messageId.toHex(), me, r.nickname, sent, packet.timestamp, true, 0)
        _directMessages.update { it + (peerId to add(it[peerId].orEmpty(), message)) }
    }

    /** A photo or voice note to a team (wire v3: phones on older versions won't see it). */
    fun sendTeamMedia(teamId: String, type: MediaType, data: ByteArray, durationMs: Int, width: Int, height: Int, caption: String) = withRouter { r, me ->
        advanceTeams()
        val channel = channels.firstOrNull { it.localId == teamId } ?: return@withRouter
        if (data.isEmpty() || data.size > type.maxBytes) return@withRouter
        val uid = MeshCrypto.randomBytes(ContactBody.UID_SIZE)
        val header = MediaHeader.create(type, data, durationMs, width, height, r.nickname, caption)
        if (!r.sendTeamMedia(channel, uid, header, data)) return@withRouter
        keepTeamMedia(uid.toHex(), data)
        val info = MediaInfo(type, durationMs, width, height, header.caption, header.chunkCount, header.chunkCount)
        val message = Message(uid.toHex(), me, r.nickname, "", System.currentTimeMillis(), true, 0, media = info)
        _teamMessages.update { it + (teamId to add(it[teamId].orEmpty(), message)) }
    }

    // ---- Wire v3: linked contacts ----

    /**
     * The seed to send to [binding] through SimpleX now (ack=false), if it isn't linked yet and wasn't
     * offered recently. Thread-safe.
     */
    fun linkOffer(binding: String): ContactLinks.Offer? {
        if (!::app.isInitialized) return null
        return synchronized(links) { links.offerFor(binding)?.also { store.saveLinks(links.toJson()) } }
    }

    /** The offer from [linkOffer] couldn't be sent: it is offered again on the next refresh. Thread-safe. */
    fun linkOfferFailed(binding: String) {
        if (!::app.isInitialized) return
        synchronized(links) {
            links.offerFailed(binding)
            store.saveLinks(links.toJson())
        }
    }

    /**
     * A seed from [binding]'s SimpleX chat. Returns the answer to send through SimpleX, if any; call
     * [linkAnswerSent] once it went out (until then it is in [unsentLinkAnswers]). Thread-safe.
     */
    fun onLinkMessage(binding: String, seed: ByteArray, day: Long, ack: Boolean): ContactLinks.Offer? {
        if (!::app.isInitialized) return null
        val reply = synchronized(links) {
            val before = links.channel(binding)
            val r = links.onReceived(binding, seed, day, ack)
            store.saveLinks(links.toJson())
            if (before != null && links.channel(binding) !== before) log("a contact re-linked for the mesh")
            r
        }
        contactsChanged()
        return reply
    }

    fun linkAnswerSent(binding: String) {
        if (!::app.isInitialized) return
        synchronized(links) {
            links.answerSent(binding)
            store.saveLinks(links.toJson())
        }
    }

    /** Answers to link offers whose sending failed: binding -> answer. Thread-safe. */
    fun unsentLinkAnswers(): List<Pair<String, ContactLinks.Offer>> =
        if (!::app.isInitialized) emptyList() else synchronized(links) { links.unsentAnswers() }

    fun isLinked(binding: String): Boolean = synchronized(links) { links.isLinked(binding) }

    /**
     * The current profile's contacts (binding -> name). Only these are recognised on the mesh, so a
     * hidden profile's contacts never are while it is hidden.
     */
    fun setDirectory(names: Map<String, String>) {
        if (names == directory) return
        directory = names
        contactsChanged()
    }

    /** A deleted chat profile ([prefix] = its bindings, "u<userId>:"), or all contacts if null (deleted database). */
    fun forgetContacts(prefix: String?) {
        if (!::app.isInitialized) return
        if (prefix != null) return retainContacts(prefix, emptySet())
        synchronized(links) {
            links.clear()
            store.deleteContacts()
        }
        _contactMessages.value = emptyMap()
        _unread.update { u -> u.filterKeys { !it.startsWith("contact:") } }
        lastSent.clear()
        mediaResends.clear()
        contactsChanged()
    }

    /** Forgets links and chats of contacts that no longer exist ([prefix] = one profile's bindings). */
    fun retainContacts(prefix: String, keep: Set<String>) {
        if (!::app.isInitialized) return
        val changed = synchronized(links) { links.retain(prefix, keep).also { if (it) store.saveLinks(links.toJson()) } }
        val gone = _contactMessages.value.keys.filter { it.startsWith(prefix) && it !in keep }
        if (gone.isNotEmpty()) {
            gone.forEach { id -> _contactMessages.value[id].orEmpty().forEach { m -> if (m.media != null) store.deleteMedia(m.id) } }
            _contactMessages.update { it - gone.toSet() }
            saveChatsSoon()
        }
        if (changed || gone.isNotEmpty()) contactsChanged()
    }

    fun contactName(contactId: String): String = directory[contactId] ?: contactId.substringAfterLast(':')

    fun sendContactText(contactId: String, text: String) {
        if (!::app.isInitialized || text.isBlank()) return
        val uid = MeshCrypto.randomBytes(ContactBody.UID_SIZE)
        val sent = fitText(text)
        val message = Message(uid.toHex(), "", "", sent, System.currentTimeMillis(), true, 0)
        _contactMessages.update { it + (contactId to add(it[contactId].orEmpty(), message)) }
        saveChatsSoon()
        thread.post {
            val r = router ?: return@post
            val channel = contactChannel(contactId) ?: return@post
            if (r.sendContact(channel, ContactBody.Kind.MESSAGE, uid, sent.toByteArray(Charsets.UTF_8)) != null) lastSent[message.id] = System.currentTimeMillis()
        }
    }

    fun sendContactMedia(contactId: String, type: MediaType, data: ByteArray, durationMs: Int, width: Int, height: Int, caption: String) {
        if (!::app.isInitialized || data.isEmpty() || data.size > type.maxBytes) return
        val uid = MeshCrypto.randomBytes(ContactBody.UID_SIZE)
        val uidHex = uid.toHex()
        val cut = String(MessageBody.truncateUtf8(caption, MediaHeader.MAX_CAPTION_BYTES), Charsets.UTF_8)
        val total = MediaHeader.chunksFor(data.size)
        thread.post {
            store.saveMedia(uidHex, data)
            val header = MediaHeader.create(type, data, durationMs, width, height, "", cut)
            val info = MediaInfo(type, durationMs, width, height, cut, total, total, header.mediaKey.toHex(), header.mediaId.toHex())
            val message = Message(uidHex, "", "", "", System.currentTimeMillis(), true, 0, media = info)
            _contactMessages.update { it + (contactId to add(it[contactId].orEmpty(), message)) }
            saveChatsSoon()
            val r = router ?: return@post
            val channel = contactChannel(contactId) ?: return@post
            if (r.sendContactMedia(channel, uid, header, data)) {
                lastSent[uidHex] = System.currentTimeMillis()
            }
        }
    }

    /** "Are you there?" Its answer marks the contact nearby (and sends anything waiting for it). */
    fun pingContact(contactId: String) = withRouter { r, _ ->
        contactChannel(contactId)?.let { r.pingContact(it) }
    }

    /** The bytes of a photo or voice note in any chat, or null if not (fully) here. Not on the main thread. */
    fun mediaData(messageId: String): ByteArray? = teamMedia[messageId] ?: if (::app.isInitialized) store.loadMedia(messageId) else null

    /** Undelivered texts to contacts, older than [minAgeMs] and younger than [OUTBOX_MS], not yet sent another way. */
    fun internetFallbacks(minAgeMs: Long): List<InternetFallback> {
        val now = System.currentTimeMillis()
        return _contactMessages.value.flatMap { (id, list) ->
            list.filter { it.isMine && !it.delivered && !it.viaInternet && it.media == null && now - it.timestamp in minAgeMs..OUTBOX_MS }
                .map { InternetFallback(id, it.id, it.text, it.timestamp) }
        }
    }

    fun markSentViaInternet(contactId: String, messageId: String) {
        updateContactMessage(contactId, messageId) { it.copy(viaInternet = true) }
        saveChatsSoon()
    }

    /** The linked pair of a contact of the current profile. */
    private fun contactChannel(contactId: String): ContactChannel? =
        if (contactId in directory) synchronized(links) { links.channel(contactId) } else null

    private fun activeContactChannels(): List<ContactChannel> = synchronized(links) {
        if (links.advance()) store.saveLinks(links.toJson())
        links.channels().filter { it.localId in directory }
    }

    private fun contactsChanged() {
        publishContacts()
        if (!::app.isInitialized) return
        thread.post { router?.setContacts(activeContactChannels()) }
    }

    private fun publishContacts() {
        val now = System.currentTimeMillis()
        val linked = synchronized(links) { links.linkedBindings() }
        _contacts.value = directory.filterKeys { it in linked }.map { (id, name) ->
            val n = nearby[id]?.takeIf { now - it.second < NEARBY_MS }
            LinkedContact(id, name, n?.first, nearby[id]?.second ?: 0L)
        }.sortedBy { it.name.lowercase() }
    }

    private fun keepTeamMedia(uidHex: String, data: ByteArray) {
        teamMedia[uidHex] = data
        var total = teamMedia.values.sumOf { it.size }
        val it = teamMedia.keys.iterator()
        while (total > MAX_TEAM_MEDIA_BYTES && it.hasNext()) {
            val k = it.next()
            if (k == uidHex) continue
            total -= teamMedia[k]?.size ?: 0
            it.remove()
        }
    }

    /** Mesh thread: sends again what [contactId] hasn't confirmed, now that it is in reach. */
    private fun resendPending(contactId: String) {
        val r = router ?: return
        val channel = contactChannel(contactId) ?: return
        val now = System.currentTimeMillis()
        for (m in _contactMessages.value[contactId].orEmpty()) {
            if (!m.isMine || m.delivered || m.viaInternet || now - m.timestamp > OUTBOX_MS) continue
            if (now - (lastSent[m.id] ?: 0L) < RESEND_EVERY_MS) continue
            val uid = hexToBytes(m.id) ?: continue
            val media = m.media
            if (media == null) {
                r.sendContact(channel, ContactBody.Kind.MESSAGE, uid, m.text.toByteArray(Charsets.UTF_8))
            } else {
                val tries = mediaResends[m.id] ?: 0
                if (lastSent.containsKey(m.id) && tries >= MAX_MEDIA_RESENDS) continue
                val data = store.loadMedia(m.id) ?: continue
                val header = resendHeader(media, data) ?: continue
                if (!r.sendContactMedia(channel, uid, header, data)) continue
                log(if (media.mediaKey != null) "resent a photo or voice note (same bytes)" else "resent a photo or voice note (new key)")
                if (lastSent.containsKey(m.id)) mediaResends[m.id] = tries + 1
            }
            lastSent[m.id] = now
        }
    }

    /**
     * The header of a resend: the same media key and ID as the first send, so every chunk encrypts to
     * the same bytes (and the contact's phone carries on with the chunks it already has). Items saved
     * before the key was kept get a fresh key and ID (a new key never reuses a nonce).
     */
    private fun resendHeader(media: MediaInfo, data: ByteArray): MediaHeader? {
        if (data.isEmpty() || data.size > media.type.maxBytes) return null
        val key = media.mediaKey?.let(::hexToBytes)
        val id = media.mediaId?.let(::hexToBytes)
        if (key == null || id == null || key.size != MeshCrypto.KEY_SIZE || id.size != MediaHeader.MEDIA_ID_SIZE) {
            return MediaHeader.create(media.type, data, media.durationMs, media.width, media.height, "", media.caption)
        }
        return MediaHeader(
            media.type, data.size, MediaHeader.chunksFor(data.size), MeshCrypto.sha256(data), key, id,
            media.durationMs, media.width, media.height, "", media.caption
        )
    }

    /** Whether a contact's message or photo / voice note is already here (asked by the router to spot replays). */
    private fun isKnownContactItem(contactId: String, uidHex: String): Boolean =
        _contactMessages.value[contactId].orEmpty().any { it.id == uidHex && !it.isMine && it.media?.complete != false }

    /** Mesh thread: pings contacts that something is waiting for (their answer triggers [resendPending]). */
    private fun pingPending(now: Long) {
        if (now - lastPendingPing < PENDING_PING_EVERY_MS) return
        lastPendingPing = now
        val r = router ?: return
        _contactMessages.value.forEach { (id, list) ->
            if (list.any { it.isMine && !it.delivered && !it.viaInternet && now - it.timestamp < OUTBOX_MS }) {
                contactChannel(id)?.let { r.pingContact(it) }
            }
        }
    }

    private fun updateContactMessage(contactId: String, messageId: String, f: (Message) -> Message) {
        _contactMessages.update { chats ->
            val list = chats[contactId] ?: return@update chats
            chats + (contactId to list.map { if (it.id == messageId) f(it) else it })
        }
    }

    private fun updateTeamMessage(teamId: String, messageId: String, f: (Message) -> Message) {
        _teamMessages.update { chats ->
            val list = chats[teamId] ?: return@update chats
            chats + (teamId to list.map { if (it.id == messageId) f(it) else it })
        }
    }

    private fun saveChatsSoon() {
        if (chatsSaveScheduled || !::app.isInitialized) return
        chatsSaveScheduled = true
        thread.schedule(1_000) {
            chatsSaveScheduled = false
            store.saveContactChats(chatsToJson(_contactMessages.value))
        }
    }

    private fun chatsToJson(chats: Map<String, List<Message>>): JSONObject {
        val o = JSONObject()
        chats.forEach { (id, list) ->
            val a = JSONArray()
            list.forEach { m ->
                val j = JSONObject().put("id", m.id).put("mine", m.isMine).put("text", m.text).put("ts", m.timestamp)
                    .put("hops", m.hops).put("dlv", m.delivered).put("net", m.viaInternet)
                m.media?.let { x ->
                    j.put("media", JSONObject().put("t", x.type.code).put("d", x.durationMs).put("w", x.width).put("h", x.height)
                        .put("c", x.caption).put("r", x.received).put("n", x.total)
                        .apply { if (x.mediaKey != null && x.mediaId != null) put("k", x.mediaKey).put("mid", x.mediaId) })
                }
                a.put(j)
            }
            o.put(id, a)
        }
        return o
    }

    private fun chatsFromJson(o: JSONObject): Map<String, List<Message>> {
        val out = HashMap<String, List<Message>>()
        o.keys().forEach { id ->
            try {
                val a = o.getJSONArray(id)
                out[id] = List(a.length()) { i ->
                    val j = a.getJSONObject(i)
                    val media = j.optJSONObject("media")?.let { x ->
                        MediaType.of(x.getInt("t"))?.let { t ->
                            MediaInfo(
                                t, x.getInt("d"), x.getInt("w"), x.getInt("h"), x.optString("c"), x.getInt("r"), x.getInt("n"),
                                x.optString("k").ifEmpty { null }, x.optString("mid").ifEmpty { null }
                            )
                        }
                    }
                    val mine = j.getBoolean("mine")
                    Message(
                        j.getString("id"), if (mine) "" else id, "", j.getString("text"), j.getLong("ts"), mine, j.optInt("hops"),
                        delivered = j.optBoolean("dlv"), media = media, viaInternet = j.optBoolean("net")
                    )
                }
            } catch (_: Exception) {
            }
        }
        return out
    }

    private fun hexToBytes(hex: String): ByteArray? =
        if (hex.length % 2 != 0) null else try { ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() } } catch (_: NumberFormatException) { null }

    private fun canonical(peerId: String): String = aliases[peerId] ?: peerId

    fun peerNickname(peerId: String): String =
        allPeers[peerId]?.nickname
            ?: _directMessages.value[peerId]?.lastOrNull { !it.isMine }?.nickname
            ?: peerId.take(8)

    fun canMessage(peerId: String): Boolean = knownKeys.containsKey(peerId)

    fun markRead(conversation: String) {
        _unread.update { it - conversation }
    }

    // ---- Teams ----

    /** Creates a team with a fresh random key; share it with [teamCode]. */
    fun createTeam(name: String): Team {
        val channel = TeamChannel.create(MessageBody.truncateChars(name.trim(), MAX_TEAM_NAME_CHARS).ifEmpty { "Team" }, System.currentTimeMillis())
        addChannel(channel)
        return Team(channel.localId, channel.name)
    }

    /**
     * Joins a team from its code: CFTEAM2.<key of that day>.<UTC day>.<name>. Returns the team (the
     * existing one if already joined), or null if the code is not valid.
     */
    fun joinTeam(code: String): Team? {
        val parts = code.trim().split('.')
        if (parts.size != 4 || parts[0] != TEAM_CODE_PREFIX) return null
        return try {
            val flags = Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
            val key = Base64.decode(parts[1], flags)
            val day = parts[2].toLong()
            val name = String(Base64.decode(parts[3], flags), Charsets.UTF_8)
            if (key.size != MeshCrypto.KEY_SIZE || day < 0) return null
            val channel = TeamChannel.fromCode(MessageBody.truncateChars(name, MAX_TEAM_NAME_CHARS).ifEmpty { "Team" }, key, day)
                .advancedTo(System.currentTimeMillis())
            channels.firstOrNull { it.sameTeamAs(channel) }?.let { return Team(it.localId, it.name) }
            addChannel(channel)
            Team(channel.localId, channel.name)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    @Synchronized
    fun leaveTeam(teamId: String) {
        channels = channels.filter { it.localId != teamId }
        store.saveChannels(channels)
        publishTeams()
        val current = channels
        // After the router stops decrypting for the team, so no message for it can slip back in.
        thread.post {
            router?.setChannels(current)
            _teamMessages.update { it - teamId }
            _unread.update { it - teamConversation(teamId) }
        }
    }

    /** The code to share, with today's key: whoever gets it can't read earlier days' messages. */
    fun teamCode(teamId: String): String? {
        advanceTeams()
        return channels.firstOrNull { it.localId == teamId }?.let(::teamCode)
    }

    private fun teamCode(channel: TeamChannel): String {
        val flags = Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
        return "$TEAM_CODE_PREFIX.${Base64.encodeToString(channel.key, flags)}.${channel.day}.${Base64.encodeToString(channel.name.toByteArray(), flags)}"
    }

    @Synchronized
    private fun addChannel(channel: TeamChannel) {
        if (channels.any { it.localId == channel.localId }) return
        channels = channels + channel
        store.saveChannels(channels)
        publishTeams()
        val current = channels
        thread.post { router?.setChannels(current) }
    }

    private fun publishTeams() {
        _teams.value = channels.map { Team(it.localId, it.name) }
    }

    /** Daily key ratchet: moves every team to today's key and forgets older ones. */
    @Synchronized
    private fun advanceTeams() {
        val now = System.currentTimeMillis()
        val current = channels
        val advanced = current.map { it.advancedTo(now) }
        if (advanced.indices.all { advanced[it] === current[it] }) return
        channels = advanced
        store.saveChannels(advanced)
        // Only while running (startEngine hands the teams to the router itself), so the mesh thread
        // isn't started just for this.
        if (identity != null) thread.post { router?.setChannels(advanced) }
    }

    // ---- Emergency wipe ----

    /** Part of ChatFort's emergency wipe: stops the mesh and erases identity, team keys and messages. */
    fun wipe() {
        if (!::app.isInitialized) return
        // Keys first, right away.
        store.wipe()
        synchronized(links) { links.clear() }
        channels = emptyList()
        _teams.value = emptyList()
        _contactMessages.value = emptyMap()
        _contacts.value = emptyList()
        teamMedia.clear()
        lastSent.clear()
        mediaResends.clear()
        CrowdMeshService.stop(app)
        // Then on the mesh thread, after anything already queued, so no event can put messages back.
        thread.post {
            shutDown()
            clearMessages()
            _contactMessages.value = emptyMap()
            _contacts.value = emptyList()
            _unread.value = emptyMap()
            _log.value = emptyList()
        }
        try { NotificationManagerCompat.from(app).cancel(MESSAGE_NOTIFICATION_ID) } catch (_: Exception) { }
        // A copied team code may still be on the clipboard.
        if (Build.VERSION.SDK_INT >= 28) {
            try { app.getSystemService(ClipboardManager::class.java)?.clearPrimaryClip() } catch (_: Exception) { }
        }
    }

    // ---- Internals (mesh thread) ----

    private fun withRouter(block: (MeshRouter, String) -> Unit) {
        thread.post {
            val r = router ?: return@post
            val me = identity?.peerIdHex ?: return@post
            block(r, me)
        }
    }

    private fun tick(s: Int) {
        if (s != session) return
        try {
            val now = System.currentTimeMillis()
            val b = ble
            _status.value = Status(running = true, linkedPhones = b?.activeLinks ?: 0, bluetoothOff = b?.isRunning != true)
            holdWakeLock()
            advanceTeams()
            if (synchronized(links) { links.advance().also { if (it) store.saveLinks(links.toJson()) } }) contactsChanged()
            router?.tick()
            val links = b?.activeLinks ?: 0
            if (links > lastLinkCount) lastPendingPing = 0L
            lastLinkCount = links
            pingPending(now)
            if (now - identitySince > IDENTITY_ROTATE_MS) rotateIdentity(now)
            if (now - lastAnnounce > ANNOUNCE_EVERY_MS) {
                router?.announce()
                lastAnnounce = now
            }
            publishPeers(now)
        } finally {
            thread.schedule(TICK_MS) { tick(s) }
        }
    }

    /**
     * New mesh identity (and Bluetooth token). People we have a private conversation with get an
     * encrypted handover signed by the old key, so the conversation carries on; to everyone else
     * this phone is a new, unrelated one.
     */
    private fun rotateIdentity(now: Long) {
        val r = router ?: return
        val next = MeshIdentity.generate()
        val partners = _directMessages.value.keys.mapNotNull { knownKeys[it] }
        r.rotateIdentity(next, partners)
        identity = next
        identitySince = now
        lastAnnounce = now
        ble?.rotateTokenNow()
        log("rotated mesh identity")
    }

    private fun onEvent(event: MeshEvent) {
        when (event) {
            is MeshEvent.Announce -> seenPeer(canonical(event.peerIdHex), event.nickname, event.publicKey, event.hops)
            is MeshEvent.Rekey -> {
                val id = canonical(event.peerIdHex)
                if (!event.isFromCurrentKey(knownKeys[id])) {
                    log("ignored a handover from an old or unknown key")
                    return
                }
                aliases[MeshCrypto.peerId(event.newKey).toHex()] = id
                knownKeys[id] = event.newKey
                log("a contact rotated its mesh identity")
            }
            is MeshEvent.Message -> {
                val peerId = canonical(event.peerIdHex)
                seenPeer(peerId, event.nickname, event.publicKey, event.hops)
                // A phone whose clock runs fast must not pin its messages below newer ones.
                val time = minOf(event.timestamp, System.currentTimeMillis())
                val message = Message(event.messageIdHex, peerId, event.nickname, event.text, time, false, event.hops)
                when (event.kind) {
                    MeshEvent.Kind.PUBLIC -> {
                        _publicMessages.update { add(it, message) }
                        arrived(PUBLIC_CONVERSATION, null)
                    }
                    MeshEvent.Kind.CHANNEL -> {
                        val teamId = event.channelIdHex ?: return
                        if (channels.none { it.localId == teamId }) return
                        _teamMessages.update { it + (teamId to add(it[teamId].orEmpty(), message)) }
                        arrived(teamConversation(teamId), app.getString(R.string.crowd_mesh_new_team_message))
                    }
                    MeshEvent.Kind.DIRECT -> {
                        _directMessages.update { it + (peerId to add(it[peerId].orEmpty(), message)) }
                        arrived(directConversation(peerId), app.getString(R.string.crowd_mesh_new_private_message))
                    }
                }
            }
            is MeshEvent.DirectAck -> _directMessages.update { chats ->
                val peerId = canonical(event.peerIdHex)
                val list = chats[peerId] ?: return@update chats
                chats + (peerId to list.map { if (it.id == event.ackedMessageIdHex) it.copy(delivered = true) else it })
            }
            is MeshEvent.ContactHeard -> {
                // Both phones hold the pair key: a kept link answer is no longer needed.
                synchronized(links) { if (links.confirmed(event.contactId)) store.saveLinks(links.toJson()) }
            }
            is MeshEvent.ContactNearby -> {
                nearby[event.contactId] = event.hops to System.currentTimeMillis()
                publishContacts()
                resendPending(event.contactId)
            }
            is MeshEvent.ContactMessage -> {
                val id = event.contactId
                val time = minOf(event.timestamp, System.currentTimeMillis())
                if (_contactMessages.value[id].orEmpty().any { it.id == event.uidHex && !it.isMine }) return
                val message = Message(event.uidHex, id, "", fitText(event.text), time, false, event.hops)
                _contactMessages.update { it + (id to add(it[id].orEmpty(), message)) }
                saveChatsSoon()
                arrived(contactConversation(id), app.getString(R.string.crowd_mesh_new_private_message))
            }
            is MeshEvent.ContactAck -> {
                updateContactMessage(event.contactId, event.uidHex) { it.copy(delivered = true) }
                saveChatsSoon()
            }
            is MeshEvent.MediaStarted -> {
                val info = MediaInfo(event.type, event.durationMs, event.width, event.height, event.caption, 0, event.chunkCount)
                val time = minOf(event.timestamp, System.currentTimeMillis())
                when (val c = event.conversation) {
                    is MediaConversation.Contact -> {
                        if (_contactMessages.value[c.contactId].orEmpty().any { it.id == event.uidHex }) return
                        val message = Message(event.uidHex, c.contactId, "", "", time, false, event.hops, media = info)
                        _contactMessages.update { it + (c.contactId to add(it[c.contactId].orEmpty(), message)) }
                    }
                    is MediaConversation.Team -> {
                        if (channels.none { it.localId == c.teamId }) return
                        if (_teamMessages.value[c.teamId].orEmpty().any { it.id == event.uidHex }) return
                        val peerId = canonical(c.senderPeerIdHex)
                        seenPeer(peerId, c.nickname, c.senderKey, event.hops)
                        val message = Message(event.uidHex, peerId, c.nickname, "", time, false, event.hops, media = info)
                        _teamMessages.update { it + (c.teamId to add(it[c.teamId].orEmpty(), message)) }
                    }
                }
            }
            is MeshEvent.MediaProgress -> when (val c = event.conversation) {
                is MediaConversation.Contact -> updateContactMessage(c.contactId, event.uidHex) { m ->
                    m.media?.takeIf { !it.complete }?.let { m.copy(media = it.copy(received = event.received)) } ?: m
                }
                is MediaConversation.Team -> updateTeamMessage(c.teamId, event.uidHex) { m ->
                    m.media?.takeIf { !it.complete }?.let { m.copy(media = it.copy(received = event.received)) } ?: m
                }
            }
            is MeshEvent.MediaReceived -> when (val c = event.conversation) {
                is MediaConversation.Contact -> {
                    val existing = _contactMessages.value[c.contactId].orEmpty().firstOrNull { it.id == event.uidHex }
                    if (existing?.media?.complete == true) return
                    store.saveMedia(event.uidHex, event.data)
                    updateContactMessage(c.contactId, event.uidHex) { m -> m.copy(media = m.media?.let { it.copy(received = it.total) }) }
                    saveChatsSoon()
                    arrived(contactConversation(c.contactId), app.getString(R.string.crowd_mesh_new_private_message))
                }
                is MediaConversation.Team -> {
                    if (channels.none { it.localId == c.teamId }) return
                    keepTeamMedia(event.uidHex, event.data)
                    updateTeamMessage(c.teamId, event.uidHex) { m -> m.copy(media = m.media?.let { it.copy(received = it.total) }) }
                    arrived(teamConversation(c.teamId), app.getString(R.string.crowd_mesh_new_team_message))
                }
            }
        }
    }

    private fun seenPeer(peerId: String, nickname: String, key: ByteArray, hops: Int) {
        // Only the contact's current identity sets its key: a late packet from a retired identity
        // (after a handover) must not roll it back. A new key only ever arrives by handover.
        val current = knownKeys[peerId]
        if (current == null || current.contentEquals(key)) knownKeys[peerId] = key
        allPeers[peerId] = Peer(peerId, nickname.ifBlank { peerId.take(8) }, hops, System.currentTimeMillis())
        publishPeers(System.currentTimeMillis())
    }

    private fun publishPeers(now: Long) {
        _peers.value = allPeers.values.filter { now - it.lastSeen < PEER_TIMEOUT_MS }.sortedBy { it.nickname.lowercase() }
    }

    private fun add(list: List<Message>, message: Message): List<Message> =
        if (list.any { it.id == message.id && it.peerId == message.peerId }) list
        else (list + message).sortedBy { it.timestamp }.takeLast(MAX_MESSAGES)

    /** Counts an unread message; [notification] null means no alert (the busy public feed). */
    private fun arrived(conversation: String, notification: String?) {
        if (visibleConversation == conversation) return
        _unread.update { it + (conversation to (it[conversation] ?: 0) + 1) }
        if (notification != null) notifyMessage(notification)
    }

    /** Keeps the CPU awake while relaying, so packets go on promptly with the screen off. */
    private fun holdWakeLock() {
        try {
            val lock = wakeLock ?: (app.getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ChatFort:CrowdMesh")
                .apply { setReferenceCounted(false) }
                .also { wakeLock = it }
            lock.acquire(WAKE_LOCK_MS)
        } catch (e: Exception) {
            Log.w(TAG, "wake lock unavailable: ${e.message}")
        }
    }

    private fun releaseWakeLock() {
        try { wakeLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) { }
    }

    /** Lock-screen safe: never shows who wrote or what they wrote. */
    private fun notifyMessage(text: String) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val manager = app.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(MESSAGES_CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(MESSAGES_CHANNEL, app.getString(R.string.crowd_mesh_messages_channel), NotificationManager.IMPORTANCE_HIGH))
        }
        val open = app.packageManager.getLaunchIntentForPackage(app.packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_OPEN_CROWD_MESH, true)
        }
        val notification = NotificationCompat.Builder(app, MESSAGES_CHANNEL)
            .setSmallIcon(R.drawable.ic_crowd_mesh)
            .setColor(0xFF1B1B1B.toInt()) // ChatFort: logo background, not the One UI default teal
            .setContentTitle(app.getString(R.string.crowd_mesh_title))
            .setContentText(text)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .apply {
                if (open != null) setContentIntent(PendingIntent.getActivity(app, 1, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            }
            .build()
        try { NotificationManagerCompat.from(app).notify(MESSAGE_NOTIFICATION_ID, notification) } catch (_: SecurityException) { }
    }

    private fun registerBluetoothReceiver() {
        if (bluetoothReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)
                thread.post {
                    val b = ble ?: return@post
                    when (state) {
                        BluetoothAdapter.STATE_ON -> if (!b.isRunning) b.start()
                        BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> b.stop()
                    }
                }
            }
        }
        ContextCompat.registerReceiver(app, receiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
        bluetoothReceiver = receiver
    }

    private fun unregisterBluetoothReceiver() {
        bluetoothReceiver?.let { try { app.unregisterReceiver(it) } catch (_: Exception) { } }
        bluetoothReceiver = null
    }

    private val timeFormat = SimpleDateFormat("HH:mm:ss", Locale.US)

    private fun log(line: String) {
        Log.i(TAG, line)
        _log.update { (it + "${timeFormat.format(Date())} $line").takeLast(200) }
    }

    /** Set on the launch intent by crowd mesh notifications. */
    const val EXTRA_OPEN_CROWD_MESH = "chatfort.open_crowd_mesh"
}
