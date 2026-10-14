package chat.simplex.mesh

import chat.simplex.mesh.core.ContactLinks
import chat.simplex.mesh.protocol.toHex
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The seed swap over SimpleX that links two ChatFort contacts for the mesh. */
class ContactLinksTest {
    private var now = 1_790_000_000_000L
    private val clock = { now }

    /** One link message in flight inside the SimpleX chat. */
    private class Msg(val to: String, val offer: ContactLinks.Offer)

    private inner class Pair {
        var a = ContactLinks(clock)
        var b = ContactLinks(clock)
        val wire = ArrayDeque<Msg>()
        var delivered = 0

        fun offerFromA() = a.offerFor("ab")?.let { wire.addLast(Msg("b", it)) }
        fun offerFromB() = b.offerFor("ba")?.let { wire.addLast(Msg("a", it)) }

        /** Delivers everything (including replies) and returns how many messages were sent. */
        fun deliverAll(drop: (Msg) -> Boolean = { false }): Int {
            var n = 0
            while (wire.isNotEmpty()) {
                val m = wire.removeFirst()
                n++
                assertTrue("no message loops", n < 20)
                if (drop(m)) continue
                val reply = if (m.to == "b") b.onReceived("ba", m.offer.seed, m.offer.day, m.offer.ack)
                else a.onReceived("ab", m.offer.seed, m.offer.day, m.offer.ack)
                reply?.let { wire.addLast(Msg(if (m.to == "b") "a" else "b", it)) }
            }
            delivered += n
            return n
        }

        fun sameKeys(): Boolean {
            // As the app's tick does: move both to today's key.
            a.advance()
            b.advance()
            val ca = a.channel("ab") ?: return false
            val cb = b.channel("ba") ?: return false
            return ca.tag(now)!!.toHex() == cb.tag(now)!!.toHex() && ca.role != cb.role
        }
    }

    @Test
    fun offerAndReplyLinkBothSides() {
        val p = Pair()
        p.offerFromA()
        assertEquals(2, p.deliverAll())
        assertTrue(p.a.isLinked("ab") && p.b.isLinked("ba"))
        assertTrue(p.sameKeys())
        // Linked: nothing more to offer.
        assertNull(p.a.offerFor("ab"))
        assertNull(p.b.offerFor("ba"))
    }

    @Test
    fun simultaneousOffersAgreeWithoutReplies() {
        val p = Pair()
        p.offerFromA()
        p.offerFromB()
        assertEquals(2, p.deliverAll())
        assertTrue(p.sameKeys())
    }

    @Test
    fun lostReplyIsRecoveredByTheResentOffer() {
        val p = Pair()
        p.offerFromA()
        p.deliverAll(drop = { it.offer.ack }) // b's reply never arrives
        assertTrue(p.b.isLinked("ba"))
        assertFalse(p.a.isLinked("ab"))
        assertNull("not re-sent too soon", p.a.offerFor("ab"))
        now += ContactLinks.RESEND_MS + 1
        p.offerFromA()
        p.deliverAll()
        assertTrue(p.sameKeys())
    }

    /** android-alignment-10 §1: both copies of a re-sent offer handled back to back. */
    @Test
    fun anOfferHandledTwiceGetsTheIdenticalAnswer() {
        val p = Pair()
        val first = p.a.offerFor("ab")!!
        now += ContactLinks.RESEND_MS + 1
        val again = p.a.offerFor("ab")!!
        assertArrayEquals(first.seed, again.seed)
        val r1 = p.b.onReceived("ba", first.seed, first.day, false)!!
        val r2 = p.b.onReceived("ba", again.seed, again.day, false)!!
        assertArrayEquals("never a new seed for a known one", r1.seed, r2.seed)
        assertEquals(r1.day, r2.day)
        assertTrue(r2.ack)
        assertNull(p.a.onReceived("ab", r1.seed, r1.day, true))
        assertNull(p.a.onReceived("ab", r2.seed, r2.day, true)) // no pending seed any more: ignored
        assertTrue(p.sameKeys())
    }

    @Test
    fun theAnswerIsKeptSevenDaysOrUntilThePairIsConfirmed() {
        val p = Pair()
        val offer = p.a.offerFor("ab")!!
        assertNotNull(p.b.onReceived("ba", offer.seed, offer.day, false))
        now += ContactLinks.ANSWER_KEEP_MS + 1
        assertTrue(p.b.advance())
        assertNull("too late: ignored", p.b.onReceived("ba", offer.seed, offer.day, false))
        assertTrue(p.b.isLinked("ba"))

        val q = Pair()
        val o = q.a.offerFor("ab")!!
        assertNotNull(q.b.onReceived("ba", o.seed, o.day, false))
        assertTrue(q.b.confirmed("ba")) // a CONTACT packet from a decrypted
        assertFalse(q.b.confirmed("ba"))
        assertNull(q.b.onReceived("ba", o.seed, o.day, false))
    }

    @Test
    fun crossingOffersWhereOneWasNeverSeenStillLink() {
        // a and b offer at the same time, but a's offer never reaches b (shown and deleted on an old app).
        val p = Pair()
        p.offerFromA()
        p.offerFromB()
        p.deliverAll(drop = { it.to == "b" })
        assertTrue(p.a.isLinked("ab"))
        assertFalse(p.b.isLinked("ba"))
        now += ContactLinks.RESEND_MS + 1
        p.offerFromB()
        p.deliverAll()
        assertTrue(p.sameKeys())
    }

    @Test
    fun aWipedPhoneLinksAgain() {
        val p = Pair()
        p.offerFromA()
        p.deliverAll()
        p.a = ContactLinks(clock) // Emergency Wipe on a's phone
        p.offerFromA()
        p.deliverAll()
        assertTrue(p.sameKeys())
    }

    @Test
    fun aReplyWithoutAnOfferIsIgnored() {
        val links = ContactLinks(clock)
        assertNull(links.onReceived("x", ByteArray(32) { 1 }, 20_000, ack = true))
        assertFalse(links.isLinked("x"))
        assertNull(links.onReceived("x", ByteArray(5), 20_000, ack = false))
    }

    @Test
    fun anOfferThatCouldNotBeSentDoesNotCount() {
        val links = ContactLinks(clock)
        val o1 = links.offerFor("x")!!
        links.offerFailed("x")
        val o2 = links.offerFor("x")!!
        assertArrayEquals("same seed: an answer to the first try still links", o1.seed, o2.seed)
        now += ContactLinks.RESEND_MS + 1
        assertNotNull(links.offerFor("x"))
        now += ContactLinks.RESEND_MS + 1
        assertNull(links.offerFor("x"))
    }

    @Test
    fun anAnswerThatCouldNotBeSentIsKeptForLater() {
        val p = Pair()
        val o = p.a.offerFor("ab")!!
        val answer = p.b.onReceived("ba", o.seed, o.day, false)!!
        val unsent = p.b.unsentAnswers().single()
        assertEquals("ba", unsent.first)
        assertArrayEquals(answer.seed, unsent.second.seed)
        assertTrue(unsent.second.ack)
        // Survives a restart.
        val reloaded = ContactLinks(clock).also { it.load(p.b.toJson()) }
        assertArrayEquals(answer.seed, reloaded.unsentAnswers().single().second.seed)
        p.b.answerSent("ba")
        assertTrue(p.b.unsentAnswers().isEmpty())
        assertNull(p.a.onReceived("ab", answer.seed, answer.day, true))
        assertTrue(p.sameKeys())
    }

    @Test
    fun linksSurviveSavingAndLoading() {
        val p = Pair()
        val o = p.a.offerFor("ab")!!
        val answer = p.b.onReceived("ba", o.seed, o.day, false)!!
        p.a.onReceived("ab", answer.seed, answer.day, true)
        val copy = ContactLinks(clock).also { it.load(p.a.toJson()) }
        assertEquals(p.a.channel("ab")!!.tag(now)!!.toHex(), copy.channel("ab")!!.tag(now)!!.toHex())
        // The kept answer survives too.
        val b2 = ContactLinks(clock).also { it.load(p.b.toJson()) }
        assertArrayEquals(answer.seed, b2.onReceived("ba", o.seed, o.day, false)!!.seed)
        // A pending offer survives too, and is not sent again before its time.
        val pending = ContactLinks(clock)
        pending.offerFor("c")
        assertNull(ContactLinks(clock).also { it.load(pending.toJson()) }.offerFor("c"))
    }

    @Test
    fun deletedContactsAreForgotten() {
        val links = ContactLinks(clock)
        links.offerFor("u1:c1")
        links.offerFor("u1:c2")
        links.offerFor("u2:c9")
        assertTrue(links.retain("u1:", setOf("u1:c2")))
        assertNull(links.offerFor("u1:c2")) // still pending, kept
        assertTrue(links.offerFor("u1:c1") != null) // was forgotten: a fresh offer
        // A deleted profile: everything under its prefix goes ("u1:" never matches "u10:").
        links.offerFor("u10:c1")
        assertTrue(links.retain("u1:", emptySet()))
        assertNotNull(links.offerFor("u1:c2"))
        assertNull(links.offerFor("u10:c1"))
        assertNull(links.offerFor("u2:c9"))
    }

    @Test
    fun aContactOnAnOlderAppIsOfferedTwiceAtMost() {
        val old = ContactLinks(clock) // its app shows our offers as text and ignores them
        val links = ContactLinks(clock)
        assertTrue(links.offerFor("old") != null)
        now += ContactLinks.RESEND_MS + 1
        assertTrue(links.offerFor("old") != null)
        now += ContactLinks.RESEND_MS + 1
        assertNull(links.offerFor("old"))
        assertNull(ContactLinks(clock).also { it.load(links.toJson()) }.offerFor("old"))
        // Once it updates, its own offer links us (it crosses our pending one: no reply) ...
        val theirs = old.offerFor("new")!!
        assertNull(links.onReceived("old", theirs.seed, theirs.day, ack = false))
        assertTrue(links.isLinked("old"))
        // ... and, as it never saw our offer, its re-sent offer gets our offered seed as the answer.
        now += ContactLinks.RESEND_MS + 1
        val again = old.offerFor("new")!!
        val answer = links.onReceived("old", again.seed, again.day, ack = false)!!
        assertNull(old.onReceived("new", answer.seed, answer.day, ack = true))
        links.advance()
        old.advance()
        assertEquals(links.channel("old")!!.tag(now)!!.toHex(), old.channel("new")!!.tag(now)!!.toHex())
    }
}
