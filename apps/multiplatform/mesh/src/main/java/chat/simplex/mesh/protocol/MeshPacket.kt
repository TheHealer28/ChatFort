package chat.simplex.mesh.protocol

import java.nio.ByteBuffer

/** [version]: the wire version packets of this type are sent with (v2 types stay v2 so v2 phones read them). */
enum class PacketType(val code: Int, val version: Int) {
    /** Nickname + key, flooded a few hops so people nearby can see and message each other. */
    ANNOUNCE(1, 2),
    /** Public crowd message, readable by everyone on the mesh. Signed by the sender's mesh identity. */
    PUBLIC(2, 2),
    /**
     * Team channel message. target = hourly channel tag. Sealed: signed by a one-time key, and the real
     * sender (key + signature) is inside the encryption, so relays can't see who posts to which team.
     */
    CHANNEL(3, 2),
    /**
     * Private message, delivery receipt or identity handover (see [SealedBody.Kind]). Sealed: no target,
     * signed by a one-time key, sender inside the encryption. Relays see neither sender nor recipient.
     */
    DIRECT(4, 2),
    /**
     * Wire v3. Message between two linked ChatFort contacts (pair key swapped over SimpleX, see
     * [chat.simplex.mesh.core.ContactChannel]). target = hourly pair tag, signed by a one-time key,
     * payload = [ContactBody] encrypted with the pair's day key.
     */
    CONTACT(5, 3),
    /**
     * Wire v3. One chunk of a photo or voice note ([MediaChunk]). target = the item's random media ID;
     * all chunks of an item are signed by one one-time key, so relays can rate-limit per item.
     */
    MEDIA_CHUNK(6, 3);

    companion object {
        fun of(code: Int): PacketType? = entries.firstOrNull { it.code == code }
    }
}

/**
 * A signed mesh packet (wire version 2, or 3 for the v3 types; the layout is the same and the version
 * byte comes from [PacketType.version]). Relays may only decrement [ttl]; everything else, including
 * the origin's original hop limit [maxTtl] and [flags], is covered by the origin's ECDSA signature.
 * [hops] is derived (maxTtl - ttl), so a relay can't make a packet travel further than its sender
 * allowed, and can only make it look closer by also cutting its remaining range.
 *
 * Wire format (big-endian):
 * magic 'C' | version | type | ttl | maxTtl | flags | messageId(16) | origin(8) | timestamp(8) |
 * target(8) | originKey(65) | payloadLength(2) | payload | signatureLength(1) | signature
 *
 * Forward compatibility: every future version keeps the first five bytes (magic, version, type < 0x80,
 * ttl, maxTtl) and lets relays change only ttl, so this version can relay packets it can't read
 * ([OpaquePacket]).
 */
class MeshPacket(
    val type: PacketType,
    val ttl: Int,
    val maxTtl: Int,
    val flags: Int,
    val messageId: ByteArray,
    val origin: ByteArray,
    val timestamp: Long,
    val target: ByteArray,
    val originKey: ByteArray,
    val payload: ByteArray,
    val signature: ByteArray
) {
    /** Hops travelled so far (0 at the origin). Not proof of distance: a relay can re-send a packet as if fresh. */
    val hops: Int get() = maxTtl - ttl

    /**
     * Dedup key. v2: bound to the origin, so nobody can pre-empt someone else's message by reusing its ID.
     * v3: the hash v2 phones use when relaying it unread ([OpaquePacket.idOf]), so dedup and inventories
     * agree across versions; it covers the signature, so it can't be pre-empted either.
     */
    val shortId: Long by lazy(LazyThreadSafetyMode.NONE) {
        if (type.version == 2) shortIdOf(origin, messageId) else OpaquePacket.idOf(encode())
    }

    fun relayed(): MeshPacket =
        MeshPacket(type, ttl - 1, maxTtl, flags, messageId, origin, timestamp, target, originKey, payload, signature)

    fun encode(): ByteArray {
        val body = body(ttl)
        return ByteBuffer.allocate(body.size + 1 + signature.size)
            .put(body).put(signature.size.toByte()).put(signature).array()
    }

    /** Bytes covered by the signature: the packet with ttl zeroed, without the signature. */
    fun signedBytes(): ByteArray = body(0)

    /** Additional authenticated data for encrypted payloads: binds ciphertext to this packet's header. */
    fun aad(): ByteArray = aadOf(type, messageId, origin, timestamp, target)

    /** True if the origin matches the key and the signature is valid. */
    fun verify(): Boolean {
        if (!origin.contentEquals(MeshCrypto.peerId(originKey))) return false
        val key = MeshCrypto.decodePublicKey(originKey) ?: return false
        return MeshCrypto.verify(key, signedBytes(), signature)
    }

    private fun body(ttlValue: Int): ByteArray =
        ByteBuffer.allocate(HEADER_SIZE + payload.size)
            .put(MAGIC.toByte()).put(type.version.toByte()).put(type.code.toByte())
            .put(ttlValue.toByte()).put(maxTtl.toByte()).put(flags.toByte())
            .put(messageId).put(origin).putLong(timestamp).put(target).put(originKey)
            .putShort(payload.size.toShort()).put(payload)
            .array()

    companion object {
        const val MAGIC = 0x43 // 'C'
        /** Version of control frames and of the v2 packet types. */
        const val VERSION = 2
        /** Highest packet version this phone reads; newer ones are relayed unread. */
        const val MAX_READ_VERSION = 3
        const val MAX_TTL = 7
        /** Media chunks travel at most this far, to spare crowded meshes. */
        const val MEDIA_MAX_TTL = 5
        const val MESSAGE_ID_SIZE = 16
        const val TARGET_SIZE = 8
        const val MAX_PAYLOAD = 2048
        const val MAX_SIGNATURE = 80
        const val HEADER_SIZE = 6 + MESSAGE_ID_SIZE + MeshCrypto.PEER_ID_SIZE + 8 + TARGET_SIZE + MeshCrypto.PUBLIC_KEY_SIZE + 2
        val NO_TARGET = ByteArray(TARGET_SIZE)

        fun create(
            identity: MeshIdentity,
            type: PacketType,
            ttl: Int,
            target: ByteArray = NO_TARGET,
            timestamp: Long = System.currentTimeMillis(),
            messageId: ByteArray = MeshCrypto.randomBytes(MESSAGE_ID_SIZE),
            flags: Int = 0,
            payloadFor: (aad: ByteArray) -> ByteArray
        ): MeshPacket {
            require(target.size == TARGET_SIZE && ttl in 1..maxTtlOf(type) && flags in 0..0xff)
            val payload = payloadFor(aadOf(type, messageId, identity.peerId, timestamp, target))
            require(payload.size <= MAX_PAYLOAD)
            val unsigned = MeshPacket(type, ttl, ttl, flags, messageId, identity.peerId, timestamp, target, identity.publicKey, payload, ByteArray(0))
            val signature = MeshCrypto.sign(identity.privateKey, unsigned.signedBytes())
            return MeshPacket(type, ttl, ttl, flags, messageId, identity.peerId, timestamp, target, identity.publicKey, payload, signature)
        }

        /** Parses a packet of this version; null for anything malformed (never throws on hostile input). */
        fun decode(bytes: ByteArray): MeshPacket? {
            if (bytes.size < HEADER_SIZE + 1) return null
            val b = ByteBuffer.wrap(bytes)
            if (b.get().toInt() != MAGIC) return null
            val version = b.get().toInt() and 0xff
            val type = PacketType.of(b.get().toInt() and 0xff) ?: return null
            // Each type exists in exactly one version (a v2 type in a v3 header is malformed).
            if (type.version != version) return null
            val ttl = b.get().toInt() and 0xff
            val maxTtl = b.get().toInt() and 0xff
            val flags = b.get().toInt() and 0xff
            if (maxTtl !in 1..maxTtlOf(type) || ttl !in 1..maxTtl) return null
            val messageId = ByteArray(MESSAGE_ID_SIZE).also { b.get(it) }
            val origin = ByteArray(MeshCrypto.PEER_ID_SIZE).also { b.get(it) }
            val timestamp = b.long
            val target = ByteArray(TARGET_SIZE).also { b.get(it) }
            val originKey = ByteArray(MeshCrypto.PUBLIC_KEY_SIZE).also { b.get(it) }
            val payloadSize = b.short.toInt() and 0xffff
            if (payloadSize > MAX_PAYLOAD || b.remaining() < payloadSize + 1) return null
            val payload = ByteArray(payloadSize).also { b.get(it) }
            val sigSize = b.get().toInt() and 0xff
            if (sigSize == 0 || sigSize > MAX_SIGNATURE || b.remaining() != sigSize) return null
            val signature = ByteArray(sigSize).also { b.get(it) }
            return MeshPacket(type, ttl, maxTtl, flags, messageId, origin, timestamp, target, originKey, payload, signature)
        }

        fun shortIdOf(origin: ByteArray, messageId: ByteArray): Long =
            ByteBuffer.wrap(MeshCrypto.sha256(origin, messageId), 0, 8).long

        fun maxTtlOf(type: PacketType): Int = if (type == PacketType.MEDIA_CHUNK) MEDIA_MAX_TTL else MAX_TTL

        private fun aadOf(type: PacketType, messageId: ByteArray, origin: ByteArray, timestamp: Long, target: ByteArray): ByteArray =
            ByteBuffer.allocate(1 + MESSAGE_ID_SIZE + origin.size + 8 + TARGET_SIZE)
                .put(type.code.toByte()).put(messageId).put(origin).putLong(timestamp).put(target).array()
    }
}

/**
 * A packet from a newer protocol version. It can't be read or verified here, but it is relayed (with
 * a tight per-link rate limit) so that older phones don't cut newer ones off from each other.
 */
class OpaquePacket private constructor(private val bytes: ByteArray) {
    val ttl: Int get() = bytes[3].toInt() and 0xff
    val maxTtl: Int get() = bytes[4].toInt() and 0xff

    /** Dedup key: hash of everything except the ttl byte. */
    val shortId: Long by lazy(LazyThreadSafetyMode.NONE) { idOf(bytes) }

    fun relayed(): ByteArray = bytes.copyOf().also { it[3] = (ttl - 1).toByte() }

    companion object {
        const val MAX_SIZE = 4096
        private val OPAQUE_DOMAIN = "chatfort-mesh-opaque".toByteArray()

        /** SHA-256("chatfort-mesh-opaque" ‖ packet with the ttl byte zeroed)[0..8]. Also the v3 dedup ID. */
        fun idOf(packetBytes: ByteArray): Long {
            val copy = packetBytes.copyOf().also { it[3] = 0 }
            return ByteBuffer.wrap(MeshCrypto.sha256(OPAQUE_DOMAIN, copy), 0, 8).long
        }

        fun decode(bytes: ByteArray): OpaquePacket? {
            if (bytes.size < 6 || bytes.size > MAX_SIZE) return null
            if (bytes[0].toInt() != MeshPacket.MAGIC) return null
            val version = bytes[1].toInt() and 0xff
            val type = bytes[2].toInt() and 0xff
            val ttl = bytes[3].toInt() and 0xff
            val maxTtl = bytes[4].toInt() and 0xff
            if (version <= MeshPacket.VERSION || version >= 0x80 || type >= 0x80) return null
            // Type codes are one namespace across versions. A known code in a version this phone reads
            // is never relayed unread (if MeshPacket.decode rejected it, it is malformed: dropped);
            // unknown codes are, so a version can still grow new types.
            if (version <= MeshPacket.MAX_READ_VERSION && PacketType.of(type) != null) return null
            if (maxTtl !in 1..MeshPacket.MAX_TTL || ttl !in 1..maxTtl) return null
            return OpaquePacket(bytes.copyOf())
        }
    }
}

/** Link-local control frames: exchanged between direct neighbours only, never relayed. */
sealed class ControlFrame {
    /** Short IDs of the packets this node holds for store-and-forward. */
    class Inventory(val ids: List<Long>) : ControlFrame()
    /** Short IDs this node is missing and asks the neighbour to send. */
    class Request(val ids: List<Long>) : ControlFrame()

    fun encode(): ByteArray {
        val (code, ids) = when (this) {
            is Inventory -> INVENTORY to ids
            is Request -> REQUEST to ids
        }
        val list = ids.take(MAX_IDS)
        val b = ByteBuffer.allocate(5 + list.size * 8)
            .put(MeshPacket.MAGIC.toByte()).put(MeshPacket.VERSION.toByte()).put(code.toByte())
            .putShort(list.size.toShort())
        list.forEach { b.putLong(it) }
        return b.array()
    }

    companion object {
        const val INVENTORY = 0x81
        const val REQUEST = 0x82
        const val MAX_IDS = 512

        fun isControl(bytes: ByteArray): Boolean =
            bytes.size >= 3 && (bytes[2].toInt() and 0xff) >= 0x80

        fun decode(bytes: ByteArray): ControlFrame? {
            if (bytes.size < 5) return null
            val b = ByteBuffer.wrap(bytes)
            if (b.get().toInt() != MeshPacket.MAGIC || b.get().toInt() != MeshPacket.VERSION) return null
            val code = b.get().toInt() and 0xff
            val count = b.short.toInt() and 0xffff
            if (count > MAX_IDS || b.remaining() != count * 8) return null
            val ids = List(count) { b.long }
            return when (code) {
                INVENTORY -> Inventory(ids)
                REQUEST -> Request(ids)
                else -> null
            }
        }
    }
}

/**
 * The plaintext inside CHANNEL and DIRECT payloads (sealed sender):
 * kind(1) | senderKey(65) | signatureLength(1) | signature | content
 *
 * The signature is by the sender's mesh identity over [signedBytes]: the packet header fields, the
 * recipient binding (recipient's key for DIRECT, nothing extra for CHANNEL since the target tag is
 * already bound), the kind and the content. So a recipient can't re-wrap someone's message to a third
 * person, and nobody can move it into another packet or team.
 */
object SealedBody {
    enum class Kind(val code: Int) {
        /** content = [MessageBody] */
        MESSAGE(1),
        /** content = the acknowledged message ID (16 bytes). DIRECT only. */
        ACK(2),
        /** content = the sender's new public key (65 bytes); signed by the old identity. DIRECT only. */
        REKEY(3),
        /** Wire v3: content = uid(16) ‖ [MediaHeader]. CHANNEL only (v2 phones ignore unknown kinds). */
        MEDIA(4);

        companion object {
            fun of(code: Int): Kind? = entries.firstOrNull { it.code == code }
        }
    }

    class Opened(val kind: Kind, val senderKey: ByteArray, val content: ByteArray) {
        val senderPeerId: ByteArray get() = MeshCrypto.peerId(senderKey)
    }

    private val DOMAIN = "chatfort-mesh-sealed-v2".toByteArray()

    fun seal(sender: MeshIdentity, kind: Kind, content: ByteArray, header: Header, recipientKey: ByteArray?): ByteArray {
        val sig = MeshCrypto.sign(sender.privateKey, signedBytes(kind, content, header, recipientKey))
        return ByteBuffer.allocate(1 + MeshCrypto.PUBLIC_KEY_SIZE + 1 + sig.size + content.size)
            .put(kind.code.toByte()).put(sender.publicKey).put(sig.size.toByte()).put(sig).put(content)
            .array()
    }

    /** Parses and verifies; null if malformed or the signature doesn't hold. */
    fun open(plain: ByteArray, header: Header, recipientKey: ByteArray?): Opened? {
        if (plain.size < 1 + MeshCrypto.PUBLIC_KEY_SIZE + 1 + 8) return null
        val b = ByteBuffer.wrap(plain)
        val kind = Kind.of(b.get().toInt() and 0xff) ?: return null
        val senderKey = ByteArray(MeshCrypto.PUBLIC_KEY_SIZE).also { b.get(it) }
        val sigSize = b.get().toInt() and 0xff
        if (sigSize == 0 || sigSize > MeshPacket.MAX_SIGNATURE || b.remaining() < sigSize) return null
        val sig = ByteArray(sigSize).also { b.get(it) }
        val content = ByteArray(b.remaining()).also { b.get(it) }
        val key = MeshCrypto.decodePublicKey(senderKey) ?: return null
        if (!MeshCrypto.verify(key, signedBytes(kind, content, header, recipientKey), sig)) return null
        return Opened(kind, senderKey, content)
    }

    /** The outer packet fields the inner signature covers. */
    class Header(val type: PacketType, val messageId: ByteArray, val timestamp: Long, val target: ByteArray)

    private fun signedBytes(kind: Kind, content: ByteArray, h: Header, recipientKey: ByteArray?): ByteArray {
        val recipient = recipientKey ?: ByteArray(0)
        return ByteBuffer.allocate(DOMAIN.size + 1 + MeshPacket.MESSAGE_ID_SIZE + 8 + MeshPacket.TARGET_SIZE + 1 + recipient.size + 1 + content.size)
            .put(DOMAIN).put(h.type.code.toByte()).put(h.messageId).putLong(h.timestamp).put(h.target)
            .put(recipient.size.toByte()).put(recipient)
            .put(kind.code.toByte()).put(content)
            .array()
    }
}

/** Message bodies: [nickname length][nickname UTF-8][text UTF-8]. */
object MessageBody {
    const val MAX_NICKNAME_BYTES = 32
    const val MAX_TEXT_BYTES = 1000

    fun encode(nickname: String, text: String = ""): ByteArray {
        val nick = truncateUtf8(nickname, MAX_NICKNAME_BYTES)
        val body = truncateUtf8(text, MAX_TEXT_BYTES)
        return byteArrayOf(nick.size.toByte()) + nick + body
    }

    /** Returns (nickname, text), or null if malformed. */
    fun decode(bytes: ByteArray): Pair<String, String>? {
        if (bytes.isEmpty()) return null
        val n = bytes[0].toInt() and 0xff
        if (n > MAX_NICKNAME_BYTES || 1 + n > bytes.size || bytes.size - 1 - n > MAX_TEXT_BYTES) return null
        val nick = String(bytes, 1, n, Charsets.UTF_8)
        val text = String(bytes, 1 + n, bytes.size - 1 - n, Charsets.UTF_8)
        return nick to text
    }

    /** Cuts at a character boundary so the result is at most [max] bytes of valid UTF-8. */
    fun truncateUtf8(s: String, max: Int): ByteArray {
        val full = s.toByteArray(Charsets.UTF_8)
        if (full.size <= max) return full
        val sb = StringBuilder()
        var size = 0
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            val len = when {
                cp < 0x80 -> 1
                cp < 0x800 -> 2
                cp < 0x10000 -> 3
                else -> 4
            }
            if (size + len > max) break
            sb.appendCodePoint(cp)
            size += len
            i += Character.charCount(cp)
        }
        return sb.toString().toByteArray(Charsets.UTF_8)
    }

    /** At most [maxChars] characters, never splitting a surrogate pair (emoji). */
    fun truncateChars(s: String, maxChars: Int): String {
        if (s.codePointCount(0, s.length) <= maxChars) return s
        return s.substring(0, s.offsetByCodePoints(0, maxChars))
    }
}
