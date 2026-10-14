package chat.simplex.mesh.protocol

import java.nio.ByteBuffer

/** Wire v3 media: what can be sent, and how big it may be. */
enum class MediaType(val code: Int, val maxBytes: Int) {
    /** JPEG, re-encoded from pixels (no EXIF/location), long edge at most 1024. */
    PHOTO(1, 48 * 1024),
    /** AAC (HE-AAC v1 or AAC-LC) in an MPEG-4 (.m4a) container, mono 16 kHz, at most 30 s. 42 chunks. */
    VOICE(2, 42 * 1536);

    companion object {
        fun of(code: Int): MediaType? = entries.firstOrNull { it.code == code }
    }
}

/**
 * Describes a photo or voice note and carries the key to its chunks. Sent inside a CONTACT packet
 * (kind MEDIA) or a team CHANNEL packet (sealed kind MEDIA, after a 16-byte uid).
 *
 * mediaType(1) | totalSize(4) | chunkCount(1) | sha256(32) | mediaKey(32) | mediaId(8) |
 * durationMs(4) | width(2) | height(2) | nickLen(1) | nick | captionLen(2) | caption
 */
class MediaHeader(
    val type: MediaType,
    val totalSize: Int,
    val chunkCount: Int,
    val sha256: ByteArray,
    val mediaKey: ByteArray,
    val mediaId: ByteArray,
    val durationMs: Int,
    val width: Int,
    val height: Int,
    val nickname: String,
    val caption: String
) {
    fun encode(): ByteArray {
        val nick = MessageBody.truncateUtf8(nickname, MessageBody.MAX_NICKNAME_BYTES)
        val cap = MessageBody.truncateUtf8(caption, MAX_CAPTION_BYTES)
        return ByteBuffer.allocate(FIXED_SIZE + 1 + nick.size + 2 + cap.size)
            .put(type.code.toByte()).putInt(totalSize).put(chunkCount.toByte())
            .put(sha256).put(mediaKey).put(mediaId)
            .putInt(durationMs).putShort(width.toShort()).putShort(height.toShort())
            .put(nick.size.toByte()).put(nick)
            .putShort(cap.size.toShort()).put(cap)
            .array()
    }

    companion object {
        const val CHUNK_SIZE = 1536
        const val MAX_CHUNKS = 48
        const val MEDIA_ID_SIZE = 8
        const val MAX_CAPTION_BYTES = 500
        private const val FIXED_SIZE = 1 + 4 + 1 + 32 + MeshCrypto.KEY_SIZE + MEDIA_ID_SIZE + 4 + 2 + 2

        fun chunksFor(totalSize: Int): Int = (totalSize + CHUNK_SIZE - 1) / CHUNK_SIZE

        /** Null if malformed or over the limits for its type. */
        fun decode(bytes: ByteArray): MediaHeader? {
            if (bytes.size < FIXED_SIZE + 1 + 2) return null
            val b = ByteBuffer.wrap(bytes)
            val type = MediaType.of(b.get().toInt() and 0xff) ?: return null
            val totalSize = b.int
            val chunkCount = b.get().toInt() and 0xff
            if (totalSize !in 1..type.maxBytes || chunkCount != chunksFor(totalSize) || chunkCount > MAX_CHUNKS) return null
            val sha = ByteArray(32).also { b.get(it) }
            val key = ByteArray(MeshCrypto.KEY_SIZE).also { b.get(it) }
            val id = ByteArray(MEDIA_ID_SIZE).also { b.get(it) }
            val duration = b.int
            val width = b.short.toInt() and 0xffff
            val height = b.short.toInt() and 0xffff
            if (duration < 0) return null
            val nickLen = b.get().toInt() and 0xff
            if (nickLen > MessageBody.MAX_NICKNAME_BYTES || b.remaining() < nickLen + 2) return null
            val nick = ByteArray(nickLen).also { b.get(it) }
            val capLen = b.short.toInt() and 0xffff
            if (capLen > MAX_CAPTION_BYTES || b.remaining() != capLen) return null
            val cap = ByteArray(capLen).also { b.get(it) }
            return MediaHeader(
                type, totalSize, chunkCount, sha, key, id, duration, width, height,
                String(nick, Charsets.UTF_8), String(cap, Charsets.UTF_8)
            )
        }

        /** A header for [data] with a fresh random media key and ID. */
        fun create(type: MediaType, data: ByteArray, durationMs: Int, width: Int, height: Int, nickname: String, caption: String): MediaHeader {
            require(data.size in 1..type.maxBytes)
            return MediaHeader(
                type, data.size, chunksFor(data.size), MeshCrypto.sha256(data),
                MeshCrypto.randomBytes(MeshCrypto.KEY_SIZE), MeshCrypto.randomBytes(MEDIA_ID_SIZE),
                durationMs, width, height, nickname, caption
            )
        }
    }
}

/**
 * MEDIA_CHUNK payload: index(1) | AES-256-GCM(chunkKey, data, AAD = mediaId(8) ‖ index), without the
 * nonce: nonce = 11 zero bytes ‖ index. Key, nonce and AAD depend only on the item and the index, so
 * a chunk always encrypts to the same bytes: resends (same mediaKey, mediaId and data, new packets)
 * never use a (key, nonce) pair with different input, which would leak the GCM authentication key.
 * The packet itself is bound by its outer signature.
 */
object MediaChunk {
    private val CHUNK_INFO = "chatfort-mesh-media-chunk-v3".toByteArray()

    fun chunkKey(mediaKey: ByteArray): ByteArray = MeshCrypto.hkdf(mediaKey, null, CHUNK_INFO, MeshCrypto.KEY_SIZE)

    fun split(data: ByteArray): List<ByteArray> =
        (0 until MediaHeader.chunksFor(data.size)).map { i ->
            data.copyOfRange(i * MediaHeader.CHUNK_SIZE, minOf((i + 1) * MediaHeader.CHUNK_SIZE, data.size))
        }

    fun seal(chunkKey: ByteArray, index: Int, data: ByteArray, mediaId: ByteArray): ByteArray {
        require(index in 0 until MediaHeader.MAX_CHUNKS && mediaId.size == MediaHeader.MEDIA_ID_SIZE)
        val sealed = MeshCrypto.sealWithNonce(chunkKey, data, aad(mediaId, index), nonce(index))
        return byteArrayOf(index.toByte()) + sealed.copyOfRange(MeshCrypto.NONCE_SIZE, sealed.size)
    }

    /** The chunk index of a payload (unauthenticated until [open] succeeds), or -1 if malformed. */
    fun indexOf(payload: ByteArray): Int =
        if (payload.size < 1 + 16) -1 else (payload[0].toInt() and 0xff).takeIf { it < MediaHeader.MAX_CHUNKS } ?: -1

    /** The chunk's data, or null if the key is wrong or anything was tampered with. */
    fun open(chunkKey: ByteArray, payload: ByteArray, mediaId: ByteArray): ByteArray? {
        val index = indexOf(payload)
        if (index < 0 || mediaId.size != MediaHeader.MEDIA_ID_SIZE) return null
        return MeshCrypto.open(chunkKey, nonce(index) + payload.copyOfRange(1, payload.size), aad(mediaId, index))
    }

    fun aad(mediaId: ByteArray, index: Int): ByteArray = mediaId + index.toByte()

    private fun nonce(index: Int): ByteArray = ByteArray(MeshCrypto.NONCE_SIZE).also { it[MeshCrypto.NONCE_SIZE - 1] = index.toByte() }
}
