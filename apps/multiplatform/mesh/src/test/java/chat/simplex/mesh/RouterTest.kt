package chat.simplex.mesh

import chat.simplex.mesh.core.MeshEvent
import chat.simplex.mesh.core.MeshRouter
import chat.simplex.mesh.core.TeamChannel
import chat.simplex.mesh.protocol.MeshCrypto
import chat.simplex.mesh.protocol.MeshPacket
import chat.simplex.mesh.protocol.MessageBody
import chat.simplex.mesh.protocol.PacketType
import chat.simplex.mesh.protocol.toHex
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

class RouterTest {

    private fun chain(net: VirtualNet, names: List<String>) = names.zipWithNext().forEach { (a, b) -> net.link(a, b) }

    private fun names(n: Int) = List(n) { "p$it" }

    @Test
    fun publicMessageTravelsSevenHopsAndNoFurther() {
        val net = VirtualNet()
        val p = names(10)
        chain(net, p)
        net.startTicks()
        net.run(1_000)
        net.node("p0").router.sendPublic("gate 3 is open")
        net.run(5 * 60_000)
        for ((i, name) in p.withIndex()) {
            val got = net.node(name).received("gate 3 is open")
            when (i) {
                0 -> assertTrue(got.isEmpty())
                in 1..7 -> {
                    assertEquals("$name should get it once", 1, got.size)
                    assertEquals(i, got.single().hops)
                }
                else -> assertTrue("$name is beyond 7 hops", got.isEmpty())
            }
        }
    }

    @Test
    fun meshWithLoopsDeliversExactlyOnceAndSendsEachLinkAtMostOncePerDirection() {
        val net = VirtualNet()
        val size = 7
        fun n(x: Int, y: Int) = "n${x}_$y"
        var edges = 0
        for (x in 0 until size) for (y in 0 until size) {
            if (x + 1 < size) { net.link(n(x, y), n(x + 1, y)); edges++ }
            if (y + 1 < size) { net.link(n(x, y), n(x, y + 1)); edges++ }
            if (x + 1 < size && y + 1 < size && (x + y) % 2 == 0) { net.link(n(x, y), n(x + 1, y + 1)); edges++ }
        }
        net.run(1_000)
        net.resetCounters()
        val source = n(0, 0)
        net.node(source).router.sendPublic("hello grid")
        net.run(10_000)
        val dist = net.distances(source)
        for ((name, node) in net.nodes) {
            val got = node.received("hello grid").size
            val d = dist.getValue(name)
            when {
                d == 0 -> assertEquals(0, got)
                d <= MeshRouter.MESSAGE_TTL -> assertEquals("$name at $d hops", 1, got)
                else -> assertEquals("$name at $d hops", 0, got)
            }
        }
        assertTrue("sent ${net.framesSent} frames over $edges links", net.framesSent <= 2 * edges)
    }

    @Test
    fun announceReachesThreeHops() {
        val net = VirtualNet()
        val p = names(6)
        chain(net, p)
        net.node("p0").router.nickname = "Ayesha"
        net.node("p0").router.announce()
        net.run(5_000)
        for (i in 1..5) {
            val got = net.node(p[i]).announces.filter { it.nickname == "Ayesha" }
            if (i <= MeshRouter.ANNOUNCE_TTL) assertEquals(i, got.single().hops) else assertTrue(got.isEmpty())
        }
    }

    @Test
    fun privateMessageIsReadOnlyByRecipientAndAcknowledged() {
        val net = VirtualNet()
        val p = names(6)
        chain(net, p)
        net.run(1_000)
        // p0 learns p5's key from a public message (p5 is beyond announce range).
        net.node("p5").router.sendPublic("I'm at the east gate")
        net.run(5_000)
        val key = net.node("p0").received("I'm at the east gate").single().publicKey
        val sent = net.node("p0").router.sendDirect(key, "bring water")!!
        net.run(10_000)

        val dm = net.node("p5").messages.single { it.kind == MeshEvent.Kind.DIRECT }
        assertEquals("bring water", dm.text)
        assertEquals(net.node("p0").identity.peerIdHex, dm.peerIdHex)
        for (i in 1..4) assertTrue(net.node(p[i]).messages.none { it.kind == MeshEvent.Kind.DIRECT })
        val ack = net.node("p0").acks.single()
        assertEquals(sent.messageId.toHex(), ack.ackedMessageIdHex)
        assertEquals(net.node("p5").identity.peerIdHex, ack.peerIdHex)
    }

    @Test
    fun teamMessagesAreReadOnlyByMembersButRelayedByEveryone() {
        val net = VirtualNet()
        val p = names(5)
        chain(net, p)
        val team = TeamChannel.create("medics", net.now)
        val teamOnP4 = TeamChannel.fromCode("medics", team.key, team.day)
        val otherTeam = TeamChannel.create("medics", net.now)
        net.node("p0").router.setChannels(listOf(team))
        net.node("p4").router.setChannels(listOf(teamOnP4))
        net.node("p2").router.setChannels(listOf(otherTeam))
        net.run(1_000)
        net.node("p0").router.sendChannel(team, "injured person near the stage")!!
        net.run(10_000)
        val got = net.node("p4").messages.single()
        assertEquals(MeshEvent.Kind.CHANNEL, got.kind)
        assertEquals("injured person near the stage", got.text)
        assertEquals(teamOnP4.localId, got.channelIdHex)
        // The real sender is only inside the encryption.
        assertEquals(net.node("p0").identity.peerIdHex, got.peerIdHex)
        for (i in 1..3) assertTrue("p$i is not in the team", net.node(p[i]).messages.isEmpty())
    }

    @Test
    fun messageSentAloneIsDeliveredWhenPeopleArriveButStillOnlySevenHops() {
        val net = VirtualNet()
        val p = names(10)
        net.node("p0").router.sendPublic("written with nobody around")
        net.run(60_000)
        // People arrive one after another, each only meeting the previous one.
        for (i in 1 until p.size) {
            net.link(p[i - 1], p[i])
            net.run(30_000)
            if (i >= 2) net.unlink(p[i - 2], p[i - 1])
        }
        net.run(60_000)
        for (i in 1 until p.size) {
            val got = net.node(p[i]).received("written with nobody around")
            if (i <= 7) assertEquals("p$i", i, got.single().hops) else assertTrue("p$i is beyond 7 hops", got.isEmpty())
        }
    }

    @Test
    fun separatedGroupsCatchUpWhenTheyMeet() {
        val net = VirtualNet()
        chain(net, listOf("a0", "a1", "a2"))
        chain(net, listOf("b0", "b1", "b2"))
        net.startTicks()
        net.run(1_000)
        net.node("a0").router.sendPublic("police moving to the north road")
        net.run(30_000)
        assertTrue(net.nodes.filterKeys { it.startsWith("b") }.values.all { it.messages.isEmpty() })
        net.link("a2", "b0")
        net.run(3 * 60_000)
        assertEquals(3, net.node("b0").received("police moving to the north road").single().hops)
        assertEquals(4, net.node("b1").received("police moving to the north road").single().hops)
        assertEquals(5, net.node("b2").received("police moving to the north road").single().hops)
    }

    @Test
    fun catchUpIsPulledNotReflooded() {
        val net = VirtualNet()
        // A well-connected group that already shares 50 messages.
        val group = names(6)
        for (i in group.indices) for (j in i + 1 until group.size) net.link(group[i], group[j])
        net.run(1_000)
        repeat(50) { net.node(group[it % group.size]).router.sendPublic("msg $it") }
        net.run(30 * 60_000)
        net.resetCounters()
        // A newcomer joins one member; everyone else already has everything.
        net.link("newcomer", group[0])
        net.run(30_000)
        assertEquals(50, net.node("newcomer").messages.size)
        // 50 packets to the newcomer plus a few control frames; no re-flood through the group.
        assertTrue("sent ${net.framesSent} frames", net.framesSent <= 60)
    }

    @Test
    fun forgedPacketsDoNotBlockGenuineOnes() {
        val net = VirtualNet()
        chain(net, listOf("alice", "bob", "carol"))
        net.link("mallory", "bob")
        net.run(1_000)
        val alice = net.node("alice").identity
        val mallory = net.node("mallory").identity
        val genuine = MeshPacket.create(alice, PacketType.PUBLIC, 7, timestamp = net.now) { MessageBody.encode("alice", "meet at 5") }

        // 1. Alice's packet with the text changed: rejected, and it must not block the real one.
        val tampered = genuine.encode().also { it[MeshPacket.HEADER_SIZE + 7] = 'X'.code.toByte() }
        net.inject("mallory", "bob", tampered)
        // 2. Mallory's own validly signed packet reusing Alice's message ID, sent first.
        val squatter = MeshPacket.create(mallory, PacketType.PUBLIC, 7, timestamp = net.now, messageId = genuine.messageId) {
            MessageBody.encode("alice", "meeting cancelled")
        }
        net.inject("mallory", "bob", squatter.encode())
        net.run(1_000)
        net.inject("alice", "bob", genuine.encode())
        net.run(5_000)

        for (name in listOf("bob", "carol")) {
            val texts = net.node(name).messages.map { it.peerIdHex to it.text }
            assertTrue("$name got Alice's real message", (alice.peerIdHex to "meet at 5") in texts)
            assertTrue("$name never saw the tampered text", texts.none { it.second.contains('X') })
            // Mallory's packet is delivered, but as Mallory: it can't claim to be Alice.
            assertTrue(texts.filter { it.second == "meeting cancelled" }.all { it.first == mallory.peerIdHex })
        }
    }

    @Test
    fun floodFromOneSenderIsRateLimited() {
        val net = VirtualNet()
        chain(net, listOf("spammer", "p1", "p2"))
        net.run(1_000)
        repeat(100) { net.node("spammer").router.sendPublic("spam $it") }
        net.run(10_000)
        val got = net.node("p1").messages.size
        assertTrue("delivered $got", got in 29..31)
        assertTrue(net.node("p2").messages.size <= got)
        // Normal pace is fine again a minute later.
        net.run(60_000)
        net.node("spammer").router.sendPublic("later")
        net.run(10_000)
        assertEquals(1, net.node("p2").received("later").size)
    }

    @Test
    fun wrongClocksWithinSixHoursAreAcceptedButOldReplaysAreNot() {
        val net = VirtualNet()
        chain(net, listOf("a", "b"))
        net.run(1_000)
        val a = net.node("a").identity
        fun packet(offset: Long, text: String) =
            MeshPacket.create(a, PacketType.PUBLIC, 7, timestamp = net.now + offset) { MessageBody.encode("a", text) }.encode()
        val hour = 60 * 60_000L
        net.inject("a", "b", packet(-5 * hour, "clock 5h slow"))
        net.inject("a", "b", packet(5 * hour, "time zone set wrong"))
        net.inject("a", "b", packet(-7 * hour, "replayed from this morning"))
        net.inject("a", "b", packet(7 * hour, "far future"))
        net.run(5_000)
        val texts = net.node("b").messages.map { it.text }.toSet()
        assertEquals(setOf("clock 5h slow", "time zone set wrong"), texts)
    }

    @Test
    fun clearStopsPendingRelays() {
        val net = VirtualNet()
        chain(net, listOf("a", "b", "c"))
        net.run(1_000)
        val packet = MeshPacket.create(net.node("a").identity, PacketType.PUBLIC, 7, timestamp = net.now) {
            MessageBody.encode("a", "hello")
        }
        net.inject("a", "b", packet.encode())
        net.run(6) // delivered to b, relay still waiting on its jitter
        assertEquals(1, net.node("b").messages.size)
        net.node("b").router.clear()
        net.run(5_000)
        assertTrue(net.node("c").messages.isEmpty())
    }

    @Test
    fun crowdOf200PhonesReachesEveryoneWithinSevenHops() {
        val rnd = Random(7)
        val net = VirtualNet(seed = 7)
        // 200 phones scattered over 250 m x 250 m; Bluetooth reaches ~30 m in a crowd;
        // each phone keeps at most 8 links.
        val count = 200
        val pos = List(count) { rnd.nextDouble() * 250 to rnd.nextDouble() * 250 }
        val degree = IntArray(count)
        val pairs = mutableListOf<Triple<Int, Int, Double>>()
        for (i in 0 until count) for (j in i + 1 until count) {
            val dx = pos[i].first - pos[j].first
            val dy = pos[i].second - pos[j].second
            val d = Math.sqrt(dx * dx + dy * dy)
            if (d <= 30) pairs += Triple(i, j, d)
        }
        for ((i, j, _) in pairs.sortedBy { it.third }) {
            if (degree[i] < 8 && degree[j] < 8) {
                net.link("c$i", "c$j")
                degree[i]++
                degree[j]++
            }
        }
        (0 until count).forEach { net.node("c$it") }
        net.run(1_000)
        net.resetCounters()

        val senders = listOf(0, 50, 100, 150, 199)
        senders.forEach { net.node("c$it").router.sendPublic("alert from c$it") }
        net.run(30_000)

        var reachedTotal = 0
        for (s in senders) {
            val dist = net.distances("c$s")
            for ((name, node) in net.nodes) {
                val d = dist[name] ?: Int.MAX_VALUE
                val got = node.received("alert from c$s").size
                if (d in 1..MeshRouter.MESSAGE_TTL) {
                    assertEquals("$name at $d hops from c$s", 1, got)
                    reachedTotal++
                } else {
                    assertEquals("$name at $d hops from c$s", 0, got)
                }
            }
        }
        val links = degree.sum() / 2
        println("crowd: $count phones, $links links, ${reachedTotal / senders.size} reached per message on average, ${net.framesSent / senders.size} frames per message")
        assertTrue(net.framesSent <= senders.size * 2 * links)
    }
}
