package chat.simplex.mesh

import chat.simplex.mesh.core.TeamChannel
import chat.simplex.mesh.protocol.MeshCrypto
import chat.simplex.mesh.protocol.MeshIdentity
import chat.simplex.mesh.protocol.MeshPacket
import chat.simplex.mesh.protocol.MessageBody
import chat.simplex.mesh.protocol.PacketType
import chat.simplex.mesh.protocol.SealedBody
import chat.simplex.mesh.protocol.toHex
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigInteger

/**
 * Wire-version-2 test vectors for other implementations (iOS). Every value is printed; the fixed
 * parts are asserted so a change to the format fails here first. ECDSA signatures are randomised,
 * so packets are given as "verify this" vectors rather than byte-exact outputs.
 */
class VectorsTest {

    private fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }

    private val aliceScalar = BigInteger("1111111111111111111111111111111111111111111111111111111111111111", 16)
    private val bobScalar = BigInteger("2222222222222222222222222222222222222222222222222222222222222222", 16)
    private val ephScalar = BigInteger("3333333333333333333333333333333333333333333333333333333333333333", 16)

    private fun print(name: String, value: String) = println("VECTOR $name = $value")

    @Test
    fun keysAndPeerIds() {
        val alice = MeshIdentity.of(MeshCrypto.keyPairFromScalar(aliceScalar))
        print("alice.publicKey", alice.publicKey.toHex())
        print("alice.peerId", alice.peerIdHex)
        // Cross-check the test-only scalar multiplication against the platform: sign with the scalar key,
        // verify with the derived public key.
        val sig = MeshCrypto.sign(alice.privateKey, "x".toByteArray())
        assertTrue(MeshCrypto.verify(MeshCrypto.decodePublicKey(alice.publicKey)!!, "x".toByteArray(), sig))
        assertEquals(MeshCrypto.sha256(alice.publicKey).copyOf(8).toHex(), alice.peerIdHex)
    }

    @Test
    fun signedPublicPacketIncludingHighS() {
        val alice = MeshIdentity.of(MeshCrypto.keyPairFromScalar(aliceScalar))
        val packet = MeshPacket.create(
            alice, PacketType.PUBLIC, 7, timestamp = 1_790_000_000_000L, messageId = ByteArray(16) { it.toByte() }
        ) { MessageBody.encode("anon1234", "gate 3 is open") }
        assertTrue(packet.verify())
        print("public.packet", packet.encode().toHex())
        print("public.signedBytes", packet.signedBytes().toHex())

        // The same signature in both forms, s and n - s ("low S" / "high S"): Android signs either and accepts both.
        for ((name, high) in listOf("lowS" to false, "highS" to true)) {
            val sig = withS(packet.signature, high)
            val variant = MeshPacket(packet.type, packet.ttl, packet.maxTtl, packet.flags, packet.messageId, packet.origin, packet.timestamp, packet.target, packet.originKey, packet.payload, sig)
            assertTrue(variant.verify())
            print("public.packet.$name", variant.encode().toHex())
        }
    }

    @Test
    fun channelMessageWithFixedNonce() {
        val key32 = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        val day = 20_717L
        val t = day * TeamChannel.DAY_MS + 3_600_000L * 9 + 42_000
        val team = TeamChannel.fromCode("medics", key32, day).advancedTo(t)
        val tag = team.tag(t)!!
        val messageKey = team.messageKey(t)!!
        print("channel.day", day.toString())
        print("channel.timestamp", t.toString())
        print("channel.tag", tag.toHex())
        print("channel.messageKey", messageKey.toHex())
        print("channel.ratchet(key32)", TeamChannel.ratchet(key32).toHex())
        val aad = ByteArray(1 + 16 + 8 + 8 + 8).also { it[0] = PacketType.CHANNEL.code.toByte() }
        val sealed = MeshCrypto.sealWithNonce(messageKey, "hello team".toByteArray(), aad, ByteArray(12) { 7 })
        print("channel.aad", aad.toHex())
        print("channel.sealed(nonce=07*12, plaintext='hello team')", sealed.toHex())
        assertArrayEquals("hello team".toByteArray(), MeshCrypto.open(messageKey, sealed, aad))
    }

    @Test
    fun directMessageFromFixedKeys() {
        val alice = MeshIdentity.of(MeshCrypto.keyPairFromScalar(aliceScalar))
        val bob = MeshIdentity.of(MeshCrypto.keyPairFromScalar(bobScalar))
        val eph = MeshCrypto.keyPairFromScalar(ephScalar)
        val ephKey = MeshCrypto.encodePublicKey(eph.public)
        val shared = MeshCrypto.ecdh(eph.private, MeshCrypto.decodePublicKey(bob.publicKey)!!)
        val directKey = MeshCrypto.hkdf(shared, ephKey + bob.publicKey, "chatfort-mesh-direct-v2".toByteArray(), 32)
        print("direct.ephemeralPublicKey", ephKey.toHex())
        print("direct.ecdhX", shared.toHex())
        print("direct.key", directKey.toHex())
        // Bob derives the same key from his side.
        val bobShared = MeshCrypto.ecdh(bob.privateKey, MeshCrypto.decodePublicKey(ephKey)!!)
        assertArrayEquals(shared, bobShared)

        // A complete sealed private message Bob can open (signatures are random; verify, don't compare).
        val messageId = ByteArray(16) { (0xA0 + it).toByte() }
        val ts = 1_790_000_000_000L
        val header = SealedBody.Header(PacketType.DIRECT, messageId, ts, MeshPacket.NO_TARGET)
        val inner = SealedBody.seal(alice, SealedBody.Kind.MESSAGE, MessageBody.encode("alice", "north exit"), header, bob.publicKey)
        val outer = MeshIdentity.generate()
        val packet = MeshPacket.create(outer, PacketType.DIRECT, 7, timestamp = ts, messageId = messageId) { aad ->
            ephKey + MeshCrypto.sealWithNonce(directKey, inner, aad, ByteArray(12) { 9 })
        }
        assertTrue(packet.verify())
        val plain = MeshCrypto.open(directKey, packet.payload.copyOfRange(65, packet.payload.size), packet.aad())!!
        val opened = SealedBody.open(plain, header, bob.publicKey)!!
        assertArrayEquals(alice.publicKey, opened.senderKey)
        print("direct.packet", packet.encode().toHex())
    }

    private val outerScalar = BigInteger("4444444444444444444444444444444444444444444444444444444444444444", 16)
    private val carolScalar = BigInteger("5555555555555555555555555555555555555555555555555555555555555555", 16)

    /** A full CHANNEL packet: sealed MESSAGE (recipientLen 0), hourly tag as target, real AAD. */
    @Test
    fun fullChannelPacket() {
        val alice = MeshIdentity.of(MeshCrypto.keyPairFromScalar(aliceScalar))
        val outer = MeshIdentity.of(MeshCrypto.keyPairFromScalar(outerScalar))
        val key32 = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        val day = 20_717L
        val ts = day * TeamChannel.DAY_MS + 3_600_000L * 9 + 42_000
        val team = TeamChannel.fromCode("medics", key32, day).advancedTo(ts)
        val target = team.tag(ts)!!
        val messageId = ByteArray(16) { (0xC0 + it).toByte() }
        val header = SealedBody.Header(PacketType.CHANNEL, messageId, ts, target)
        val inner = SealedBody.seal(alice, SealedBody.Kind.MESSAGE, MessageBody.encode("alice", "stretcher needed"), header, null)
        val packet = MeshPacket.create(outer, PacketType.CHANNEL, 7, target = target, timestamp = ts, messageId = messageId) { aad ->
            print("channelPacket.aad", aad.toHex())
            MeshCrypto.sealWithNonce(team.messageKey(ts)!!, inner, aad, ByteArray(12) { 5 })
        }
        assertTrue(packet.verify())
        val plain = MeshCrypto.open(team.messageKey(ts)!!, packet.payload, packet.aad())!!
        val opened = SealedBody.open(plain, header, null)!!
        assertArrayEquals(alice.publicKey, opened.senderKey)
        print("channelPacket.outerPublicKey (scalar 0x44..44)", outer.publicKey.toHex())
        print("channelPacket.target", target.toHex())
        print("channelPacket.innerPlaintext", plain.toHex())
        print("channelPacket.packet (nonce=05*12)", packet.encode().toHex())
    }

    /** Sealed ACK (kind 2) and REKEY (kind 3) DIRECTs from alice to bob. */
    @Test
    fun sealedAckAndRekey() {
        val alice = MeshIdentity.of(MeshCrypto.keyPairFromScalar(aliceScalar))
        val bob = MeshIdentity.of(MeshCrypto.keyPairFromScalar(bobScalar))
        val aliceNext = MeshIdentity.of(MeshCrypto.keyPairFromScalar(carolScalar))
        val ackedId = ByteArray(16) { (0xA0 + it).toByte() }
        for ((name, kind, content) in listOf(
            Triple("ack", SealedBody.Kind.ACK, ackedId),
            Triple("rekey", SealedBody.Kind.REKEY, aliceNext.publicKey)
        )) {
            val (packet, plain) = sealedDirect(alice, bob, kind, content, ByteArray(16) { (0xD0 + kind.code).toByte() }, 1_790_000_100_000L)
            val header = SealedBody.Header(PacketType.DIRECT, packet.messageId, packet.timestamp, MeshPacket.NO_TARGET)
            val opened = SealedBody.open(plain, header, bob.publicKey)!!
            assertEquals(kind, opened.kind)
            assertArrayEquals(alice.publicKey, opened.senderKey)
            assertArrayEquals(content, opened.content)
            print("$name.innerPlaintext", plain.toHex())
            print("$name.packet (eph scalar 0x33..33, nonce=09*12)", packet.encode().toHex())
        }
        print("rekey.newPublicKey (scalar 0x55..55)", aliceNext.publicKey.toHex())
    }

    @Test
    fun teamCodeAndMultiDayRatchet() {
        val key32 = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        val day = 20_717L
        val b64 = java.util.Base64.getUrlEncoder().withoutPadding()
        val code = "CFTEAM2.${b64.encodeToString(key32)}.$day.${b64.encodeToString("medics".toByteArray())}"
        print("teamCode", code)
        var k = key32
        for (d in 1..3) {
            k = TeamChannel.ratchet(k)
            print("ratchet.day+$d", k.toHex())
        }
        // A joiner holding the day-d code, two days later, gets day d+2's key.
        val joined = TeamChannel.fromCode("medics", key32, day).advancedTo((day + 2) * TeamChannel.DAY_MS + 13 * TeamChannel.HOUR_MS)
        assertEquals(day + 2, joined.day)
        assertArrayEquals(TeamChannel.ratchet(TeamChannel.ratchet(key32)), joined.key)
        print("joiner.day+2.key", joined.key.toHex())
    }

    @Test
    fun opaqueDedupIdAndControlFrames() {
        val future = byteArrayOf(0x43, 3, 9, 5, 5) + ByteArray(32) { it.toByte() }
        val opaque = chat.simplex.mesh.protocol.OpaquePacket.decode(future)!!
        print("opaque.packet", future.toHex())
        print("opaque.dedupId", "%016x".format(opaque.shortId))
        val ids = listOf(1L, 0x0102030405060708L)
        print("inventory", chat.simplex.mesh.protocol.ControlFrame.Inventory(ids).encode().toHex())
        print("request", chat.simplex.mesh.protocol.ControlFrame.Request(ids).encode().toHex())
        assertEquals("4302810002", chat.simplex.mesh.protocol.ControlFrame.Inventory(ids).encode().toHex().take(10))
    }

    /** A sealed DIRECT with fixed ephemeral key (0x33..33) and nonce (09×12); outer key 0x44..44. */
    private fun sealedDirect(
        from: MeshIdentity, to: MeshIdentity, kind: SealedBody.Kind, content: ByteArray, messageId: ByteArray, ts: Long
    ): Pair<MeshPacket, ByteArray> {
        val eph = MeshCrypto.keyPairFromScalar(ephScalar)
        val ephKey = MeshCrypto.encodePublicKey(eph.public)
        val key = MeshCrypto.hkdf(MeshCrypto.ecdh(eph.private, MeshCrypto.decodePublicKey(to.publicKey)!!), ephKey + to.publicKey, "chatfort-mesh-direct-v2".toByteArray(), 32)
        val header = SealedBody.Header(PacketType.DIRECT, messageId, ts, MeshPacket.NO_TARGET)
        val inner = SealedBody.seal(from, kind, content, header, to.publicKey)
        val packet = MeshPacket.create(MeshIdentity.of(MeshCrypto.keyPairFromScalar(outerScalar)), PacketType.DIRECT, 7, timestamp = ts, messageId = messageId) { aad ->
            ephKey + MeshCrypto.sealWithNonce(key, inner, aad, ByteArray(12) { 9 })
        }
        assertTrue(packet.verify())
        return packet to inner
    }

    /** Re-encodes a DER ECDSA signature with s or n - s, whichever is high (or low). */
    private fun withS(der: ByteArray, high: Boolean): ByteArray {
        var i = 2
        require(der[0].toInt() == 0x30)
        require(der[i].toInt() == 0x02)
        val rLen = der[i + 1].toInt()
        val r = der.copyOfRange(i + 2, i + 2 + rLen)
        i += 2 + rLen
        require(der[i].toInt() == 0x02)
        val sLen = der[i + 1].toInt()
        val s = BigInteger(1, der.copyOfRange(i + 2, i + 2 + sLen))
        val n = MeshCrypto.curveOrder
        val isHigh = s > n.shiftRight(1)
        val sPrime = if (isHigh == high) s else n.subtract(s)
        fun intDer(v: ByteArray): ByteArray = byteArrayOf(0x02, v.size.toByte()) + v
        val sBytes = sPrime.toByteArray() // minimal two's complement, positive
        val body = intDer(r) + intDer(sBytes)
        return byteArrayOf(0x30, body.size.toByte()) + body
    }
}
