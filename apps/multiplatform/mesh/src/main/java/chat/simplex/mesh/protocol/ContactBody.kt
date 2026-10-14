package chat.simplex.mesh.protocol

import java.nio.ByteBuffer

/**
 * Wire v3: the plaintext inside a CONTACT packet: kind(1) | role(1) | uid(16) | content.
 *
 * No inner signature: only the two linked phones hold the pair key, so a packet that decrypts came
 * from one of them, and [role] (each side's fixed 0 or 1) tells which, so a phone can drop its own
 * packets reflected back at it. [uid] is the sender's stable ID for the item, the same across resends.
 */
object ContactBody {
    const val UID_SIZE = 16
    const val MAX_TEXT_BYTES = MessageBody.MAX_TEXT_BYTES

    enum class Kind(val code: Int) {
        /** content = text (UTF-8, at most [MAX_TEXT_BYTES]). */
        MESSAGE(1),
        /** uid = the acknowledged item's uid; no content. */
        ACK(2),
        /** "Are you nearby?" No content; answered with [PONG]. */
        PING(3),
        /** uid = the ping's uid; no content. */
        PONG(4),
        /** content = [MediaHeader]. */
        MEDIA(5);

        companion object {
            fun of(code: Int): Kind? = entries.firstOrNull { it.code == code }
        }
    }

    class Opened(val kind: Kind, val role: Int, val uid: ByteArray, val content: ByteArray)

    fun encode(kind: Kind, role: Int, uid: ByteArray, content: ByteArray = ByteArray(0)): ByteArray {
        require(role == 0 || role == 1)
        require(uid.size == UID_SIZE)
        return ByteBuffer.allocate(2 + UID_SIZE + content.size)
            .put(kind.code.toByte()).put(role.toByte()).put(uid).put(content).array()
    }

    /** Null if malformed. Text is checked to fit [MAX_TEXT_BYTES]; other kinds carry no content except MEDIA. */
    fun decode(bytes: ByteArray): Opened? {
        if (bytes.size < 2 + UID_SIZE) return null
        val kind = Kind.of(bytes[0].toInt() and 0xff) ?: return null
        val role = bytes[1].toInt() and 0xff
        if (role > 1) return null
        val uid = bytes.copyOfRange(2, 2 + UID_SIZE)
        val content = bytes.copyOfRange(2 + UID_SIZE, bytes.size)
        when (kind) {
            Kind.MESSAGE -> if (content.size > MAX_TEXT_BYTES) return null
            Kind.MEDIA -> if (content.isEmpty()) return null
            else -> if (content.isNotEmpty()) return null
        }
        return Opened(kind, role, uid, content)
    }
}
