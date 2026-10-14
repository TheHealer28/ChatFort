package chat.simplex.mesh

import chat.simplex.mesh.core.ContactChannel
import chat.simplex.mesh.core.ContactLinks
import chat.simplex.mesh.protocol.ContactBody
import chat.simplex.mesh.protocol.MediaChunk
import chat.simplex.mesh.protocol.MediaHeader
import chat.simplex.mesh.protocol.MediaType
import chat.simplex.mesh.protocol.MeshCrypto
import chat.simplex.mesh.protocol.MeshPacket
import chat.simplex.mesh.protocol.OpaquePacket
import chat.simplex.mesh.protocol.PacketType
import chat.simplex.mesh.protocol.toHex
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Checks the iOS implementation's v3 vectors (mesh-v3-vectors-ios.txt on the private alignment
 * branch) against this implementation. Skipped if the file isn't there; set MESH_IOS_VECTORS to its path.
 */
class IosVectorsCheckTest {
    private val file = File(System.getenv("MESH_IOS_VECTORS") ?: "../../../../chatfort-alignment/mesh-v3-vectors-ios.txt")

    private fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun load(): Map<String, String> = file.readLines()
        .filter { it.startsWith("VECTOR ") }
        .associate { line -> line.removePrefix("VECTOR ").substringBefore(" = ") to line.substringAfter(" = ") }

    @Test
    fun iosVectorsMatch() {
        assumeTrue("no iOS vectors at ${file.absolutePath}", file.exists())
        val v = load()
        fun h(name: String) = hex(v[name] ?: error("missing $name"))
        val report = ArrayList<String>()

        // Pair keys and tags.
        val seedA = h("contact.seedA")
        val seedB = h("contact.seedB")
        val ts = v.getValue("contact.ts").toLong()
        val a = ContactChannel.fromSeeds("a", seedA, 20734, seedB, 20735, ts)!!
        val b = ContactChannel.fromSeeds("b", seedB, 20735, seedA, 20734, ts)!!
        assertEquals(v.getValue("contact.roleA").toInt(), a.role)
        assertArrayEquals(h("contact.key(d0)"), a.keyFor(20735))
        assertArrayEquals(h("contact.key(d0+1)"), ContactChannel.ratchet(h("contact.key(d0)")))
        assertArrayEquals(h("contact.key(d0+2)"), ContactChannel.ratchet(h("contact.key(d0+1)")))
        assertArrayEquals(h("contact.messageKey(d0)"), a.messageKey(ts))
        assertArrayEquals(h("contact.tag(ts)"), a.tag(ts))
        report += "keys, message key, tag: match"

        // Contact message.
        val uid = ByteArray(16) { 0xaa.toByte() }
        assertArrayEquals(h("contact.message.plaintext"), ContactBody.encode(ContactBody.Kind.MESSAGE, 0, uid, "meet at the north gate".toByteArray()))
        assertArrayEquals(h("contact.ack.plaintext"), ContactBody.encode(ContactBody.Kind.ACK, 1, uid))
        val bytes = h("contact.message.packet")
        val packet = MeshPacket.decode(bytes)
        assertNotNull("iOS contact packet parses", packet)
        packet!!
        assertEquals(PacketType.CONTACT, packet.type)
        assertTrue("iOS signature verifies", packet.verify())
        assertArrayEquals(h("contact.message.outerKey"), packet.originKey)
        assertArrayEquals(h("contact.message.aad"), packet.aad())
        assertArrayEquals(h("contact.message.payload (nonce a0..ab)"), packet.payload)
        // Same key, nonce, AAD and plaintext give the same bytes here.
        assertArrayEquals(packet.payload, MeshCrypto.sealWithNonce(a.messageKey(ts)!!, h("contact.message.plaintext"), packet.aad(), ByteArray(12) { (0xa0 + it).toByte() }))
        val body = ContactBody.decode(MeshCrypto.open(b.messageKey(ts)!!, packet.payload, packet.aad())!!)!!
        assertEquals("meet at the north gate", String(body.content))
        assertEquals("%016x".format(packet.shortId), v.getValue("contact.message.dedupId"))
        assertEquals(OpaquePacket.idOf(bytes), packet.shortId)
        report += "contact packet: parses, verifies, opens; AAD, payload and dedup ID match"

        // Media.
        val data = ByteArray(3000) { (it % 251).toByte() }
        val mediaKey = ByteArray(32) { 0x44 }
        val mediaId = ByteArray(8) { 0x55 }
        val header = MediaHeader(MediaType.PHOTO, 3000, 2, MeshCrypto.sha256(data), mediaKey, mediaId, 0, 640, 480, "", "gate")
        assertArrayEquals(h("media.header (photo, contact)"), header.encode())
        assertNotNull(MediaHeader.decode(h("media.header (photo, contact)")))
        val team = MediaHeader(MediaType.PHOTO, 3000, 2, MeshCrypto.sha256(data), mediaKey, mediaId, 0, 640, 480, "medic7", "gate")
        assertArrayEquals(h("media.teamContent (uid aa.. | header, nick medic7)"), uid + team.encode())
        val chunkKey = MediaChunk.chunkKey(mediaKey)
        assertArrayEquals(h("media.chunkKey"), chunkKey)
        report += "media header, team content, chunk key: match"

        val chunks = MediaChunk.split(data)
        for (i in 0..1) {
            val p = MeshPacket.decode(h("media.chunk$i.packet"))!!
            assertEquals(PacketType.MEDIA_CHUNK, p.type)
            assertTrue(p.verify())
            assertArrayEquals(mediaId, p.target)
            assertArrayEquals(h("media.chunk$i.payload"), p.payload)
            val aad = h("media.chunk$i.aad")
            val newAad = MediaChunk.aad(mediaId, i)
            if (aad.contentEquals(newAad)) {
                assertArrayEquals(chunks[i], MediaChunk.open(chunkKey, p.payload, mediaId))
                assertArrayEquals(p.payload, MediaChunk.seal(chunkKey, i, chunks[i], mediaId))
                report += "chunk $i: new AAD (mediaId | index); opens, and identical bytes here"
            } else {
                // Before the switch: AAD = packet AAD | index.
                assertArrayEquals(p.aad() + i.toByte(), aad)
                val nonce = ByteArray(12).also { it[11] = i.toByte() }
                assertArrayEquals(chunks[i], MeshCrypto.open(chunkKey, nonce + p.payload.copyOfRange(1, p.payload.size), aad))
                assertFalse(MediaChunk.open(chunkKey, p.payload, mediaId) != null)
                report += "chunk $i: OLD AAD (packet AAD | index); opens with it, not with the new one"
            }
        }

        // Link message.
        val link = JSONObject(v.getValue("link.json"))
        assertEquals("chatfortMeshLink", link.getString("type"))
        assertEquals("This message needs a newer app version.", link.getString("text"))
        assertEquals(3, link.getInt("v"))
        assertArrayEquals(seedA, ContactLinks.decodeSeed(link.getString("seed")))
        assertEquals(ContactLinks.encodeSeed(seedA), link.getString("seed"))
        assertEquals(20734L, link.getLong("day"))
        assertFalse(link.getBoolean("ack"))
        report += "link.json: matches"

        report.forEach { println("IOS-CHECK $it") }
        File("build").mkdirs()
        File("build/ios-vectors-check.txt").writeText(report.joinToString("\n", postfix = "\n"))
    }
}
