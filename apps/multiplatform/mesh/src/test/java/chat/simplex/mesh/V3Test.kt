package chat.simplex.mesh

import chat.simplex.mesh.core.ContactChannel
import chat.simplex.mesh.core.MediaConversation
import chat.simplex.mesh.core.MeshEvent
import chat.simplex.mesh.core.TeamChannel
import chat.simplex.mesh.protocol.ContactBody
import chat.simplex.mesh.protocol.ControlFrame
import chat.simplex.mesh.protocol.MediaChunk
import chat.simplex.mesh.protocol.MediaHeader
import chat.simplex.mesh.protocol.MediaType
import chat.simplex.mesh.protocol.MeshCrypto
import chat.simplex.mesh.protocol.MeshIdentity
import chat.simplex.mesh.protocol.MeshPacket
import chat.simplex.mesh.protocol.OpaquePacket
import chat.simplex.mesh.protocol.PacketType
import chat.simplex.mesh.protocol.toHex
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** Wire v3: linked contacts, photos and voice notes. */
class V3Test {

    private fun chain(net: VirtualNet, names: List<String>) = names.zipWithNext().forEach { (a, b) -> net.link(a, b) }

    private fun seed(b: Int) = ByteArray(32) { (b + it).toByte() }

    /** Links nodes [a] and [b] as contacts (as the SimpleX seed swap would). */
    private fun pair(net: VirtualNet, a: String, b: String): Pair<ContactChannel, ContactChannel> {
        val day = TeamChannel.dayOf(net.now)
        val sa = MeshCrypto.randomBytes(32)
        val sb = MeshCrypto.randomBytes(32)
        val ca = ContactChannel.fromSeeds("$a->$b", sa, day, sb, day, net.now)!!
        val cb = ContactChannel.fromSeeds("$b->$a", sb, day, sa, day, net.now)!!
        net.node(a).router.setContacts(listOf(ca))
        net.node(b).router.setContacts(listOf(cb))
        return ca to cb
    }

    private inline fun <reified T : MeshEvent> VirtualNet.Node.ev(): List<T> = events.filterIsInstance<T>()

    // ---- Pair keys ----

    @Test
    fun bothSidesDeriveTheSamePairWithOppositeRoles() {
        val now = 1_790_000_000_000L
        val day = TeamChannel.dayOf(now)
        val a = ContactChannel.fromSeeds("a", seed(1), day - 3, seed(2), day - 1, now)!!
        val b = ContactChannel.fromSeeds("b", seed(2), day - 1, seed(1), day - 3, now)!!
        assertEquals(0, a.role)
        assertEquals(1, b.role)
        assertEquals(day - 1, a.startDay)
        assertArrayEquals(a.tag(now), b.tag(now))
        assertArrayEquals(a.messageKey(now), b.messageKey(now))
        // Before the pair's first day there is no key; the day before today is gone after the grace period.
        assertNull(a.keyFor(day - 2))
        assertNull(ContactChannel.fromSeeds("x", seed(1), day, seed(1), day, now))
        // A different pair, and a team with the same key material, never collide.
        val other = ContactChannel.fromSeeds("c", seed(1), day, seed(3), day, now)!!
        assertNotEquals(a.tag(now)!!.toHex(), other.tag(now)!!.toHex())
    }

    @Test
    fun pairTagChangesEveryHour() {
        val now = 1_790_000_000_000L
        val day = TeamChannel.dayOf(now)
        val a = ContactChannel.fromSeeds("a", seed(1), day, seed(2), day, now)!!
        assertNotEquals(a.tag(now)!!.toHex(), a.tag(now + TeamChannel.HOUR_MS)!!.toHex())
    }

    // ---- Contact messages ----

    @Test
    fun contactMessageReachesOnlyTheContactAndIsAcknowledged() {
        val net = VirtualNet()
        chain(net, listOf("a", "b", "c", "d"))
        net.run(1_000)
        val (ca, _) = pair(net, "a", "d")
        val uid = MeshCrypto.randomBytes(16)
        assertNotNull(net.node("a").router.sendContact(ca, ContactBody.Kind.MESSAGE, uid, "on my way".toByteArray()))
        net.run(10_000)
        val got = net.node("d").ev<MeshEvent.ContactMessage>()
        assertEquals(1, got.size)
        assertEquals("on my way", got.single().text)
        assertEquals("d->a", got.single().contactId)
        assertEquals(uid.toHex(), got.single().uidHex)
        assertEquals(3, got.single().hops)
        assertEquals(uid.toHex(), net.node("a").ev<MeshEvent.ContactAck>().single().uidHex)
        for (relay in listOf("b", "c")) assertTrue("$relay reads nothing", net.node(relay).events.isEmpty())
    }

    @Test
    fun ownPacketReflectedBackIsDropped() {
        // x holds the same side of the pair as a (a copy of a's keys): it must not take a's packets as the contact's.
        val net = VirtualNet()
        chain(net, listOf("a", "x"))
        net.run(1_000)
        val day = TeamChannel.dayOf(net.now)
        val sa = seed(5)
        val sb = seed(9)
        val ca = ContactChannel.fromSeeds("a", sa, day, sb, day, net.now)!!
        net.node("a").router.setContacts(listOf(ca))
        net.node("x").router.setContacts(listOf(ContactChannel.fromSeeds("x", sa, day, sb, day, net.now)!!))
        net.node("a").router.sendContact(ca, ContactBody.Kind.MESSAGE, MeshCrypto.randomBytes(16), "hi".toByteArray())
        net.run(5_000)
        assertTrue(net.node("x").ev<MeshEvent.ContactMessage>().isEmpty())
    }

    @Test
    fun pingIsAnsweredAtMostOncePerMinute() {
        val net = VirtualNet()
        chain(net, listOf("a", "b"))
        net.run(1_000)
        val (ca, _) = pair(net, "a", "b")
        repeat(3) { net.node("a").router.pingContact(ca); net.run(2_000) }
        assertEquals("b saw all three pings", 3, net.node("b").ev<MeshEvent.ContactNearby>().size)
        assertEquals("a got one pong", 1, net.node("a").ev<MeshEvent.ContactNearby>().size)
        net.run(60_000)
        net.node("a").router.pingContact(ca)
        net.run(2_000)
        assertEquals(2, net.node("a").ev<MeshEvent.ContactNearby>().size)
    }

    @Test
    fun strangersCannotReadOrForgeContactPackets() {
        val net = VirtualNet()
        chain(net, listOf("a", "m", "b"))
        net.run(1_000)
        val (_, cb) = pair(net, "a", "b")
        // m knows the tag (it is public) but not the key.
        val forged = MeshPacket.create(MeshIdentity.generate(), PacketType.CONTACT, 7, target = cb.tag(net.now)!!, timestamp = net.now) { aad ->
            MeshCrypto.seal(MeshCrypto.randomBytes(32), ContactBody.encode(ContactBody.Kind.MESSAGE, 0, ByteArray(16), "fake".toByteArray()), aad)
        }
        net.inject("m", "b", forged.encode())
        net.run(5_000)
        assertTrue(net.node("b").events.isEmpty())
    }

    // ---- Media ----

    @Test
    fun photoReachesContactAcrossThreeHops() {
        val net = VirtualNet()
        chain(net, listOf("a", "b", "c", "d"))
        net.startTicks()
        net.run(1_000)
        val (ca, _) = pair(net, "a", "d")
        val photo = Random(7).nextBytes(40_000)
        val header = MediaHeader.create(MediaType.PHOTO, photo, 0, 800, 600, "", "gate 3")
        val uid = MeshCrypto.randomBytes(16)
        assertTrue(net.node("a").router.sendContactMedia(ca, uid, header, photo))
        net.run(60_000)
        val got = net.node("d").ev<MeshEvent.MediaReceived>().single()
        assertArrayEquals(photo, got.data)
        assertEquals(MediaConversation.Contact("d->a"), got.conversation)
        assertEquals("gate 3", got.caption)
        assertEquals(MediaType.PHOTO, got.type)
        assertTrue(net.node("d").ev<MeshEvent.MediaProgress>().isNotEmpty())
        assertEquals("delivered", uid.toHex(), net.node("a").ev<MeshEvent.ContactAck>().single().uidHex)
        for (relay in listOf("b", "c")) assertTrue(net.node(relay).ev<MeshEvent.MediaStarted>().isEmpty())
    }

    @Test
    fun voiceNoteReachesTeamMembers() {
        val net = VirtualNet()
        chain(net, listOf("a", "b", "c"))
        net.startTicks()
        net.run(1_000)
        val team = TeamChannel.create("medics", net.now)
        net.node("a").router.setChannels(listOf(team))
        net.node("c").router.setChannels(listOf(team))
        net.node("a").router.nickname = "amina"
        val voice = Random(3).nextBytes(20_000)
        val header = MediaHeader.create(MediaType.VOICE, voice, 12_000, 0, 0, "amina", "")
        assertTrue(net.node("a").router.sendTeamMedia(team, MeshCrypto.randomBytes(16), header, voice))
        net.run(60_000)
        val got = net.node("c").ev<MeshEvent.MediaReceived>().single()
        assertArrayEquals(voice, got.data)
        assertEquals(12_000, got.durationMs)
        val from = got.conversation as MediaConversation.Team
        assertEquals(team.localId, from.teamId)
        assertEquals("amina", from.nickname)
        assertEquals(net.node("a").identity.peerIdHex, from.senderPeerIdHex)
        assertTrue(net.node("b").ev<MeshEvent.MediaStarted>().isEmpty())
    }

    @Test
    fun lateJoinerCatchesUpOnAPhoto() {
        val net = VirtualNet()
        chain(net, listOf("a", "b"))
        net.startTicks()
        net.run(1_000)
        val (ca, _) = pair(net, "a", "c")
        val photo = Random(9).nextBytes(10_000)
        net.node("a").router.sendContactMedia(ca, MeshCrypto.randomBytes(16), MediaHeader.create(MediaType.PHOTO, photo, 0, 10, 10, "", ""), photo)
        net.run(30_000)
        net.unlink("a", "b")
        net.link("b", "c")
        net.run(60_000)
        assertArrayEquals(photo, net.node("c").ev<MeshEvent.MediaReceived>().single().data)
    }

    @Test
    fun tamperedChunksAreIgnored() {
        val photo = Random(1).nextBytes(5_000)
        val header = MediaHeader.create(MediaType.PHOTO, photo, 0, 1, 1, "", "")
        val key = MediaChunk.chunkKey(header.mediaKey)
        val id = header.mediaId
        val sealed = MediaChunk.seal(key, 0, MediaChunk.split(photo)[0], id)
        assertArrayEquals(MediaChunk.split(photo)[0], MediaChunk.open(key, sealed, id))
        // Resends encrypt to exactly the same bytes (no nonce reuse with different input).
        assertArrayEquals(sealed, MediaChunk.seal(key, 0, MediaChunk.split(photo)[0], id))
        // Another item's ID: the media ID is authenticated.
        assertNull(MediaChunk.open(key, sealed, ByteArray(8) { 7 }))
        sealed[5] = (sealed[5].toInt() xor 1).toByte()
        assertNull(MediaChunk.open(key, sealed, id))
        // Moved to another index: the index is authenticated too.
        val moved = MediaChunk.seal(key, 1, MediaChunk.split(photo)[0], id).also { it[0] = 0 }
        assertNull(MediaChunk.open(key, moved, id))
    }

    // ---- Replays (android-alignment-9 §2.3) ----

    private fun contactPacket(c: ContactChannel, kind: ContactBody.Kind, uid: ByteArray, time: Long, text: String = ""): MeshPacket =
        MeshPacket.create(MeshIdentity.generate(), PacketType.CONTACT, 7, target = c.tag(time)!!, timestamp = time) { aad ->
            MeshCrypto.seal(c.messageKey(time)!!, ContactBody.encode(kind, c.role, uid, text.toByteArray()), aad)
        }

    @Test
    fun aReplayedOldPingGetsNoPongAndDoesNotShowNearby() {
        val net = VirtualNet()
        chain(net, listOf("a", "b"))
        net.run(1_000)
        val (ca, _) = pair(net, "a", "b")
        val old = contactPacket(ca, ContactBody.Kind.PING, MeshCrypto.randomBytes(16), net.now - 10 * 60_000)
        net.inject("a", "b", old.encode())
        net.run(5_000)
        assertEquals("decrypted", 1, net.node("b").ev<MeshEvent.ContactHeard>().size)
        assertTrue("not nearby", net.node("b").ev<MeshEvent.ContactNearby>().isEmpty())
        assertTrue("no pong", net.node("a").ev<MeshEvent.ContactNearby>().isEmpty())
        // A fresh ping is answered.
        net.node("a").router.pingContact(ca)
        net.run(5_000)
        assertEquals(1, net.node("a").ev<MeshEvent.ContactNearby>().size)
    }

    @Test
    fun oldNewItemsAreAcknowledgedButOldRepeatsAreNot() {
        val net = VirtualNet()
        chain(net, listOf("a", "b"))
        net.run(1_000)
        val (ca, _) = pair(net, "a", "b")
        val uid = MeshCrypto.randomBytes(16)
        // Store-and-forward: an hour-old message that is new to b still gets its ACK.
        net.inject("a", "b", contactPacket(ca, ContactBody.Kind.MESSAGE, uid, net.now - 60 * 60_000, "hi").encode())
        net.run(5_000)
        assertEquals(1, net.node("b").ev<MeshEvent.ContactMessage>().size)
        assertEquals(1, net.node("a").ev<MeshEvent.ContactAck>().size)
        // The same item in another old packet (a replay): no ACK, so nobody learns b is here.
        net.inject("a", "b", contactPacket(ca, ContactBody.Kind.MESSAGE, uid, net.now - 30 * 60_000, "hi").encode())
        net.run(5_000)
        assertEquals(1, net.node("a").ev<MeshEvent.ContactAck>().size)
        // A real resend is fresh: confirmed again.
        net.inject("a", "b", contactPacket(ca, ContactBody.Kind.MESSAGE, uid, net.now, "hi").encode())
        net.run(5_000)
        assertEquals(2, net.node("a").ev<MeshEvent.ContactAck>().size)
    }

    @Test
    fun v3PacketsAreServedToALinkTwicePerTenMinutesAtMost() {
        val net = VirtualNet()
        chain(net, listOf("a", "z"))
        net.run(1_000)
        val day = TeamChannel.dayOf(net.now)
        val c = ContactChannel.fromSeeds("a", seed(1), day, seed(2), day, net.now)!!
        net.node("a").router.setContacts(listOf(c))
        val packet = net.node("a").router.sendContact(c, ContactBody.Kind.MESSAGE, MeshCrypto.randomBytes(16), "x".toByteArray())!!
        net.run(2_000)
        fun copiesAtZ() = net.node("z").rawIn.count { MeshPacket.decode(it)?.shortId == packet.shortId }
        val before = copiesAtZ()
        // A v2 phone asks for the same v3 ID again every 10 s (it keeps v3 packets unread, never "seen").
        repeat(5) {
            net.inject("z", "a", ControlFrame.Request(listOf(packet.shortId)).encode())
            net.run(10_000)
        }
        assertEquals(before + 2, copiesAtZ())
        net.run(10 * 60_000)
        net.inject("z", "a", ControlFrame.Request(listOf(packet.shortId)).encode())
        net.run(2_000)
        assertEquals(before + 3, copiesAtZ())
    }

    @Test
    fun mediaHeadersOverTheLimitsAreRejected() {
        val ok = MediaHeader.create(MediaType.PHOTO, ByteArray(3_000), 0, 1, 1, "n", "c")
        val bytes = ok.encode()
        val decoded = MediaHeader.decode(bytes)!!
        assertEquals(2, decoded.chunkCount)
        assertEquals("c", decoded.caption)
        // chunkCount that doesn't match the size
        assertNull(MediaHeader.decode(bytes.copyOf().also { it[5] = 3 }))
        // a photo bigger than 48 KB
        assertNull(MediaHeader.decode(bytes.copyOf().also { it[1] = 0; it[2] = 1; it[3] = 0; it[4] = 0; it[5] = 43 }))
        // trailing garbage
        assertNull(MediaHeader.decode(bytes + 0))
    }

    // ---- Compatibility with v2 phones ----

    @Test
    fun v3PacketsUseTheIdV2PhonesComputeWhenRelayingThemUnread() {
        val now = 1_790_000_000_000L
        val day = TeamChannel.dayOf(now)
        val c = ContactChannel.fromSeeds("a", seed(1), day, seed(2), day, now)!!
        val packet = MeshPacket.create(MeshIdentity.generate(), PacketType.CONTACT, 7, target = c.tag(now)!!, timestamp = now) { aad ->
            MeshCrypto.seal(c.messageKey(now)!!, ContactBody.encode(ContactBody.Kind.PING, c.role, ByteArray(16)), aad)
        }
        val bytes = packet.encode()
        assertEquals(3, bytes[1].toInt())
        assertEquals(OpaquePacket.idOf(bytes), packet.shortId)
        assertEquals(packet.shortId, packet.relayed().shortId)
        assertEquals(packet.shortId, MeshPacket.decode(packet.relayed().encode())!!.shortId)
        // A v3 phone reads it, so it never treats it as unreadable.
        assertNull(OpaquePacket.decode(bytes))
        // v2 types keep version byte 2 and the v2 dedup ID.
        val pub = MeshPacket.create(MeshIdentity.generate(), PacketType.PUBLIC, 7, timestamp = now) { ByteArray(3) }
        assertEquals(2, pub.encode()[1].toInt())
        assertEquals(MeshPacket.shortIdOf(pub.origin, pub.messageId), pub.shortId)
    }

    @Test
    fun malformedVersionTypeCombinationsAreDropped() {
        val pub = MeshPacket.create(MeshIdentity.generate(), PacketType.PUBLIC, 7, timestamp = 1L) { ByteArray(3) }.encode()
        // A v2 type in a v3 header: neither read nor relayed.
        val wrong = pub.copyOf().also { it[1] = 3 }
        assertNull(MeshPacket.decode(wrong))
        assertNull(OpaquePacket.decode(wrong))
        // A media chunk may travel at most 5 hops.
        val chunk = MeshPacket.create(MeshIdentity.generate(), PacketType.MEDIA_CHUNK, 5, timestamp = 1L) { ByteArray(20) }.encode()
        assertNotNull(MeshPacket.decode(chunk))
        assertNull(MeshPacket.decode(chunk.copyOf().also { it[4] = 7 }))
    }
}
