package chat.simplex.mesh.core

import chat.simplex.mesh.protocol.MeshCrypto
import chat.simplex.mesh.protocol.MeshPacket
import java.nio.ByteBuffer

/**
 * An encrypted team channel. Anyone holding the current key can read and post; relays only see
 * ciphertext and an hourly tag.
 *
 * Forward secrecy by day: key(d+1) = HKDF(key(d), "chatfort-mesh-channel-ratchet-v2"). Phones keep
 * only today's key (plus yesterday's for [PREVIOUS_KEY_GRACE_MS] after midnight UTC, for late or
 * mistimed messages), and team codes carry the key of the day they are shown. So a leaked code or a
 * seized phone can't read earlier days' messages.
 *
 * Unlinkable over time: the target tag is HMAC(tagKey(day), hour), so relays can't follow a team's
 * traffic from one hour to the next.
 *
 * Immutable: [advancedTo] returns a new instance.
 */
class TeamChannel private constructor(
    /** Local only (UI and storage); never sent. Each member's phone has its own. */
    val localId: String,
    val name: String,
    /** UTC day number of [key]. */
    val day: Long,
    val key: ByteArray,
    private val previousKey: ByteArray?
) {
    private val tagKeys = HashMap<Long, ByteArray>()

    /** Ratchets forward to [today]; keeps yesterday's key only for the grace period after midnight. */
    fun advancedTo(now: Long): TeamChannel {
        val today = dayOf(now)
        val keepPrevious = now - today * DAY_MS < PREVIOUS_KEY_GRACE_MS
        if (today <= day) {
            // Same day (or the clock went back): nothing to derive; drop yesterday's key once the grace is over.
            return if (previousKey != null && today == day && !keepPrevious) TeamChannel(localId, name, day, key, null) else this
        }
        var k = key
        var prev: ByteArray? = null
        for (d in day until today) {
            prev = k
            k = ratchet(k)
        }
        return TeamChannel(localId, name, today, k, if (keepPrevious) prev else null)
    }

    /** Key for UTC [d]: today's, yesterday's (while kept), or tomorrow's (derived, for fast clocks). */
    fun keyFor(d: Long): ByteArray? = when (d) {
        day -> key
        day - 1 -> previousKey
        day + 1 -> ratchet(key)
        else -> null
    }

    fun messageKey(timestamp: Long): ByteArray? =
        keyFor(dayOf(timestamp))?.let { MeshCrypto.hkdf(it, null, MESSAGE_INFO, MeshCrypto.KEY_SIZE) }

    /** The packet target for a message sent at [timestamp]: changes every hour. */
    fun tag(timestamp: Long): ByteArray? {
        val d = dayOf(timestamp)
        val tagKey = tagKeys[d] ?: keyFor(d)?.let { MeshCrypto.hkdf(it, null, TAG_INFO, MeshCrypto.KEY_SIZE) }?.also { tagKeys[d] = it } ?: return null
        val hour = Math.floorDiv(timestamp, HOUR_MS)
        return MeshCrypto.hmac(tagKey, ByteBuffer.allocate(8).putLong(hour).array()).copyOf(MeshPacket.TARGET_SIZE)
    }

    /** Same team (same key chain), whatever day each copy was saved on. */
    fun sameTeamAs(other: TeamChannel): Boolean {
        val d = maxOf(day, other.day)
        return keyAt(d).contentEquals(other.keyAt(d))
    }

    private fun keyAt(d: Long): ByteArray {
        var k = key
        for (i in day until d) k = ratchet(k)
        return k
    }

    /** Fields to persist: the key of [day] only (older keys are never stored). */
    fun persisted(): Persisted = Persisted(localId, name, day, key, previousKey)

    class Persisted(val localId: String, val name: String, val day: Long, val key: ByteArray, val previousKey: ByteArray?)

    companion object {
        const val DAY_MS = 24 * 60 * 60_000L
        const val HOUR_MS = 60 * 60_000L
        const val PREVIOUS_KEY_GRACE_MS = 12 * 60 * 60_000L
        private val RATCHET_INFO = "chatfort-mesh-channel-ratchet-v2".toByteArray()
        private val MESSAGE_INFO = "chatfort-mesh-channel-msg-v2".toByteArray()
        private val TAG_INFO = "chatfort-mesh-channel-tag-v2".toByteArray()

        fun dayOf(timestamp: Long): Long = Math.floorDiv(timestamp, DAY_MS)

        fun ratchet(key: ByteArray): ByteArray = MeshCrypto.hkdf(key, null, RATCHET_INFO, MeshCrypto.KEY_SIZE)

        /** A new team with a random key, starting today. */
        fun create(name: String, now: Long): TeamChannel =
            TeamChannel(newLocalId(), name, dayOf(now), MeshCrypto.randomBytes(MeshCrypto.KEY_SIZE), null)

        /** A team from a code: the key of [day]. Ratchet with [advancedTo] before use. */
        fun fromCode(name: String, key: ByteArray, day: Long): TeamChannel {
            require(key.size == MeshCrypto.KEY_SIZE)
            return TeamChannel(newLocalId(), name, day, key.copyOf(), null)
        }

        fun restore(p: Persisted): TeamChannel = TeamChannel(p.localId, p.name, p.day, p.key, p.previousKey)

        private fun newLocalId(): String = MeshCrypto.randomBytes(8).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
