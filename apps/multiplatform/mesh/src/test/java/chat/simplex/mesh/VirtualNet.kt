package chat.simplex.mesh

import chat.simplex.mesh.core.LinkSender
import chat.simplex.mesh.core.MeshEvent
import chat.simplex.mesh.core.MeshRouter
import chat.simplex.mesh.core.MeshScheduler
import chat.simplex.mesh.protocol.MeshIdentity
import java.util.PriorityQueue
import java.util.Random

/**
 * An in-memory crowd of phones on a virtual clock. Each named node runs a real [MeshRouter];
 * links deliver frames in order after [latencyMs], like a BLE connection.
 */
class VirtualNet(seed: Long = 1, private val latencyMs: Long = 5) {
    var now = 1_790_000_000_000L
        private set
    private var seq = 0L
    private class Task(val at: Long, val seq: Long, val run: () -> Unit)
    private val queue = PriorityQueue(compareBy<Task>({ it.at }, { it.seq }))
    private val rnd = Random(seed)
    private val up = HashSet<Pair<String, String>>()
    val nodes = LinkedHashMap<String, Node>()

    /** Packet and control frames put on the air since the last [resetCounters]. */
    var framesSent = 0
        private set

    val scheduler = MeshScheduler { delayMs, task -> queue.add(Task(now + delayMs, seq++, task)) }

    inner class Node(val name: String) {
        val events = mutableListOf<MeshEvent>()
        /** Every frame this node received over a link. */
        val rawIn = mutableListOf<ByteArray>()
        val router = MeshRouter(
            identity = MeshIdentity.generate(),
            sender = LinkSender { to, data, _ -> transmit(name, to, data) },
            scheduler = scheduler,
            clock = { now },
            onEvent = { events += it },
            random = Random(rnd.nextLong())
        )
        val messages: List<MeshEvent.Message> get() = events.filterIsInstance<MeshEvent.Message>()
        val announces: List<MeshEvent.Announce> get() = events.filterIsInstance<MeshEvent.Announce>()
        val acks: List<MeshEvent.DirectAck> get() = events.filterIsInstance<MeshEvent.DirectAck>()
        val identity: MeshIdentity get() = router.identity
        fun received(text: String) = messages.filter { it.text == text }
    }

    fun node(name: String): Node = nodes.getOrPut(name) { Node(name) }

    fun link(a: String, b: String) {
        node(a); node(b)
        up += a to b
        up += b to a
        nodes.getValue(a).router.onLinkUp(b)
        nodes.getValue(b).router.onLinkUp(a)
    }

    fun unlink(a: String, b: String) {
        if (!up.remove(a to b)) return
        up.remove(b to a)
        nodes.getValue(a).router.onLinkDown(b)
        nodes.getValue(b).router.onLinkDown(a)
    }

    fun isLinked(a: String, b: String) = (a to b) in up

    /** Frames straight into [to] as if they came over its link from [from]. */
    fun inject(from: String, to: String, data: ByteArray) {
        scheduler.schedule(latencyMs) { nodes.getValue(to).router.onData(from, data) }
    }

    private fun transmit(from: String, to: String, data: ByteArray) {
        if ((from to to) !in up) return
        framesSent++
        val copy = data.copyOf()
        scheduler.schedule(latencyMs) {
            if ((from to to) in up) nodes.getValue(to).let { it.rawIn += copy; it.router.onData(from, copy) }
        }
    }

    /** Calls [MeshRouter.tick] on every node every [everyMs], as the app does. */
    fun startTicks(everyMs: Long = 5_000) {
        fun loop() {
            nodes.values.forEach { it.router.tick() }
            scheduler.schedule(everyMs) { loop() }
        }
        scheduler.schedule(everyMs) { loop() }
    }

    fun resetCounters() {
        framesSent = 0
    }

    /** Runs everything due in the next [ms] of virtual time. */
    fun run(ms: Long) {
        val end = now + ms
        while (true) {
            val task = queue.peek() ?: break
            if (task.at > end) break
            queue.poll()
            now = maxOf(now, task.at)
            task.run()
        }
        now = end
    }

    /** Hop distances from [start] over the current links. */
    fun distances(start: String): Map<String, Int> {
        val dist = HashMap<String, Int>()
        val todo = ArrayDeque<String>()
        dist[start] = 0
        todo.addLast(start)
        while (todo.isNotEmpty()) {
            val n = todo.removeFirst()
            for ((a, b) in up) if (a == n && b !in dist) {
                dist[b] = dist.getValue(n) + 1
                todo.addLast(b)
            }
        }
        return dist
    }
}
