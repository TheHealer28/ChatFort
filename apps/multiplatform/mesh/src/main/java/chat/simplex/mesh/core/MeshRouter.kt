package chat.simplex.mesh.core

import chat.simplex.mesh.protocol.ContactBody
import chat.simplex.mesh.protocol.ControlFrame
import chat.simplex.mesh.protocol.MediaChunk
import chat.simplex.mesh.protocol.MediaHeader
import chat.simplex.mesh.protocol.MediaType
import chat.simplex.mesh.protocol.MeshCrypto
import chat.simplex.mesh.protocol.MeshIdentity
import chat.simplex.mesh.protocol.MeshPacket
import chat.simplex.mesh.protocol.MessageBody
import chat.simplex.mesh.protocol.OpaquePacket
import chat.simplex.mesh.protocol.PacketType
import chat.simplex.mesh.protocol.SealedBody
import chat.simplex.mesh.protocol.toHex
import java.nio.ByteBuffer
import java.util.Random
import kotlin.math.abs

/** Sends whole frames to direct neighbours. Called on the mesh thread only. */
fun interface LinkSender {
    /** [bulk] frames are store-and-forward catch-up and may wait behind live traffic. */
    fun send(linkId: String, data: ByteArray, bulk: Boolean)
}

/** Link events delivered on the mesh thread. */
interface LinkListener {
    fun onLinkUp(linkId: String)
    fun onLinkDown(linkId: String)
    fun onData(linkId: String, data: ByteArray)
}

/** Runs a task on the mesh thread after a delay. */
fun interface MeshScheduler {
    fun schedule(delayMs: Long, task: () -> Unit)
}

/** Where a photo or voice note was sent. */
sealed class MediaConversation {
    /** From a linked contact ([ContactChannel.localId]). */
    data class Contact(val contactId: String) : MediaConversation()

    /** Posted to a team ([TeamChannel.localId]) by the sender inside the encryption. */
    data class Team(val teamId: String, val senderPeerIdHex: String, val senderKey: ByteArray, val nickname: String) : MediaConversation() {
        override fun equals(other: Any?): Boolean = other is Team && other.teamId == teamId && other.senderPeerIdHex == senderPeerIdHex
        override fun hashCode(): Int = teamId.hashCode() * 31 + senderPeerIdHex.hashCode()
    }
}

sealed class MeshEvent {
    /** The sender's mesh identity; empty for events about linked contacts (they have no visible identity). */
    open val peerIdHex: String get() = ""

    class Announce(override val peerIdHex: String, val publicKey: ByteArray, val nickname: String, val hops: Int) : MeshEvent()

    class Message(
        val kind: Kind,
        val messageIdHex: String,
        /** The sender's mesh identity (for sealed kinds, taken from inside the encryption). */
        override val peerIdHex: String,
        val publicKey: ByteArray,
        val nickname: String,
        val text: String,
        val timestamp: Long,
        /** Approximate: relays can make a packet look closer than it is. */
        val hops: Int,
        /** [TeamChannel.localId] for team messages. */
        val channelIdHex: String? = null
    ) : MeshEvent()

    class DirectAck(override val peerIdHex: String, val ackedMessageIdHex: String) : MeshEvent()

    /** [peerIdHex] now uses [newKey] (its mesh identity rotated). Proven by its old key's signature. */
    class Rekey(override val peerIdHex: String, val newKey: ByteArray) : MeshEvent() {
        /**
         * Accept only a handover signed by the contact's *current* key, so an old handover replayed
         * later (signed by a retired key) can't roll the contact back.
         */
        fun isFromCurrentKey(currentKey: ByteArray?): Boolean =
            currentKey != null && MeshCrypto.peerId(currentKey).toHex() == peerIdHex && !currentKey.contentEquals(newKey)
    }

    // ---- Wire v3: linked contacts ----

    /** A packet from a linked contact decrypted (possibly an old one replayed): both phones hold the pair key. */
    class ContactHeard(val contactId: String) : MeshEvent()

    /** A fresh packet from a linked contact arrived (at most [MeshRouter.FRESH_MS] old): it is in reach. */
    class ContactNearby(val contactId: String, val hops: Int) : MeshEvent()

    /** May repeat for resends of the same [uidHex]; the receiver shows it once. Already acknowledged. */
    class ContactMessage(val contactId: String, val uidHex: String, val text: String, val timestamp: Long, val hops: Int) : MeshEvent()

    class ContactAck(val contactId: String, val uidHex: String) : MeshEvent()

    // ---- Wire v3: photos and voice notes ----

    class MediaStarted(
        val conversation: MediaConversation,
        val uidHex: String,
        val type: MediaType,
        val chunkCount: Int,
        val durationMs: Int,
        val width: Int,
        val height: Int,
        val caption: String,
        val timestamp: Long,
        val hops: Int
    ) : MeshEvent()

    class MediaProgress(val conversation: MediaConversation, val uidHex: String, val received: Int, val total: Int) : MeshEvent()

    /** Complete and checked against the header's SHA-256. For contacts, already acknowledged. */
    class MediaReceived(
        val conversation: MediaConversation,
        val uidHex: String,
        val type: MediaType,
        val data: ByteArray,
        val durationMs: Int,
        val width: Int,
        val height: Int,
        val caption: String,
        val timestamp: Long,
        val hops: Int
    ) : MeshEvent()

    enum class Kind { PUBLIC, CHANNEL, DIRECT }
}

/**
 * ChatFort crowd mesh router (wire versions 2 and 3).
 *
 * Live packets are flooded: each phone relays a new packet once, after a short random delay, to
 * every neighbour that hasn't already sent it the same packet, until its hop limit runs out.
 * Neighbours also swap inventories of recent packet IDs (when they connect and every minute) and
 * pull what they are missing, so people who arrive late or were briefly cut off catch up.
 *
 * Every packet is signed. Announcements and public messages are signed by the sender's mesh
 * identity. Team, private and contact packets are "sealed": signed by a one-time key, with the real
 * sender (and for private messages, the recipient) only inside the encryption. Media chunks are
 * signed by one one-time key per photo or voice note.
 *
 * Not thread-safe: every call must happen on the mesh thread.
 */
class MeshRouter(
    identity: MeshIdentity,
    private val sender: LinkSender,
    private val scheduler: MeshScheduler,
    private val clock: () -> Long,
    private val onEvent: (MeshEvent) -> Unit,
    private val log: (String) -> Unit = {},
    private val random: Random = Random(),
    /** Whether a contact item (uid) was already received, e.g. before a restart (kept by the app). */
    private val knownUid: (contactId: String, uidHex: String) -> Boolean = { _, _ -> false }
) : LinkListener {

    companion object {
        const val ANNOUNCE_TTL = 3
        const val MESSAGE_TTL = MeshPacket.MAX_TTL
        const val SEEN_CAPACITY = 50_000
        const val STORE_CAPACITY = 300
        /** No single sender can fill the store and push everyone else's messages out. */
        const val STORE_PER_ORIGIN = 30
        const val STORE_MAX_AGE_MS = 60 * 60_000L
        // Wide windows, so phones with a wrong clock or time zone setting still get through.
        const val MAX_PACKET_AGE_MS = 6 * 60 * 60_000L
        const val MAX_CLOCK_SKEW_MS = 6 * 60 * 60_000L
        const val RELAY_JITTER_MIN_MS = 15L
        const val RELAY_JITTER_MAX_MS = 120L
        /** Live packets per sender identity (announcements, public messages). */
        const val ORIGIN_RATE_PER_MIN = 30.0
        /** Caught-up packets per sender identity: a backlog is allowed, an endless supply isn't. */
        const val CATCHUP_ORIGIN_RATE_PER_MIN = 60.0
        const val LINK_RATE_PER_MIN = 1200.0
        /** Sealed packets (team, private, contact) per link: their one-time signing keys can't be rate-limited per sender. */
        const val SEALED_LINK_RATE_PER_MIN = 240.0
        /** Packets from sender identities never seen before, per link: limits floods of throwaway identities. */
        const val NEW_ORIGIN_RATE_PER_MIN = 300.0
        /** Packets from newer app versions that can't be read here, per link. */
        const val OPAQUE_LINK_RATE_PER_MIN = 60.0
        const val SERVE_RATE_PER_MIN = 300.0
        const val MAX_REQUESTED = 200
        const val REQUEST_RETRY_MS = 10_000L
        const val RESYNC_EVERY_MS = 60_000L
        const val RESYNC_WINDOW_MS = 3 * 60_000L
        /** After rotating, the old identity still opens private messages sent to it for this long. */
        const val PREVIOUS_IDENTITY_MS = 15 * 60_000L
        private const val ANNOUNCE_FRESH_MS = 5 * 60_000L
        private val DIRECT_INFO = "chatfort-mesh-direct-v2".toByteArray()

        // ---- Wire v3 ----
        /** A contact answers "are you nearby?" at most this often. */
        const val PONG_EVERY_MS = 60_000L
        /**
         * Contact packets older (or newer) than this don't count as "nearby", get no PONG, and repeated
         * items get no ACK: a recorded packet replayed elsewhere must not reveal where the contact is.
         */
        const val FRESH_MS = 2 * 60_000L
        /**
         * v3 packets served to one link at most this often per window: v2 phones (iOS <= 1.6.3) relay
         * them unread without marking them seen, so they ask for the same IDs again every 10 s.
         */
        const val SERVE_V3_PER_WINDOW = 2
        const val SERVE_V3_WINDOW_MS = 10 * 60_000L
        /** Media chunks per link, and per item (its one-time key). */
        const val CHUNK_LINK_RATE_PER_MIN = 180.0
        const val MEDIA_ORIGIN_RATE_PER_MIN = 60.0
        /** Media chunks have their own store, so photos never push text messages out. */
        const val MEDIA_STORE_CAPACITY = 240
        const val MEDIA_STORE_PER_ORIGIN = MediaHeader.MAX_CHUNKS
        /** The sender spaces its chunks out, so text keeps flowing. */
        const val MEDIA_SEND_INTERVAL_MS = 100L
        /** Items being received at once, and how long an unfinished one waits for its chunks. */
        const val MAX_PENDING_MEDIA = 20
        const val PENDING_MEDIA_MS = 30 * 60_000L
        /** Chunks that arrive before their header (e.g. caught up out of order). */
        const val MAX_ORPHAN_ITEMS = 4
        const val MAX_ORPHAN_CHUNKS = 100
        const val ORPHAN_MS = 2 * 60_000L
    }

    var nickname: String = "anon"

    var identity: MeshIdentity = identity
        private set
    private var previousIdentity: MeshIdentity? = null
    private var previousIdentityUntil = 0L

    private val upLinks = LinkedHashSet<String>()
    /** Packets already handled, with the most hops-to-live we have had for each. */
    private val seen = boundedMap<Long, Int>(SEEN_CAPACITY)
    private class Stored(val packet: MeshPacket, val storedAt: Long, val originHex: String?)
    private val stored = LinkedHashMap<Long, Stored>()
    private val storedPerOrigin = HashMap<String, Int>()
    private val mediaStored = LinkedHashMap<Long, Stored>()
    private val mediaPerOrigin = HashMap<String, Int>()
    /** A relay waiting out its jitter, and the TTL each neighbour already holds the packet with. */
    private class PendingRelay(val holders: MutableMap<String, Int>)
    private val pendingRelays = HashMap<Long, PendingRelay>()
    /** Packet IDs we asked neighbours for, and when. */
    private val requested = boundedMap<Long, Long>(2_000)
    private var channels: List<TeamChannel> = emptyList()
    private var contacts: List<ContactChannel> = emptyList()
    /** Hour -> (pair tag -> contact), so each packet costs one lookup, not one HMAC per contact. */
    private val contactTags = boundedMap<Long, Map<Long, ContactChannel>>(16)
    private val lastPong = HashMap<String, Long>()
    /** "contactId:uid" of contact items already received (messages, complete media). */
    private val handledUids = boundedMap<String, Long>(5_000)
    /** "linkId:packetId" -> (times served in the window, window start), for v3 packets. */
    private val servedV3 = boundedMap<String, LongArray>(10_000)
    private class Bucket(var tokens: Double, var updatedAt: Long)
    private val originBuckets = HashMap<String, Bucket>()
    private val catchUpBuckets = HashMap<String, Bucket>()
    private val linkBuckets = HashMap<String, Bucket>()
    private val sealedBuckets = HashMap<String, Bucket>()
    private val newOriginBuckets = HashMap<String, Bucket>()
    private val opaqueBuckets = HashMap<String, Bucket>()
    private val serveBuckets = HashMap<String, Bucket>()
    private val chunkLinkBuckets = HashMap<String, Bucket>()
    private val mediaOriginBuckets = HashMap<String, Bucket>()
    /** Sender identities seen recently (for the new-identity limit). */
    private val knownOrigins = boundedMap<String, Long>(20_000)
    /** One-time keys of our own photos and voice notes, so their chunks coming back are ignored. */
    private val myMediaOrigins = boundedMap<String, Long>(200)

    private class PendingMedia(
        val conversation: MediaConversation,
        val uid: ByteArray,
        val header: MediaHeader,
        val chunkKey: ByteArray,
        val timestamp: Long,
        val hops: Int,
        val startedAt: Long
    ) {
        val chunks = arrayOfNulls<ByteArray>(header.chunkCount)
        var received = 0
    }
    private val pendingMedia = LinkedHashMap<Long, PendingMedia>()
    private class Orphan(val firstAt: Long, val packets: MutableList<MeshPacket> = mutableListOf())
    private val orphans = LinkedHashMap<Long, Orphan>()

    private var lastAnnounce: MeshPacket? = null
    private var lastResync = 0L
    /** Bumped by [clear] so relays scheduled before a wipe don't fire. */
    private var generation = 0

    val linkCount: Int get() = upLinks.size

    fun setChannels(list: Collection<TeamChannel>) {
        channels = list.toList()
    }

    /** Linked contacts (wire v3). Pass them already advanced to today. */
    fun setContacts(list: Collection<ContactChannel>) {
        contacts = list.toList()
        contactTags.clear()
    }

    /**
     * Switches to a new mesh identity. Everyone in [handoverTo] first gets an encrypted, old-key-signed
     * notice of the new key, so private conversations continue; nobody else can link the two identities
     * from the packets. The old identity keeps opening private messages for [PREVIOUS_IDENTITY_MS].
     * Linked contacts don't need a handover: their pair key doesn't depend on the identity.
     */
    fun rotateIdentity(next: MeshIdentity, handoverTo: Collection<ByteArray>) {
        handoverTo.forEach { sendSealedDirect(it, SealedBody.Kind.REKEY, next.publicKey) }
        previousIdentity = identity
        previousIdentityUntil = clock() + PREVIOUS_IDENTITY_MS
        identity = next
        announce()
    }

    // ---- Sending ----

    fun announce(): MeshPacket {
        val packet = MeshPacket.create(identity, PacketType.ANNOUNCE, ANNOUNCE_TTL, timestamp = clock()) {
            MessageBody.encode(nickname)
        }
        lastAnnounce = packet
        originate(packet)
        return packet
    }

    fun sendPublic(text: String): MeshPacket =
        MeshPacket.create(identity, PacketType.PUBLIC, MESSAGE_TTL, timestamp = clock()) {
            MessageBody.encode(nickname, text)
        }.also(::originate)

    /** Null if the team has no key for today (should not happen after [TeamChannel.advancedTo]). */
    fun sendChannel(channel: TeamChannel, text: String): MeshPacket? =
        sendSealedChannel(channel, SealedBody.Kind.MESSAGE, MessageBody.encode(nickname, text))

    private fun sendSealedChannel(channel: TeamChannel, kind: SealedBody.Kind, content: ByteArray): MeshPacket? {
        val now = clock()
        val target = channel.tag(now) ?: return null
        val key = channel.messageKey(now) ?: return null
        val messageId = MeshCrypto.randomBytes(MeshPacket.MESSAGE_ID_SIZE)
        val header = SealedBody.Header(PacketType.CHANNEL, messageId, now, target)
        val inner = SealedBody.seal(identity, kind, content, header, null)
        return MeshPacket.create(MeshIdentity.generate(), PacketType.CHANNEL, MESSAGE_TTL, target = target, timestamp = now, messageId = messageId) { aad ->
            MeshCrypto.seal(key, inner, aad)
        }.also(::originate)
    }

    /** Encrypts to [recipientKey], sealed sender. Null if the key is invalid. */
    fun sendDirect(recipientKey: ByteArray, text: String): MeshPacket? =
        sendSealedDirect(recipientKey, SealedBody.Kind.MESSAGE, MessageBody.encode(nickname, text))

    private fun sendSealedDirect(recipientKey: ByteArray, kind: SealedBody.Kind, content: ByteArray): MeshPacket? {
        val recipient = MeshCrypto.decodePublicKey(recipientKey) ?: return null
        val now = clock()
        val messageId = MeshCrypto.randomBytes(MeshPacket.MESSAGE_ID_SIZE)
        val header = SealedBody.Header(PacketType.DIRECT, messageId, now, MeshPacket.NO_TARGET)
        val inner = SealedBody.seal(identity, kind, content, header, recipientKey)
        return MeshPacket.create(MeshIdentity.generate(), PacketType.DIRECT, MESSAGE_TTL, timestamp = now, messageId = messageId) { aad ->
            val ephemeral = MeshCrypto.generateKeyPair()
            val ephemeralKey = MeshCrypto.encodePublicKey(ephemeral.public)
            val key = directKey(MeshCrypto.ecdh(ephemeral.private, recipient), ephemeralKey, recipientKey)
            ephemeralKey + MeshCrypto.seal(key, inner, aad)
        }.also(::originate)
    }

    /**
     * Wire v3: a packet to a linked contact. [uid] identifies the item across resends. Null if the
     * pair has no key yet (its first day hasn't come) or the content doesn't fit.
     */
    fun sendContact(contact: ContactChannel, kind: ContactBody.Kind, uid: ByteArray, content: ByteArray = ByteArray(0)): MeshPacket? {
        if (kind == ContactBody.Kind.MESSAGE && content.size > ContactBody.MAX_TEXT_BYTES) return null
        val now = clock()
        val target = contact.tag(now) ?: return null
        val key = contact.messageKey(now) ?: return null
        val plain = ContactBody.encode(kind, contact.role, uid, content)
        return MeshPacket.create(MeshIdentity.generate(), PacketType.CONTACT, MESSAGE_TTL, target = target, timestamp = now) { aad ->
            MeshCrypto.seal(key, plain, aad)
        }.also(::originate)
    }

    /** Wire v3: a photo or voice note to a linked contact. Its chunks follow, spaced out. */
    fun sendContactMedia(contact: ContactChannel, uid: ByteArray, header: MediaHeader, data: ByteArray): Boolean {
        sendContact(contact, ContactBody.Kind.MEDIA, uid, header.encode()) ?: return false
        sendChunks(header, data)
        return true
    }

    /** Wire v3: a photo or voice note to a team. v2 phones in the team won't see it. */
    fun sendTeamMedia(channel: TeamChannel, uid: ByteArray, header: MediaHeader, data: ByteArray): Boolean {
        sendSealedChannel(channel, SealedBody.Kind.MEDIA, uid + header.encode()) ?: return false
        sendChunks(header, data)
        return true
    }

    private fun sendChunks(header: MediaHeader, data: ByteArray) {
        require(data.size == header.totalSize)
        val mediaIdentity = MeshIdentity.generate()
        myMediaOrigins[mediaIdentity.peerIdHex] = clock()
        val chunkKey = MediaChunk.chunkKey(header.mediaKey)
        val gen = generation
        MediaChunk.split(data).forEachIndexed { i, chunk ->
            scheduler.schedule(i * MEDIA_SEND_INTERVAL_MS) {
                if (gen != generation) return@schedule
                val packet = MeshPacket.create(mediaIdentity, PacketType.MEDIA_CHUNK, MeshPacket.MEDIA_MAX_TTL, target = header.mediaId, timestamp = clock()) { _ ->
                    MediaChunk.seal(chunkKey, i, chunk, header.mediaId)
                }
                originate(packet)
            }
        }
    }

    private fun originate(packet: MeshPacket) {
        val now = clock()
        seen[packet.shortId] = packet.ttl
        when (packet.type) {
            PacketType.ANNOUNCE -> {}
            PacketType.MEDIA_CHUNK -> storeMedia(packet, now)
            else -> store(packet, now)
        }
        val bytes = packet.encode()
        val bulk = packet.type == PacketType.MEDIA_CHUNK
        upLinks.toList().forEach { sender.send(it, bytes, bulk) }
    }

    // ---- Link events ----

    override fun onLinkUp(linkId: String) {
        upLinks += linkId
        val now = clock()
        lastAnnounce?.let { if (now - it.timestamp < ANNOUNCE_FRESH_MS) sender.send(linkId, it.encode(), false) }
        prune(now)
        sendInventory(linkId, stored.keys.reversed() + mediaStored.keys.reversed())
    }

    override fun onLinkDown(linkId: String) {
        upLinks -= linkId
        linkBuckets.remove(linkId)
        sealedBuckets.remove(linkId)
        newOriginBuckets.remove(linkId)
        opaqueBuckets.remove(linkId)
        serveBuckets.remove(linkId)
        chunkLinkBuckets.remove(linkId)
    }

    override fun onData(linkId: String, data: ByteArray) {
        if (linkId !in upLinks) return
        if (ControlFrame.isControl(data)) {
            ControlFrame.decode(data)?.let { handleControl(linkId, it) }
            return
        }
        val packet = MeshPacket.decode(data)
        if (packet != null) {
            handlePacket(linkId, packet)
        } else {
            OpaquePacket.decode(data)?.let { handleOpaque(linkId, it) }
        }
    }

    /** Call every few seconds: drops expired packets and swaps recent packet IDs with neighbours. */
    fun tick() {
        val now = clock()
        prune(now)
        if (previousIdentity != null && now > previousIdentityUntil) previousIdentity = null
        if (now - lastResync < RESYNC_EVERY_MS) return
        lastResync = now
        val recent = stored.entries.filter { now - it.value.storedAt < RESYNC_WINDOW_MS }.map { it.key }.reversed() +
            mediaStored.entries.filter { now - it.value.storedAt < RESYNC_WINDOW_MS }.map { it.key }.reversed()
        if (recent.isEmpty()) return
        upLinks.toList().forEach { sendInventory(it, recent) }
    }

    /** Text packets come first, so a large photo can't crowd them out of the 512 IDs. */
    private fun sendInventory(linkId: String, newestFirst: List<Long>) {
        if (newestFirst.isEmpty()) return
        sender.send(linkId, ControlFrame.Inventory(newestFirst.take(ControlFrame.MAX_IDS)).encode(), false)
    }

    private fun handleControl(linkId: String, frame: ControlFrame) {
        val now = clock()
        when (frame) {
            is ControlFrame.Inventory -> {
                val missing = frame.ids.asSequence()
                    .filter { id -> !seen.containsKey(id) && (requested[id]?.let { now - it > REQUEST_RETRY_MS } ?: true) }
                    .take(MAX_REQUESTED)
                    .toList()
                if (missing.isEmpty()) return
                missing.forEach { requested[it] = now }
                sender.send(linkId, ControlFrame.Request(missing).encode(), false)
            }
            is ControlFrame.Request -> for (id in frame.ids.take(MAX_REQUESTED)) {
                val s = stored[id] ?: mediaStored[id] ?: continue
                val v3 = s.packet.type.version >= 3
                if (v3 && !mayServeV3(linkId, id, now)) continue
                if (!take(serveBuckets, linkId, SERVE_RATE_PER_MIN, now)) break
                if (v3) countServedV3(linkId, id, now)
                sender.send(linkId, s.packet.encode(), true)
            }
        }
    }

    private fun mayServeV3(linkId: String, id: Long, now: Long): Boolean {
        val e = servedV3["$linkId:$id"] ?: return true
        return now - e[1] > SERVE_V3_WINDOW_MS || e[0] < SERVE_V3_PER_WINDOW
    }

    private fun countServedV3(linkId: String, id: Long, now: Long) {
        val key = "$linkId:$id"
        val e = servedV3[key]
        if (e == null || now - e[1] > SERVE_V3_WINDOW_MS) servedV3[key] = longArrayOf(1, now) else e[0]++
    }

    /** Signed by a one-time key with the sender (if any) inside the encryption. */
    private fun isSealed(type: PacketType) = type == PacketType.CHANNEL || type == PacketType.DIRECT || type == PacketType.CONTACT

    private fun isMine(origin: ByteArray): Boolean =
        origin.contentEquals(identity.peerId) || previousIdentity?.peerId?.contentEquals(origin) == true

    private fun handlePacket(linkId: String, packet: MeshPacket) {
        val id = packet.shortId
        val now = clock()
        val best = seen[id]
        if (best != null) {
            requested.remove(id)
            // Duplicate: the neighbour holds it with one more hop than the copy it sent, so it
            // won't get it back unless our copy would give it more hops.
            pendingRelays[id]?.holders?.merge(linkId, packet.ttl + 1) { a, b -> maxOf(a, b) }
            if (packet.ttl > best && packet.ttl > 1) shorterRoute(linkId, packet, now)
            return
        }
        if (packet.timestamp < now - MAX_PACKET_AGE_MS || packet.timestamp > now + MAX_CLOCK_SKEW_MS) return
        if (!take(linkBuckets, linkId, LINK_RATE_PER_MIN, now)) return
        val sealed = isSealed(packet.type)
        val media = packet.type == PacketType.MEDIA_CHUNK
        val originHex = packet.origin.toHex()
        val mine = if (media) myMediaOrigins.containsKey(originHex) else !sealed && isMine(packet.origin)
        if (!mine) {
            when {
                sealed -> if (!take(sealedBuckets, linkId, SEALED_LINK_RATE_PER_MIN, now)) return
                media -> if (!take(chunkLinkBuckets, linkId, CHUNK_LINK_RATE_PER_MIN, now)) return
                !knownOrigins.containsKey(originHex) -> if (!take(newOriginBuckets, linkId, NEW_ORIGIN_RATE_PER_MIN, now)) return
            }
        }
        // Verify before marking seen, so forged copies can't block the genuine packet.
        if (!packet.verify()) {
            log("dropped a packet with an invalid signature")
            return
        }
        val caughtUp = requested.remove(id) != null
        val perOrigin = !sealed && !mine
        if (perOrigin && !media) knownOrigins[originHex] = now
        if (perOrigin && caughtUp) {
            val ok = if (media) take(mediaOriginBuckets, originHex, MEDIA_ORIGIN_RATE_PER_MIN, now)
            else take(catchUpBuckets, originHex, CATCHUP_ORIGIN_RATE_PER_MIN, now)
            if (!ok) {
                // Not marked seen: it can be pulled again on a later inventory swap, at a sustainable pace.
                log("rate limit: deferred catch-up from a phone with a large backlog")
                return
            }
        }
        val limited = perOrigin && !caughtUp && !(
            if (media) take(mediaOriginBuckets, originHex, MEDIA_ORIGIN_RATE_PER_MIN, now)
            else take(originBuckets, originHex, ORIGIN_RATE_PER_MIN, now))
        // Our own packets and rate-limited ones are never passed on, not even by a shorter route.
        seen[id] = if (mine || limited) Int.MAX_VALUE else packet.ttl
        if (mine) return
        if (limited) {
            log("rate limit: dropped a packet from a phone sending too fast")
            return
        }
        deliver(packet)
        // Out of hops: delivered here, but neither relayed nor kept for others.
        if (packet.ttl <= 1) return
        val forward = packet.relayed()
        keep(forward, now)
        // Live packets go straight on. Caught-up ones spread through the next inventory swap instead,
        // so a reconnect doesn't re-flood neighbours that mostly have them already.
        if (!caughtUp) scheduleRelay(linkId, packet.ttl + 1, forward)
    }

    private fun keep(packet: MeshPacket, now: Long) {
        when (packet.type) {
            PacketType.ANNOUNCE -> {}
            PacketType.MEDIA_CHUNK -> storeMedia(packet, now)
            else -> store(packet, now)
        }
    }

    /**
     * The same packet again, by a shorter route and with more hops to live. Flooding can deliver the
     * long way round first, so pass it on again (without showing it twice) or phones near the edge
     * of the hop limit would miss it.
     */
    private fun shorterRoute(linkId: String, packet: MeshPacket, now: Long) {
        if (!take(linkBuckets, linkId, LINK_RATE_PER_MIN, now) || !packet.verify()) return
        seen[packet.shortId] = packet.ttl
        val forward = packet.relayed()
        keep(forward, now)
        scheduleRelay(linkId, packet.ttl + 1, forward)
    }

    /** Relays [packet] after a random delay to neighbours that don't hold it with as many hops left. */
    private fun scheduleRelay(from: String, fromHolds: Int, packet: MeshPacket) {
        val id = packet.shortId
        // A newer relay for the same packet supersedes one still waiting; keep what it learned.
        val holders = HashMap(pendingRelays[id]?.holders.orEmpty())
        holders.merge(from, fromHolds) { a, b -> maxOf(a, b) }
        val pending = PendingRelay(holders)
        pendingRelays[id] = pending
        val gen = generation
        val bulk = packet.type == PacketType.MEDIA_CHUNK
        scheduler.schedule(jitter()) {
            if (gen != generation || pendingRelays[id] !== pending) return@schedule
            pendingRelays.remove(id)
            val bytes = packet.encode()
            upLinks.filter { (pending.holders[it] ?: 0) < packet.ttl }.forEach { sender.send(it, bytes, bulk) }
        }
    }

    private fun jitter(): Long =
        RELAY_JITTER_MIN_MS + random.nextInt((RELAY_JITTER_MAX_MS - RELAY_JITTER_MIN_MS).toInt() + 1)

    /** A packet from a newer app version: pass it on, unread, so newer phones stay connected through us. */
    private fun handleOpaque(linkId: String, packet: OpaquePacket) {
        val id = packet.shortId
        val now = clock()
        if (seen.containsKey(id)) return
        if (!take(linkBuckets, linkId, LINK_RATE_PER_MIN, now) || !take(opaqueBuckets, linkId, OPAQUE_LINK_RATE_PER_MIN, now)) return
        seen[id] = packet.ttl
        if (packet.ttl <= 1) return
        val bytes = packet.relayed()
        val gen = generation
        scheduler.schedule(jitter()) {
            if (gen != generation) return@schedule
            upLinks.filter { it != linkId }.forEach { sender.send(it, bytes, false) }
        }
    }

    private fun deliver(packet: MeshPacket) {
        when (packet.type) {
            PacketType.ANNOUNCE -> MessageBody.decode(packet.payload)?.let { (nick, _) ->
                onEvent(MeshEvent.Announce(packet.origin.toHex(), packet.originKey, nick, packet.hops + 1))
            }
            PacketType.PUBLIC -> MessageBody.decode(packet.payload)?.let { (nick, text) ->
                onEvent(message(MeshEvent.Kind.PUBLIC, packet, packet.originKey, nick, text))
            }
            PacketType.CHANNEL -> deliverChannel(packet)
            PacketType.DIRECT -> deliverDirect(packet)
            PacketType.CONTACT -> deliverContact(packet)
            PacketType.MEDIA_CHUNK -> deliverChunk(packet)
        }
    }

    private fun deliverChannel(packet: MeshPacket) {
        val channel = channels.firstOrNull { it.tag(packet.timestamp)?.contentEquals(packet.target) == true } ?: return
        val key = channel.messageKey(packet.timestamp) ?: return
        val plain = MeshCrypto.open(key, packet.payload, packet.aad()) ?: return
        val header = SealedBody.Header(packet.type, packet.messageId, packet.timestamp, packet.target)
        val opened = SealedBody.open(plain, header, null) ?: return
        if (isMine(opened.senderPeerId)) return
        when (opened.kind) {
            SealedBody.Kind.MESSAGE -> MessageBody.decode(opened.content)?.let { (nick, text) ->
                onEvent(message(MeshEvent.Kind.CHANNEL, packet, opened.senderKey, nick, text, channel.localId))
            }
            SealedBody.Kind.MEDIA -> {
                val c = opened.content
                if (c.size <= ContactBody.UID_SIZE) return
                val media = MediaHeader.decode(c.copyOfRange(ContactBody.UID_SIZE, c.size)) ?: return
                val from = MediaConversation.Team(channel.localId, opened.senderPeerId.toHex(), opened.senderKey, media.nickname)
                startMedia(from, c.copyOf(ContactBody.UID_SIZE), media, packet)
            }
            else -> {}
        }
    }

    private fun deliverDirect(packet: MeshPacket) {
        val header = SealedBody.Header(packet.type, packet.messageId, packet.timestamp, packet.target)
        val me = listOfNotNull(identity, previousIdentity)
        val (opened, _) = me.firstNotNullOfOrNull { id ->
            decryptDirect(packet, id)?.let { SealedBody.open(it, header, id.publicKey) }?.let { it to id }
        } ?: return
        if (isMine(opened.senderPeerId)) return
        val from = opened.senderPeerId.toHex()
        when (opened.kind) {
            SealedBody.Kind.MESSAGE -> MessageBody.decode(opened.content)?.let { (nick, text) ->
                onEvent(message(MeshEvent.Kind.DIRECT, packet, opened.senderKey, nick, text))
                sendSealedDirect(opened.senderKey, SealedBody.Kind.ACK, packet.messageId)
            }
            SealedBody.Kind.ACK -> if (opened.content.size == MeshPacket.MESSAGE_ID_SIZE) {
                onEvent(MeshEvent.DirectAck(from, opened.content.toHex()))
            }
            SealedBody.Kind.REKEY -> if (MeshCrypto.decodePublicKey(opened.content) != null) {
                onEvent(MeshEvent.Rekey(from, opened.content))
            }
            // Media goes to linked contacts and teams only, never to strangers.
            SealedBody.Kind.MEDIA -> {}
        }
    }

    private fun message(kind: MeshEvent.Kind, packet: MeshPacket, senderKey: ByteArray, nick: String, text: String, channel: String? = null) =
        MeshEvent.Message(kind, packet.messageId.toHex(), MeshCrypto.peerId(senderKey).toHex(), senderKey, nick, text, packet.timestamp, packet.hops + 1, channel)

    private fun decryptDirect(packet: MeshPacket, me: MeshIdentity): ByteArray? {
        val p = packet.payload
        if (p.size < MeshCrypto.PUBLIC_KEY_SIZE + MeshCrypto.NONCE_SIZE + 16) return null
        val ephemeralKey = p.copyOfRange(0, MeshCrypto.PUBLIC_KEY_SIZE)
        val ephemeral = MeshCrypto.decodePublicKey(ephemeralKey) ?: return null
        val key = directKey(MeshCrypto.ecdh(me.privateKey, ephemeral), ephemeralKey, me.publicKey)
        return MeshCrypto.open(key, p.copyOfRange(MeshCrypto.PUBLIC_KEY_SIZE, p.size), packet.aad())
    }

    private fun directKey(shared: ByteArray, ephemeralKey: ByteArray, recipientKey: ByteArray): ByteArray =
        MeshCrypto.hkdf(shared, ephemeralKey + recipientKey, DIRECT_INFO, MeshCrypto.KEY_SIZE)

    // ---- Wire v3: linked contacts ----

    private fun contactFor(target: ByteArray, timestamp: Long): ContactChannel? {
        if (contacts.isEmpty()) return null
        val hour = Math.floorDiv(timestamp, TeamChannel.HOUR_MS)
        val tags = contactTags.getOrPut(hour) {
            val at = hour * TeamChannel.HOUR_MS
            HashMap<Long, ContactChannel>().also { m -> contacts.forEach { c -> c.tag(at)?.let { m[longOf(it)] = c } } }
        }
        return tags[longOf(target)]
    }

    private fun deliverContact(packet: MeshPacket) {
        val contact = contactFor(packet.target, packet.timestamp) ?: return
        val key = contact.messageKey(packet.timestamp) ?: return
        val plain = MeshCrypto.open(key, packet.payload, packet.aad()) ?: return
        val body = ContactBody.decode(plain) ?: return
        // Our own packet reflected back (only the two of us hold the key).
        if (body.role == contact.role) return
        val now = clock()
        val hops = packet.hops + 1
        val id = contact.localId
        val uidHex = body.uid.toHex()
        onEvent(MeshEvent.ContactHeard(id))
        // Only a fresh packet shows the contact is in reach or gets an answer: someone who recorded a
        // contact's packet must not be able to replay it elsewhere to find out whether it is nearby.
        val fresh = abs(now - packet.timestamp) <= FRESH_MS
        if (fresh) onEvent(MeshEvent.ContactNearby(id, hops))
        when (body.kind) {
            ContactBody.Kind.MESSAGE -> {
                val repeat = isRepeat(id, uidHex)
                onEvent(MeshEvent.ContactMessage(id, uidHex, String(body.content, Charsets.UTF_8), packet.timestamp, hops))
                handledUids["$id:$uidHex"] = now
                // A new item is acknowledged at any age (store-and-forward); a repeated one only if fresh.
                if (!repeat || fresh) sendContact(contact, ContactBody.Kind.ACK, body.uid)
            }
            ContactBody.Kind.ACK -> onEvent(MeshEvent.ContactAck(id, uidHex))
            ContactBody.Kind.PING -> if (fresh && now - (lastPong[id] ?: 0L) >= PONG_EVERY_MS) {
                lastPong[id] = now
                sendContact(contact, ContactBody.Kind.PONG, body.uid)
            }
            ContactBody.Kind.PONG -> {}
            ContactBody.Kind.MEDIA -> MediaHeader.decode(body.content)?.let { header ->
                if (isRepeat(id, uidHex)) {
                    // Already here: just confirm it again, if this resend is fresh.
                    if (fresh) sendContact(contact, ContactBody.Kind.ACK, body.uid)
                } else {
                    startMedia(MediaConversation.Contact(id), body.uid, header, packet)
                }
            }
        }
    }

    private fun isRepeat(contactId: String, uidHex: String): Boolean =
        handledUids.containsKey("$contactId:$uidHex") || knownUid(contactId, uidHex)

    /** Pings a linked contact; it answers if it is in reach (see [MeshEvent.ContactNearby]). */
    fun pingContact(contact: ContactChannel): MeshPacket? =
        sendContact(contact, ContactBody.Kind.PING, MeshCrypto.randomBytes(ContactBody.UID_SIZE))

    // ---- Wire v3: receiving photos and voice notes ----

    private fun startMedia(from: MediaConversation, uid: ByteArray, header: MediaHeader, packet: MeshPacket) {
        val mediaId = longOf(header.mediaId)
        if (pendingMedia.containsKey(mediaId)) return
        val now = clock()
        while (pendingMedia.size >= MAX_PENDING_MEDIA) pendingMedia.remove(pendingMedia.keys.first())
        val pending = PendingMedia(from, uid, header, MediaChunk.chunkKey(header.mediaKey), packet.timestamp, packet.hops + 1, now)
        pendingMedia[mediaId] = pending
        onEvent(
            MeshEvent.MediaStarted(
                from, uid.toHex(), header.type, header.chunkCount, header.durationMs, header.width, header.height,
                header.caption, packet.timestamp, packet.hops + 1
            )
        )
        // Chunks that got here before the header.
        orphans.remove(mediaId)?.packets?.forEach { addChunk(mediaId, pending, it) }
    }

    private fun deliverChunk(packet: MeshPacket) {
        val mediaId = longOf(packet.target)
        val pending = pendingMedia[mediaId]
        if (pending != null) {
            addChunk(mediaId, pending, packet)
            return
        }
        // Most chunks on the mesh are other people's: keep only a few, briefly, in case their header follows.
        val now = clock()
        val orphan = orphans[mediaId] ?: run {
            if (orphans.size >= MAX_ORPHAN_ITEMS) orphans.remove(orphans.keys.first())
            Orphan(now).also { orphans[mediaId] = it }
        }
        if (orphans.values.sumOf { it.packets.size } < MAX_ORPHAN_CHUNKS) orphan.packets += packet
    }

    private fun addChunk(mediaId: Long, pending: PendingMedia, packet: MeshPacket) {
        val header = pending.header
        val index = MediaChunk.indexOf(packet.payload)
        if (index !in 0 until header.chunkCount || pending.chunks[index] != null) return
        val data = MediaChunk.open(pending.chunkKey, packet.payload, pending.header.mediaId) ?: return
        val expected = minOf(MediaHeader.CHUNK_SIZE, header.totalSize - index * MediaHeader.CHUNK_SIZE)
        if (data.size != expected) return
        pending.chunks[index] = data
        pending.received++
        val uidHex = pending.uid.toHex()
        if (pending.received < header.chunkCount) {
            onEvent(MeshEvent.MediaProgress(pending.conversation, uidHex, pending.received, header.chunkCount))
            return
        }
        pendingMedia.remove(mediaId)
        val all = ByteBuffer.allocate(header.totalSize).also { b -> pending.chunks.forEach { b.put(it!!) } }.array()
        if (!MeshCrypto.sha256(all).contentEquals(header.sha256)) {
            log("dropped a photo or voice note that didn't match its checksum")
            return
        }
        onEvent(
            MeshEvent.MediaReceived(
                pending.conversation, uidHex, header.type, all, header.durationMs, header.width, header.height,
                header.caption, pending.timestamp, pending.hops
            )
        )
        val c = pending.conversation
        if (c is MediaConversation.Contact) {
            handledUids["${c.contactId}:$uidHex"] = clock()
            contacts.firstOrNull { it.localId == c.contactId }?.let { sendContact(it, ContactBody.Kind.ACK, pending.uid) }
        }
    }

    private fun longOf(bytes: ByteArray): Long = ByteBuffer.wrap(bytes, 0, 8).long

    // ---- Store-and-forward ----

    private fun store(packet: MeshPacket, now: Long) {
        val originHex = if (isSealed(packet.type)) null else packet.origin.toHex()
        if (originHex != null && !isMine(packet.origin) && (storedPerOrigin[originHex] ?: 0) >= STORE_PER_ORIGIN && !stored.containsKey(packet.shortId)) return
        removeStored(packet.shortId)
        stored[packet.shortId] = Stored(packet, now, originHex)
        if (originHex != null) storedPerOrigin.merge(originHex, 1, Int::plus)
        prune(now)
    }

    private fun removeStored(id: Long) {
        val s = stored.remove(id) ?: return
        s.originHex?.let { o -> storedPerOrigin.computeIfPresent(o) { _, n -> if (n <= 1) null else n - 1 } }
    }

    private fun storeMedia(packet: MeshPacket, now: Long) {
        val originHex = packet.origin.toHex()
        if ((mediaPerOrigin[originHex] ?: 0) >= MEDIA_STORE_PER_ORIGIN && !mediaStored.containsKey(packet.shortId)) return
        removeMedia(packet.shortId)
        mediaStored[packet.shortId] = Stored(packet, now, originHex)
        mediaPerOrigin.merge(originHex, 1, Int::plus)
        prune(now)
    }

    private fun removeMedia(id: Long) {
        val s = mediaStored.remove(id) ?: return
        s.originHex?.let { o -> mediaPerOrigin.computeIfPresent(o) { _, n -> if (n <= 1) null else n - 1 } }
    }

    private fun prune(now: Long) {
        while (true) {
            val (id, s) = stored.entries.firstOrNull() ?: break
            if (stored.size > STORE_CAPACITY || now - s.storedAt > STORE_MAX_AGE_MS) removeStored(id) else break
        }
        while (true) {
            val (id, s) = mediaStored.entries.firstOrNull() ?: break
            if (mediaStored.size > MEDIA_STORE_CAPACITY || now - s.storedAt > STORE_MAX_AGE_MS) removeMedia(id) else break
        }
        orphans.entries.removeAll { now - it.value.firstAt > ORPHAN_MS }
        pendingMedia.entries.removeAll { now - it.value.startedAt > PENDING_MEDIA_MS }
    }

    /** Forget everything (emergency wipe / stop). */
    fun clear() {
        generation++
        upLinks.clear()
        seen.clear()
        stored.clear()
        storedPerOrigin.clear()
        mediaStored.clear()
        mediaPerOrigin.clear()
        pendingRelays.clear()
        requested.clear()
        originBuckets.clear()
        catchUpBuckets.clear()
        linkBuckets.clear()
        sealedBuckets.clear()
        newOriginBuckets.clear()
        opaqueBuckets.clear()
        serveBuckets.clear()
        chunkLinkBuckets.clear()
        mediaOriginBuckets.clear()
        knownOrigins.clear()
        myMediaOrigins.clear()
        channels = emptyList()
        contacts = emptyList()
        contactTags.clear()
        lastPong.clear()
        handledUids.clear()
        servedV3.clear()
        pendingMedia.clear()
        orphans.clear()
        previousIdentity = null
        lastAnnounce = null
    }

    // ---- Rate limiting (token buckets) ----

    private fun take(buckets: HashMap<String, Bucket>, key: String, perMinute: Double, now: Long): Boolean {
        val b = buckets.getOrPut(key) { Bucket(perMinute, now) }
        b.tokens = minOf(perMinute, b.tokens + (now - b.updatedAt) * perMinute / 60_000.0)
        b.updatedAt = now
        if (b.tokens < 1.0) return false
        b.tokens -= 1.0
        if (buckets.size > 5_000) buckets.keys.firstOrNull { it != key }?.let { buckets.remove(it) }
        return true
    }

    private fun <K, V> boundedMap(capacity: Int): LinkedHashMap<K, V> = object : LinkedHashMap<K, V>(1024, 0.75f, false) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?): Boolean = size > capacity
    }
}
