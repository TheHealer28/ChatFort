package chat.simplex.mesh

import chat.simplex.mesh.core.ContactChannel
import chat.simplex.mesh.core.ContactLinks
import chat.simplex.mesh.core.TeamChannel
import chat.simplex.mesh.protocol.ContactBody
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
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.math.BigInteger

/**
 * Wire-version-3 test vectors for iOS: the same inputs and names as mesh-v3-vectors-ios.txt, so the two
 * files can be compared line by line. Written to build/mesh-v3-vectors.txt. ECDSA signatures are random,
 * so packets are "verify and open this" vectors.
 */
class VectorsV3Test {
    private val out = ArrayList<String>()
    private fun print(name: String, value: String) = out.add("VECTOR $name = $value").also { println(out.last()) }

    private val seedA = ByteArray(32) { it.toByte() }            // 00..1f
    private val seedB = ByteArray(32) { (0x80 + it).toByte() }   // 80..9f
    private val dayA = 20734L
    private val dayB = 20735L
    /** d0 = dayB, 13:05 UTC. */
    private val ts = dayB * TeamChannel.DAY_MS + 13 * TeamChannel.HOUR_MS + 5 * 60_000L
    private val uid = ByteArray(16) { 0xaa.toByte() }
    private val data = ByteArray(3000) { (it % 251).toByte() }
    private val mediaKey = ByteArray(32) { 0x44 }
    private val mediaId = ByteArray(8) { 0x55 }

    private fun identity(byte: String) = MeshIdentity.of(MeshCrypto.keyPairFromScalar(BigInteger(byte.repeat(32), 16)))

    @Test
    fun vectors() {
        out += "# ChatFort Crowd mesh wire v3 — vectors from the Android implementation (VectorsV3Test.kt)"
        out += "# Same inputs and names as mesh-v3-vectors-ios.txt. Hex unless noted. ECDSA signatures are random: verify them, don't compare."
        out += "# Seeds: A = 00..1f, B = 80..9f. dayA = 20734, dayB = 20735, d0 = dayB. ts = d0 + 13 h 5 min."
        out += "# Outer key of the contact packet: P-256 scalar 0x44..44. Media chunk packets: scalar 0x55..55."
        out += "# Chunk AAD = mediaId(8) | index(1) (android-alignment-9 §2.6), so a chunk encrypts to the same bytes every round."
        contact()
        media()
        link()
        print("limits.photoMaxBytes", MediaType.PHOTO.maxBytes.toString())
        print("limits.voiceMaxBytes", MediaType.VOICE.maxBytes.toString())
        File("build").mkdirs()
        File("build/mesh-v3-vectors.txt").writeText(out.joinToString("\n", postfix = "\n"))
    }

    private fun contact() {
        val a = ContactChannel.fromSeeds("a", seedA, dayA, seedB, dayB, ts)!!
        val b = ContactChannel.fromSeeds("b", seedB, dayB, seedA, dayA, ts)!!
        print("contact.seedA", seedA.toHex())
        print("contact.seedB", seedB.toHex())
        print("contact.roleA", a.role.toString())
        assertEquals(0, a.role)
        assertEquals(1, b.role)
        assertEquals(dayB, a.startDay)
        val root = MeshCrypto.hkdf(seedA + seedB, null, "chatfort-mesh-contact-root-v3".toByteArray(), 32)
        assertArrayEquals(root, a.keyFor(dayB))
        print("contact.key(d0)", root.toHex())
        print("contact.key(d0+1)", ContactChannel.ratchet(root).toHex())
        print("contact.key(d0+2)", ContactChannel.ratchet(ContactChannel.ratchet(root)).toHex())
        assertArrayEquals(a.messageKey(ts), b.messageKey(ts))
        print("contact.messageKey(d0)", a.messageKey(ts)!!.toHex())
        print("contact.ts", ts.toString())
        assertArrayEquals(a.tag(ts), b.tag(ts))
        print("contact.tag(ts)", a.tag(ts)!!.toHex())

        val plain = ContactBody.encode(ContactBody.Kind.MESSAGE, a.role, uid, "meet at the north gate".toByteArray())
        print("contact.message.plaintext", plain.toHex())
        val outer = identity("44")
        print("contact.message.outerKey", outer.publicKey.toHex())
        val packet = MeshPacket.create(outer, PacketType.CONTACT, 7, target = a.tag(ts)!!, timestamp = ts, messageId = ByteArray(16) { it.toByte() }) { aad ->
            print("contact.message.aad", aad.toHex())
            MeshCrypto.sealWithNonce(a.messageKey(ts)!!, plain, aad, ByteArray(12) { (0xa0 + it).toByte() }).also {
                print("contact.message.payload (nonce a0..ab)", it.toHex())
            }
        }
        val bytes = packet.encode()
        assertEquals(3, bytes[1].toInt())
        assertTrue(packet.verify())
        print("contact.message.packet", bytes.toHex())
        assertEquals(OpaquePacket.idOf(bytes), packet.shortId)
        print("contact.message.dedupId", "%016x".format(packet.shortId))
        // b opens it and sees a's role.
        val opened = ContactBody.decode(MeshCrypto.open(b.messageKey(ts)!!, MeshPacket.decode(bytes)!!.payload, packet.aad())!!)!!
        assertEquals(ContactBody.Kind.MESSAGE, opened.kind)
        assertEquals(0, opened.role)
        assertEquals("meet at the north gate", String(opened.content))
        print("contact.ack.plaintext", ContactBody.encode(ContactBody.Kind.ACK, 1, uid).toHex())
    }

    private fun media() {
        val header = MediaHeader(MediaType.PHOTO, data.size, MediaHeader.chunksFor(data.size), MeshCrypto.sha256(data), mediaKey, mediaId, 0, 640, 480, "", "gate")
        print("media.data", "3000 bytes, byte i = i mod 251")
        print("media.header (photo, contact)", header.encode().toHex())
        val team = MediaHeader(header.type, header.totalSize, header.chunkCount, header.sha256, mediaKey, mediaId, 0, 640, 480, "medic7", "gate")
        print("media.teamContent (uid aa.. | header, nick medic7)", (uid + team.encode()).toHex())
        assertEquals(2, header.chunkCount)
        val chunkKey = MediaChunk.chunkKey(mediaKey)
        print("media.chunkKey", chunkKey.toHex())
        val chunks = MediaChunk.split(data)
        val mediaIdentity = identity("55")
        for (i in 0..1) {
            print("media.chunk$i.aad", MediaChunk.aad(mediaId, i).toHex())
            val payload = MediaChunk.seal(chunkKey, i, chunks[i], mediaId)
            print("media.chunk$i.payload", payload.toHex())
            val packet = MeshPacket.create(mediaIdentity, PacketType.MEDIA_CHUNK, 5, target = mediaId, timestamp = ts, messageId = ByteArray(16) { (0x10 + i).toByte() }) { payload }
            assertTrue(packet.verify())
            print("media.chunk$i.packet", packet.encode().toHex())
            assertArrayEquals(chunks[i], MediaChunk.open(chunkKey, MeshPacket.decode(packet.encode())!!.payload, mediaId))
        }
    }

    private fun link() {
        // Built as the app does (ChatfortMeshLink.content, kotlinx JSON in this key order).
        val json = "{\"type\":\"chatfortMeshLink\",\"text\":\"This message needs a newer app version.\",\"v\":3," +
            "\"seed\":\"${ContactLinks.encodeSeed(seedA)}\",\"day\":$dayA,\"ack\":false}"
        print("link.json", json)
    }
}
