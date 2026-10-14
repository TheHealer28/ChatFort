package chat.simplex.mesh

import chat.simplex.mesh.core.MeshEvent
import chat.simplex.mesh.core.MeshRouter
import chat.simplex.mesh.core.TeamChannel
import chat.simplex.mesh.protocol.MeshCrypto
import chat.simplex.mesh.protocol.MeshIdentity
import chat.simplex.mesh.protocol.MeshPacket
import chat.simplex.mesh.protocol.MessageBody
import chat.simplex.mesh.protocol.OpaquePacket
import chat.simplex.mesh.protocol.PacketType
import chat.simplex.mesh.protocol.toHex
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Tests for the wire-version-2 security fixes. */
class SecurityTest {

    private fun chain(net: VirtualNet, names: List<String>) = names.zipWithNext().forEach { (a, b) -> net.link(a, b) }

    private fun decodedIn(node: VirtualNet.Node): List<MeshPacket> = node.rawIn.mapNotNull { MeshPacket.decode(it) }

    // ---- Hop limit ----

    @Test
    fun relaysCannotRaiseTheHopLimit() {
        val id = MeshIdentity.generate()
        val packet = MeshPacket.create(id, PacketType.PUBLIC, 3) { MessageBody.encode("a", "x") }
        val bytes = packet.encode()
        // ttl above the signed maxTtl: rejected outright.
        assertNull(MeshPacket.decode(bytes.copyOf().also { it[3] = 7 }))
        // maxTtl raised as well: parses, but the signature no longer holds.
        val raised = bytes.copyOf().also { it[3] = 7; it[4] = 7 }
        assertFalse(MeshPacket.decode(raised)!!.verify())
        // Lowering ttl is what relaying does: still valid, and hops go up accordingly.
        val relayed = MeshPacket.decode(bytes.copyOf().also { it[3] = 1 })!!
        assertTrue(relayed.verify())
        assertEquals(2, relayed.hops)
    }

    // ---- Sealed private messages ----

    @Test
    fun privateMessagesHideSenderAndRecipientFromRelays() {
        val net = VirtualNet()
        val p = List(5) { "p$it" }
        chain(net, p)
        net.run(1_000)
        val recipientKey = net.node("p4").identity.publicKey
        net.node("p0").router.sendDirect(recipientKey, "north exit")!!
        net.run(10_000)

        assertEquals("north exit", net.node("p4").messages.single().text)
        assertEquals(net.node("p0").identity.peerIdHex, net.node("p4").messages.single().peerIdHex)
        assertEquals(1, net.node("p0").acks.size)

        val sender = net.node("p0").identity.peerId
        val recipient = net.node("p4").identity.peerId
        val relayed = decodedIn(net.node("p2")).filter { it.type == PacketType.DIRECT }
        assertEquals("the message and its receipt pass through p2", 2, relayed.size)
        for (packet in relayed) {
            assertFalse("sender visible to a relay", packet.origin.contentEquals(sender))
            assertFalse("recipient visible to a relay", packet.origin.contentEquals(recipient))
            assertArrayEquals(MeshPacket.NO_TARGET, packet.target)
            val raw = packet.encode().toHex()
            assertFalse(raw.contains(net.node("p0").identity.publicKey.toHex()))
            assertFalse(raw.contains(recipientKey.toHex()))
        }
        for (i in 1..3) assertTrue(net.node(p[i]).messages.isEmpty())
    }

    @Test
    fun aRecipientCannotPassOffAPrivateMessageAsSentToSomeoneElse() {
        // Bob gets a message from Alice and re-encrypts Alice's inner signed body to Carol.
        // Carol must reject it: the signature is bound to Bob's key.
        val net = VirtualNet()
        chain(net, listOf("alice", "bob", "carol"))
        net.run(1_000)
        val alice = net.node("alice").identity
        val bob = net.node("bob").identity
        val carol = net.node("carol").identity
        val now = net.now
        val messageId = MeshCrypto.randomBytes(16)
        val header = chat.simplex.mesh.protocol.SealedBody.Header(PacketType.DIRECT, messageId, now, MeshPacket.NO_TARGET)
        val innerForBob = chat.simplex.mesh.protocol.SealedBody.seal(alice, chat.simplex.mesh.protocol.SealedBody.Kind.MESSAGE, MessageBody.encode("alice", "for bob only"), header, bob.publicKey)
        val forged = MeshPacket.create(MeshIdentity.generate(), PacketType.DIRECT, 7, timestamp = now, messageId = messageId) { aad ->
            val eph = MeshCrypto.generateKeyPair()
            val ephKey = MeshCrypto.encodePublicKey(eph.public)
            val key = MeshCrypto.hkdf(MeshCrypto.ecdh(eph.private, MeshCrypto.decodePublicKey(carol.publicKey)!!), ephKey + carol.publicKey, "chatfort-mesh-direct-v2".toByteArray(), 32)
            ephKey + MeshCrypto.seal(key, innerForBob, aad)
        }
        net.inject("bob", "carol", forged.encode())
        net.run(5_000)
        assertTrue(net.node("carol").messages.isEmpty())
    }

    @Test
    fun everySealedPacketHasFreshOneTimeKeysAndNonces() {
        // Reusing an ephemeral key + nonce under AES-GCM would leak plaintext and allow forgery.
        val net = VirtualNet()
        val sender = net.node("a").router
        val bobKey = net.node("b").identity.publicKey
        val team = TeamChannel.create("t", net.now)
        val directs = List(5) { sender.sendDirect(bobKey, "same text")!! }
        val channels = List(5) { sender.sendChannel(team, "same text")!! }
        fun distinct(list: List<ByteArray>) = list.map { it.toHex() }.toSet().size == list.size
        assertTrue("outer one-time keys", distinct((directs + channels).map { it.originKey }))
        assertTrue("DIRECT ephemeral ECDH keys", distinct(directs.map { it.payload.copyOfRange(0, 65) }))
        assertTrue("DIRECT nonces", distinct(directs.map { it.payload.copyOfRange(65, 77) }))
        assertTrue("CHANNEL nonces", distinct(channels.map { it.payload.copyOfRange(0, 12) }))
    }

    @Test
    fun handoverIsAcceptedOnlyFromTheContactsCurrentKey() {
        val k0 = MeshIdentity.generate()
        val k1 = MeshIdentity.generate()
        val k2 = MeshIdentity.generate()
        val firstHandover = MeshEvent.Rekey(k0.peerIdHex, k1.publicKey) // k0 -> k1, signed by k0
        val secondHandover = MeshEvent.Rekey(k1.peerIdHex, k2.publicKey) // k1 -> k2, signed by k1
        assertTrue(firstHandover.isFromCurrentKey(k0.publicKey))
        assertTrue(secondHandover.isFromCurrentKey(k1.publicKey))
        // Replayed after the contact moved on to k2: rejected.
        assertFalse(firstHandover.isFromCurrentKey(k2.publicKey))
        assertFalse(secondHandover.isFromCurrentKey(k2.publicKey))
        assertFalse(firstHandover.isFromCurrentKey(null))
    }

    // ---- Identity rotation ----

    @Test
    fun rotatedIdentityKeepsThePrivateConversationGoing() {
        val net = VirtualNet()
        chain(net, listOf("a", "r", "b"))
        net.run(1_000)
        val aOldKey = net.node("a").identity.publicKey
        net.node("b").router.sendDirect(aOldKey, "hello a")!!
        net.run(5_000)
        assertEquals(1, net.node("a").messages.size)

        // a rotates: b gets the handover; r (a relay) learns nothing.
        val next = MeshIdentity.generate()
        net.node("a").router.rotateIdentity(next, listOf(net.node("b").identity.publicKey))
        net.run(5_000)
        val rekey = net.node("b").events.filterIsInstance<MeshEvent.Rekey>().single()
        assertEquals(MeshCrypto.peerId(aOldKey).toHex(), rekey.peerIdHex)
        assertArrayEquals(next.publicKey, rekey.newKey)
        assertTrue(net.node("r").events.none { it is MeshEvent.Rekey })

        // A message still addressed to the old key (sent before b noticed) is still read...
        net.node("b").router.sendDirect(aOldKey, "late, to the old key")!!
        // ...and new messages go to the new key.
        net.node("b").router.sendDirect(rekey.newKey, "to the new key")!!
        net.run(5_000)
        val texts = net.node("a").messages.map { it.text }
        assertTrue(texts.containsAll(listOf("late, to the old key", "to the new key")))
    }

    // ---- Teams ----

    @Test
    fun teamTagChangesEveryHourAndCodesDoNotReadEarlierDays() {
        val day = 20_000L
        val t0 = day * TeamChannel.DAY_MS + 10 * TeamChannel.HOUR_MS + 5 * 60_000
        val team = TeamChannel.create("marshals", t0 - 2 * TeamChannel.DAY_MS).advancedTo(t0)
        assertEquals(day, team.day)
        val tag1 = team.tag(t0)!!
        val tag2 = team.tag(t0 + TeamChannel.HOUR_MS)!!
        assertFalse(tag1.contentEquals(tag2))
        assertArrayEquals(tag1, team.tag(t0 + 60_000))

        // A code shown today can't open yesterday's messages, and doesn't keep older keys.
        val fromTodaysCode = TeamChannel.fromCode("marshals", team.key, team.day).advancedTo(t0)
        assertNull(fromTodaysCode.messageKey(t0 - TeamChannel.DAY_MS))
        assertNotNull(fromTodaysCode.messageKey(t0))
        assertTrue(fromTodaysCode.sameTeamAs(team))

        // Yesterday's key is kept only for the first hours after midnight.
        val justAfterMidnight = TeamChannel.create("x", t0).advancedTo(t0 + (TeamChannel.DAY_MS - 10 * TeamChannel.HOUR_MS) + TeamChannel.HOUR_MS)
        assertNotNull(justAfterMidnight.keyFor(justAfterMidnight.day - 1))
        val laterThatDay = justAfterMidnight.advancedTo(justAfterMidnight.day * TeamChannel.DAY_MS + 13 * TeamChannel.HOUR_MS)
        assertNull(laterThatDay.keyFor(laterThatDay.day - 1))
    }

    @Test
    fun teamMessagesDoNotRevealTheSenderToRelays() {
        val net = VirtualNet()
        chain(net, listOf("a", "relay", "b"))
        val team = TeamChannel.create("medics", net.now)
        net.node("a").router.setChannels(listOf(team))
        net.node("b").router.setChannels(listOf(TeamChannel.fromCode("medics", team.key, team.day)))
        net.run(1_000)
        net.node("a").router.sendChannel(team, "stretcher needed")!!
        net.run(5_000)
        assertEquals("stretcher needed", net.node("b").messages.single().text)
        val seen = decodedIn(net.node("relay")).single { it.type == PacketType.CHANNEL }
        assertFalse(seen.origin.contentEquals(net.node("a").identity.peerId))
        assertFalse(seen.encode().toHex().contains(net.node("a").identity.publicKey.toHex()))
    }

    // ---- Rate limits ----

    @Test
    fun catchUpCannotBypassTheSenderRateLimit() {
        val net = VirtualNet()
        net.node("spammer")
        net.node("b")
        // Written while alone, so it all arrives later as catch-up.
        repeat(150) { net.node("spammer").router.sendPublic("backlog $it") }
        net.run(1_000)
        net.link("spammer", "b")
        net.run(20_000)
        val got = net.node("b").messages.size
        assertTrue("delivered $got in the first 20 s", got <= MeshRouter.CATCHUP_ORIGIN_RATE_PER_MIN.toInt() + 11)
        assertTrue("some of the backlog does arrive", got >= 30)
    }

    @Test
    fun floodOfThrowawayIdentitiesIsLimitedPerLink() {
        val net = VirtualNet()
        chain(net, listOf("attacker", "b"))
        net.run(1_000)
        repeat(400) {
            val throwaway = MeshIdentity.generate()
            val p = MeshPacket.create(throwaway, PacketType.PUBLIC, 7, timestamp = net.now) { MessageBody.encode("x", "flood $it") }
            net.inject("attacker", "b", p.encode())
        }
        net.run(5_000)
        val got = net.node("b").messages.size
        assertTrue("delivered $got", got <= MeshRouter.NEW_ORIGIN_RATE_PER_MIN.toInt() + 5)
    }

    // ---- Forward compatibility ----

    @Test
    fun packetsFromANewerVersionAreRelayedButNotRead() {
        val net = VirtualNet()
        chain(net, listOf("a", "b", "c"))
        net.run(1_000)
        val future = byteArrayOf(MeshPacket.MAGIC.toByte(), 3, 9, 5, 5) + MeshCrypto.randomBytes(120)
        net.inject("a", "b", future)
        net.inject("a", "b", future) // duplicates are dropped
        net.run(5_000)
        val atC = net.node("c").rawIn.filter { it[1].toInt() == 3 }
        assertEquals(1, atC.size)
        assertEquals("ttl went down by one", 4, atC.single()[3].toInt())
        assertTrue(net.node("c").events.isEmpty())
        assertNotNull(OpaquePacket.decode(atC.single()))
        // Out-of-range fields are not relayed.
        assertNull(OpaquePacket.decode(byteArrayOf(MeshPacket.MAGIC.toByte(), 3, 9, 6, 5) + ByteArray(10)))
    }

    @Test
    fun nicknamesAreCutWithoutSplittingEmoji() {
        val s = "a".repeat(23) + "😀" + "b"
        val cut = MessageBody.truncateChars(s, 24)
        assertEquals("a".repeat(23) + "😀", cut)
        assertEquals("ab", MessageBody.truncateChars("ab", 24))
    }

    @Test
    fun reassemblerDoesNotMixAStaleFragmentWithANewPacket() {
        val r = chat.simplex.mesh.protocol.Reassembler()
        // Packet with seq 5 loses its last fragment...
        r.accept(byteArrayOf(5, 0, 2, 1, 1), 0)
        // ...and 256 packets later seq 5 is reused for a new two-fragment packet.
        assertNull(r.accept(byteArrayOf(5, 0, 2, 9, 9), 1))
        assertArrayEquals(byteArrayOf(9, 9, 8, 8), r.accept(byteArrayOf(5, 1, 2, 8, 8), 2))
    }
}
