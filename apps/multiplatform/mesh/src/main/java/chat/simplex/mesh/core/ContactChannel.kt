package chat.simplex.mesh.core

import chat.simplex.mesh.protocol.MeshCrypto
import chat.simplex.mesh.protocol.MeshPacket
import java.nio.ByteBuffer

/**
 * Wire v3: the key chain two linked ChatFort contacts share on the mesh.
 *
 * Each side sends a random 32-byte seed (and its UTC day) inside their SimpleX chat while online. With
 * lo/hi = the two seeds in unsigned byte order:
 * - key(d0) = HKDF(lo ‖ hi, "chatfort-mesh-contact-root-v3"), d0 = the later of the two days
 * - key(d+1) = HKDF(key(d), "chatfort-mesh-contact-ratchet-v3")
 * - [role] = 0 for the side whose seed is lo, else 1
 *
 * Like a team ([TeamChannel]): only today's key is kept (plus yesterday's for 12 h after midnight
 * UTC), so a seized phone can't read earlier days; tags change every hour, so relays can't follow
 * the pair. The seeds themselves are never stored once linked.
 *
 * Immutable: [advancedTo] returns a new instance.
 */
class ContactChannel private constructor(
    /** Local only: the app's binding to the SimpleX contact. Never sent. */
    val localId: String,
    val role: Int,
    /** The first day this pair has a key (before it, nothing is sent or read). */
    val startDay: Long,
    /** UTC day number of [key]. */
    val day: Long,
    private val key: ByteArray,
    private val previousKey: ByteArray?
) {
    private val tagKeys = HashMap<Long, ByteArray>()

    fun advancedTo(now: Long): ContactChannel {
        val today = TeamChannel.dayOf(now)
        val keepPrevious = now - today * TeamChannel.DAY_MS < TeamChannel.PREVIOUS_KEY_GRACE_MS
        if (today <= day) {
            return if (previousKey != null && today == day && !keepPrevious) ContactChannel(localId, role, startDay, day, key, null) else this
        }
        var k = key
        var prev: ByteArray? = null
        for (d in day until today) {
            prev = k
            k = ratchet(k)
        }
        return ContactChannel(localId, role, startDay, today, k, if (keepPrevious && today - 1 >= startDay) prev else null)
    }

    fun keyFor(d: Long): ByteArray? = when {
        d < startDay -> null
        d == day -> key
        d == day - 1 -> previousKey
        d == day + 1 -> ratchet(key)
        else -> null
    }

    fun messageKey(timestamp: Long): ByteArray? =
        keyFor(TeamChannel.dayOf(timestamp))?.let { MeshCrypto.hkdf(it, null, MESSAGE_INFO, MeshCrypto.KEY_SIZE) }

    /** The packet target for [timestamp]: changes every hour. */
    fun tag(timestamp: Long): ByteArray? {
        val d = TeamChannel.dayOf(timestamp)
        val tagKey = tagKeys[d] ?: keyFor(d)?.let { MeshCrypto.hkdf(it, null, TAG_INFO, MeshCrypto.KEY_SIZE) }?.also { tagKeys[d] = it } ?: return null
        val hour = Math.floorDiv(timestamp, TeamChannel.HOUR_MS)
        return MeshCrypto.hmac(tagKey, ByteBuffer.allocate(8).putLong(hour).array()).copyOf(MeshPacket.TARGET_SIZE)
    }

    fun persisted(): Persisted = Persisted(localId, role, startDay, day, key, previousKey)

    class Persisted(val localId: String, val role: Int, val startDay: Long, val day: Long, val key: ByteArray, val previousKey: ByteArray?)

    companion object {
        private val ROOT_INFO = "chatfort-mesh-contact-root-v3".toByteArray()
        private val RATCHET_INFO = "chatfort-mesh-contact-ratchet-v3".toByteArray()
        private val MESSAGE_INFO = "chatfort-mesh-contact-msg-v3".toByteArray()
        private val TAG_INFO = "chatfort-mesh-contact-tag-v3".toByteArray()
        const val SEED_SIZE = 32

        fun ratchet(key: ByteArray): ByteArray = MeshCrypto.hkdf(key, null, RATCHET_INFO, MeshCrypto.KEY_SIZE)

        /**
         * The pair from both seeds, already advanced to [now]. Null if a seed has the wrong size or both
         * are equal (then a new seed must be made).
         */
        fun fromSeeds(localId: String, mySeed: ByteArray, myDay: Long, theirSeed: ByteArray, theirDay: Long, now: Long): ContactChannel? {
            if (mySeed.size != SEED_SIZE || theirSeed.size != SEED_SIZE) return null
            val cmp = compareUnsigned(mySeed, theirSeed)
            if (cmp == 0) return null
            val (lo, hi) = if (cmp < 0) mySeed to theirSeed else theirSeed to mySeed
            val d0 = maxOf(myDay, theirDay)
            val root = MeshCrypto.hkdf(lo + hi, null, ROOT_INFO, MeshCrypto.KEY_SIZE)
            return ContactChannel(localId, if (cmp < 0) 0 else 1, d0, d0, root, null).advancedTo(now)
        }

        fun restore(p: Persisted): ContactChannel = ContactChannel(p.localId, p.role, p.startDay, p.day, p.key, p.previousKey)

        fun compareUnsigned(a: ByteArray, b: ByteArray): Int {
            for (i in 0 until minOf(a.size, b.size)) {
                val c = (a[i].toInt() and 0xff) - (b[i].toInt() and 0xff)
                if (c != 0) return c
            }
            return a.size - b.size
        }
    }
}
