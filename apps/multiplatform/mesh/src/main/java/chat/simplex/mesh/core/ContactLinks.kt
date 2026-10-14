package chat.simplex.mesh.core

import chat.simplex.mesh.protocol.MeshCrypto
import org.json.JSONObject
import java.util.Base64

/**
 * Wire v3: which ChatFort contacts are linked for the mesh, and the seed swap that links them. The
 * app carries the seeds inside the contacts' SimpleX chats; this class only decides what to send.
 *
 * Rules (no loops: a reply is only ever sent in answer to an offer):
 * - Offer = our seed with ack=false. Made once per contact; re-sent once if no reply after
 *   [RESEND_MS], then never again ([MAX_OFFERS]): a contact on an older app would otherwise see the
 *   fallback text over and over, and once it updates, its own offer links us anyway. An offer that
 *   couldn't be sent doesn't count ([offerFailed]).
 * - On an offer with a new seed: if our own offer is pending, the offers crossed: link to it (no
 *   reply needed, the other side links to ours). Otherwise link with a new seed and answer (ack=true).
 *   A new seed while linked means the partner reset: same thing.
 * - On an offer we already linked to (re-sent, or handled twice): send the **identical** answer while
 *   it is kept ([ANSWER_KEEP_MS], or until a packet from the partner proves the pair, [confirmed]),
 *   never a new one, which would leave the two phones on different keys for good. After crossing
 *   offers the kept answer is our own offered seed, so a partner that never got our offer still lands
 *   on the same pair.
 * - On an answer (ack=true): link if we have a pending seed; otherwise ignore it.
 * - Once linked, the pair key chain is kept and their seed only as a hash. Our own seed survives only
 *   as the kept answer (at most 7 days), so a seized phone can't rebuild older day keys after that.
 *
 * Keys are bindings chosen by the app (a contact of a profile); they are never sent.
 * Not thread-safe: the caller synchronizes.
 */
class ContactLinks(private val clock: () -> Long) {

    class Offer(val seed: ByteArray, val day: Long, val ack: Boolean)

    private class State(
        var pending: ByteArray? = null,
        var pendingDay: Long = 0,
        var offeredAt: Long = 0,
        var offers: Int = 0,
        var theirHash: ByteArray? = null,
        var channel: ContactChannel? = null,
        var answer: ByteArray? = null,
        var answerDay: Long = 0,
        var answerAt: Long = 0,
        /** False while the answer still has to go out (sending failed or it was just made). */
        var answerSent: Boolean = true
    )

    private val states = HashMap<String, State>()

    fun isLinked(binding: String): Boolean = states[binding]?.channel != null

    fun linkedBindings(): Set<String> = states.filterValues { it.channel != null }.keys

    fun channel(binding: String): ContactChannel? = states[binding]?.channel

    /** Linked contacts' pair keys, advanced to today (call [advance] first). */
    fun channels(): List<ContactChannel> = states.values.mapNotNull { it.channel }

    /** The offer to send to [binding] now, if any: never linked and not offered recently. */
    fun offerFor(binding: String): Offer? {
        val now = clock()
        val s = states.getOrPut(binding) { State() }
        if (s.channel != null) return null
        val pending = s.pending
        if (pending != null && now - s.offeredAt < RESEND_MS) return null
        if (s.offers >= MAX_OFFERS) return null
        val seed = pending ?: MeshCrypto.randomBytes(ContactChannel.SEED_SIZE).also {
            s.pending = it
            s.pendingDay = TeamChannel.dayOf(now)
        }
        s.offeredAt = now
        s.offers++
        return Offer(seed, s.pendingDay, ack = false)
    }

    /** The offer from [offerFor] couldn't be sent: it doesn't count, and is retried on the next refresh. */
    fun offerFailed(binding: String) {
        val s = states[binding] ?: return
        if (s.pending == null || s.channel != null) return
        s.offers = maxOf(0, s.offers - 1)
        s.offeredAt = 0
    }

    /** Handles a seed from [binding]'s SimpleX chat. Returns the message to send back now, if any. */
    fun onReceived(binding: String, seed: ByteArray, day: Long, ack: Boolean): Offer? {
        if (seed.size != ContactChannel.SEED_SIZE || day < 0) return null
        val now = clock()
        val s = states.getOrPut(binding) { State() }
        val hash = MeshCrypto.sha256(seed)
        if (ack) {
            val mine = s.pending ?: return null
            link(binding, s, mine, s.pendingDay, seed, day, hash, now)
            return null
        }
        if (s.channel != null && s.theirHash?.contentEquals(hash) == true) {
            // An offer we already linked to: the identical answer while it is kept, otherwise nothing.
            val answer = s.answer ?: return null
            if (now - s.answerAt > ANSWER_KEEP_MS) {
                s.answer = null
                return null
            }
            s.answerSent = false
            return Offer(answer, s.answerDay, ack = true)
        }
        val pending = s.pending
        val pendingDay = s.pendingDay
        if (pending != null && link(binding, s, pending, pendingDay, seed, day, hash, now)) {
            // Crossing offers: no answer needed. Keep our offered seed as the answer, in case the
            // partner never got our offer and repeats its own.
            keepAnswer(s, pending, pendingDay, now, sent = true)
            return null
        }
        repeat(3) {
            val mine = MeshCrypto.randomBytes(ContactChannel.SEED_SIZE)
            val myDay = TeamChannel.dayOf(now)
            if (link(binding, s, mine, myDay, seed, day, hash, now)) {
                keepAnswer(s, mine, myDay, now, sent = false)
                return Offer(mine, myDay, ack = true)
            }
            // Equal seeds (practically impossible): try a new one.
        }
        return null
    }

    /** The answer from [onReceived] or [unsentAnswers] went out. */
    fun answerSent(binding: String) {
        states[binding]?.answerSent = true
    }

    /** Answers that still have to be sent (an earlier send failed). */
    fun unsentAnswers(): List<Pair<String, Offer>> {
        val now = clock()
        return states.mapNotNull { (binding, s) ->
            val a = s.answer
            if (a != null && !s.answerSent && now - s.answerAt <= ANSWER_KEEP_MS) binding to Offer(a, s.answerDay, ack = true) else null
        }
    }

    /** A packet from the partner decrypted: both sides hold the pair, so the kept answer can go. True if anything changed. */
    fun confirmed(binding: String): Boolean {
        val s = states[binding] ?: return false
        if (s.answer == null) return false
        s.answer = null
        return true
    }

    private fun keepAnswer(s: State, seed: ByteArray, day: Long, now: Long, sent: Boolean) {
        s.answer = seed
        s.answerDay = day
        s.answerAt = now
        s.answerSent = sent
    }

    private fun link(binding: String, s: State, mine: ByteArray, myDay: Long, theirs: ByteArray, theirDay: Long, theirHash: ByteArray, now: Long): Boolean {
        val channel = ContactChannel.fromSeeds(binding, mine, myDay, theirs, theirDay, now) ?: return false
        s.channel = channel
        s.theirHash = theirHash
        s.pending = null
        s.offeredAt = 0
        s.answer = null
        s.answerSent = true
        return true
    }

    /** Daily ratchet, and expiry of kept answers. True if anything changed (then save). */
    fun advance(): Boolean {
        val now = clock()
        var changed = false
        states.values.forEach { s ->
            if (s.answer != null && now - s.answerAt > ANSWER_KEEP_MS) {
                s.answer = null
                changed = true
            }
            val c = s.channel ?: return@forEach
            val next = c.advancedTo(now)
            if (next !== c) {
                s.channel = next
                changed = true
            }
        }
        return changed
    }

    fun forget(binding: String): Boolean = states.remove(binding) != null

    /** Forgets every binding starting with [prefix] that is not in [keep] (deleted contacts or profile). */
    fun retain(prefix: String, keep: Set<String>): Boolean {
        val gone = states.keys.filter { it.startsWith(prefix) && it !in keep }
        gone.forEach { states.remove(it) }
        return gone.isNotEmpty()
    }

    fun clear() = states.clear()

    fun toJson(): JSONObject {
        val o = JSONObject()
        states.forEach { (binding, s) ->
            val j = JSONObject()
            s.pending?.let { j.put("pend", b64(it)).put("pendDay", s.pendingDay).put("offeredAt", s.offeredAt) }
            if (s.offers > 0) j.put("offers", s.offers)
            s.theirHash?.let { j.put("th", b64(it)) }
            s.answer?.let { j.put("ans", b64(it)).put("ansDay", s.answerDay).put("ansAt", s.answerAt).put("ansSent", s.answerSent) }
            s.channel?.persisted()?.let { p ->
                j.put("role", p.role).put("start", p.startDay).put("day", p.day).put("key", b64(p.key))
                p.previousKey?.let { j.put("prev", b64(it)) }
            }
            o.put(binding, j)
        }
        return o
    }

    fun load(o: JSONObject) {
        states.clear()
        o.keys().forEach { binding ->
            try {
                val j = o.getJSONObject(binding)
                val s = State()
                if (j.has("pend")) {
                    s.pending = unb64(j.getString("pend"))
                    s.pendingDay = j.getLong("pendDay")
                    s.offeredAt = j.optLong("offeredAt", 0)
                }
                s.offers = j.optInt("offers", 0)
                if (j.has("th")) s.theirHash = unb64(j.getString("th"))
                if (j.has("ans")) {
                    s.answer = unb64(j.getString("ans"))
                    s.answerDay = j.getLong("ansDay")
                    s.answerAt = j.getLong("ansAt")
                    s.answerSent = j.optBoolean("ansSent", true)
                }
                if (j.has("key")) {
                    s.channel = ContactChannel.restore(
                        ContactChannel.Persisted(
                            binding, j.getInt("role"), j.getLong("start"), j.getLong("day"), unb64(j.getString("key")),
                            if (j.has("prev")) unb64(j.getString("prev")) else null
                        )
                    )
                }
                states[binding] = s
            } catch (_: Exception) {
            }
        }
    }

    private fun b64(b: ByteArray): String = Base64.getEncoder().encodeToString(b)
    private fun unb64(s: String): ByteArray = Base64.getDecoder().decode(s)

    companion object {
        /** An offer with no reply is sent again after this long. */
        const val RESEND_MS = 3 * 24 * 60 * 60_000L
        /** Offers per contact, ever (the first and one re-send). */
        const val MAX_OFFERS = 2
        /** How long our answer to an offer is kept, to repeat it identically if the offer comes again. */
        const val ANSWER_KEEP_MS = 7 * 24 * 60 * 60_000L
        /** Seeds travel as base64url without padding inside the SimpleX message. */
        fun encodeSeed(seed: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(seed)

        fun decodeSeed(s: String): ByteArray? = try { Base64.getUrlDecoder().decode(s) } catch (_: IllegalArgumentException) { null }
    }
}
