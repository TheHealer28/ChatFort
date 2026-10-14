package chat.simplex.mesh

import chat.simplex.mesh.protocol.ControlFrame
import chat.simplex.mesh.protocol.Fragmenter
import chat.simplex.mesh.protocol.MeshCrypto
import chat.simplex.mesh.protocol.MeshIdentity
import chat.simplex.mesh.protocol.MeshPacket
import chat.simplex.mesh.protocol.MessageBody
import chat.simplex.mesh.protocol.PacketType
import chat.simplex.mesh.protocol.Reassembler
import chat.simplex.mesh.protocol.toHex
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class ProtocolTest {

    @Test
    fun hkdfMatchesRfc5869TestCase1() {
        val ikm = ByteArray(22) { 0x0b }
        val salt = ByteArray(13) { it.toByte() }
        val info = ByteArray(10) { (0xf0 + it).toByte() }
        val okm = MeshCrypto.hkdf(ikm, salt, info, 42)
        assertEquals(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            okm.toHex()
        )
    }

    @Test
    fun publicKeyRoundTripAndInvalidPointRejected() {
        val id = MeshIdentity.generate()
        assertEquals(65, id.publicKey.size)
        assertNotNull(MeshCrypto.decodePublicKey(id.publicKey))
        val bad = id.publicKey.copyOf().also { it[64] = (it[64].toInt() xor 1).toByte() }
        assertNull("a point off the curve must be rejected", MeshCrypto.decodePublicKey(bad))
        assertNull(MeshCrypto.decodePublicKey(ByteArray(65)))
    }

    @Test
    fun sealOpenAndTamperDetection() {
        val key = MeshCrypto.randomBytes(32)
        val aad = "header".toByteArray()
        val sealed = MeshCrypto.seal(key, "hello".toByteArray(), aad)
        assertEquals("hello", String(MeshCrypto.open(key, sealed, aad)!!))
        assertNull(MeshCrypto.open(MeshCrypto.randomBytes(32), sealed, aad))
        assertNull(MeshCrypto.open(key, sealed, "other".toByteArray()))
        val flipped = sealed.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
        assertNull(MeshCrypto.open(key, flipped, aad))
    }

    @Test
    fun packetRoundTripSignatureAndRelayFields() {
        val id = MeshIdentity.generate()
        val packet = MeshPacket.create(id, PacketType.PUBLIC, 7) { MessageBody.encode("anon1234", "hello crowd") }
        val decoded = MeshPacket.decode(packet.encode())!!
        assertTrue(decoded.verify())
        assertEquals(PacketType.PUBLIC, decoded.type)
        assertArrayEquals(packet.messageId, decoded.messageId)
        assertEquals("anon1234" to "hello crowd", MessageBody.decode(decoded.payload))

        // Relays change ttl/hops only; the signature must still hold.
        val relayed = MeshPacket.decode(decoded.relayed().encode())!!
        assertEquals(6, relayed.ttl)
        assertEquals(1, relayed.hops)
        assertTrue(relayed.verify())
    }

    @Test
    fun tamperedOrForgedPacketsFailVerification() {
        val alice = MeshIdentity.generate()
        val mallory = MeshIdentity.generate()
        val packet = MeshPacket.create(alice, PacketType.PUBLIC, 7) { MessageBody.encode("alice", "meet at gate 3") }
        val bytes = packet.encode()

        // Change one byte of the text.
        val tampered = bytes.copyOf()
        tampered[MeshPacket.HEADER_SIZE + 8] = (tampered[MeshPacket.HEADER_SIZE + 8].toInt() xor 1).toByte()
        assertFalse(MeshPacket.decode(tampered)!!.verify())

        // Claiming Alice as origin while carrying another key fails the origin check...
        val wrongKey = MeshPacket(packet.type, packet.ttl, packet.maxTtl, 0, packet.messageId, alice.peerId, packet.timestamp, packet.target, mallory.publicKey, packet.payload, packet.signature)
        assertFalse(wrongKey.verify())
        // ...and Alice's header and key with someone else's signature fails the signature check.
        val malloryCopy = MeshPacket.create(mallory, PacketType.PUBLIC, 7, timestamp = packet.timestamp, messageId = packet.messageId) { packet.payload }
        val forged = MeshPacket(packet.type, packet.ttl, packet.maxTtl, 0, packet.messageId, alice.peerId, packet.timestamp, packet.target, alice.publicKey, packet.payload, malloryCopy.signature)
        assertFalse(forged.verify())
    }

    @Test
    fun decodeNeverThrowsOnGarbage() {
        val rnd = Random(42)
        repeat(2_000) {
            val bytes = ByteArray(rnd.nextInt(0, 400)).also { rnd.nextBytes(it) }
            if (bytes.isNotEmpty()) bytes[0] = MeshPacket.MAGIC.toByte()
            if (bytes.size > 1) bytes[1] = MeshPacket.VERSION.toByte()
            if (bytes.size > 2 && rnd.nextBoolean()) bytes[2] = rnd.nextInt(1, 6).toByte()
            MeshPacket.decode(bytes)
            ControlFrame.decode(bytes)
            MessageBody.decode(bytes)
        }
    }

    @Test
    fun corruptedPacketsNeverVerify() {
        val rnd = Random(7)
        val id = MeshIdentity.generate()
        val valid = MeshPacket.create(id, PacketType.PUBLIC, 7) { MessageBody.encode("anon", "stay together") }.encode()
        // ttl is the only byte relays may change (maxTtl and flags are signed).
        val unsigned = setOf(3)
        repeat(3_000) {
            val bytes = valid.copyOf(if (rnd.nextInt(10) == 0) rnd.nextInt(valid.size) else valid.size)
            repeat(rnd.nextInt(1, 4)) {
                if (bytes.isNotEmpty()) {
                    val i = rnd.nextInt(bytes.size)
                    bytes[i] = (bytes[i].toInt() xor (1 shl rnd.nextInt(8))).toByte()
                }
            }
            val packet = MeshPacket.decode(bytes) ?: return@repeat
            if (packet.verify()) {
                assertEquals(valid.size, bytes.size)
                for (i in bytes.indices) if (i !in unsigned) assertEquals("byte $i", valid[i], bytes[i])
            }
        }
    }

    @Test
    fun controlFramesRoundTrip() {
        val ids = List(300) { Random(it).nextLong() }
        val inventory = ControlFrame.decode(ControlFrame.Inventory(ids).encode()) as ControlFrame.Inventory
        assertEquals(ids, inventory.ids)
        val request = ControlFrame.decode(ControlFrame.Request(ids.take(3)).encode()) as ControlFrame.Request
        assertEquals(ids.take(3), request.ids)
        assertTrue(ControlFrame.isControl(ControlFrame.Request(ids).encode()))
        val packet = MeshPacket.create(MeshIdentity.generate(), PacketType.ANNOUNCE, 3) { MessageBody.encode("x") }.encode()
        assertFalse(ControlFrame.isControl(packet))
    }

    @Test
    fun fragmentationRoundTripAtSmallAndLargeMtu() {
        val packet = MeshCrypto.randomBytes(1_234)
        for (maxFragment in listOf(20, 185, 514)) {
            val fragments = Fragmenter().split(packet, maxFragment)
            assertTrue(fragments.all { it.size <= maxFragment })
            val r = Reassembler()
            var out: ByteArray? = null
            fragments.shuffled(Random(maxFragment)).forEach { f -> r.accept(f, 0)?.let { out = it } }
            assertArrayEquals(packet, out)
        }
        assertTrue("too large for 255 fragments", Fragmenter().split(ByteArray(10_000), 20).isEmpty())
    }

    @Test
    fun messageBodyTruncatesAtCharacterBoundaries() {
        val urdu = "سلام".repeat(400)
        val body = MessageBody.encode("نام".repeat(20), urdu)
        val (nick, text) = MessageBody.decode(body)!!
        assertTrue(nick.toByteArray().size <= MessageBody.MAX_NICKNAME_BYTES)
        assertTrue(text.toByteArray().size <= MessageBody.MAX_TEXT_BYTES)
        assertFalse("no broken characters", text.contains(Char(0xFFFD)))
    }
}
