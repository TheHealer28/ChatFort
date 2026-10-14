package chat.simplex.mesh.protocol

/**
 * Splits packets into BLE-sized fragments and reassembles them, per link.
 * Fragment: [sequence][index][count][data]. Up to 255 fragments per packet.
 */
class Fragmenter {
    private var sequence = 0

    /** [maxFragment] is the largest single BLE write (ATT MTU - 3). Returns empty if the packet is too big. */
    fun split(packet: ByteArray, maxFragment: Int): List<ByteArray> {
        val chunk = maxFragment - HEADER
        require(chunk >= 1) { "fragment size too small" }
        val count = (packet.size + chunk - 1) / chunk
        if (count == 0 || count > MAX_FRAGMENTS) return emptyList()
        val seq = sequence
        sequence = (sequence + 1) and 0xff
        return List(count) { i ->
            val start = i * chunk
            val end = minOf(packet.size, start + chunk)
            byteArrayOf(seq.toByte(), i.toByte(), count.toByte()) + packet.copyOfRange(start, end)
        }
    }

    companion object {
        const val HEADER = 3
        const val MAX_FRAGMENTS = 255
    }
}

class Reassembler(private val timeoutMs: Long = 15_000, private val maxPending: Int = 16) {
    private class Pending(val count: Int, val startedAt: Long) {
        val parts = arrayOfNulls<ByteArray>(count)
        var received = 0
    }

    private val pending = LinkedHashMap<Int, Pending>()

    /** Returns the whole packet when its last fragment arrives, otherwise null. */
    fun accept(fragment: ByteArray, now: Long): ByteArray? {
        if (fragment.size <= Fragmenter.HEADER) return null
        val seq = fragment[0].toInt() and 0xff
        val index = fragment[1].toInt() and 0xff
        val count = fragment[2].toInt() and 0xff
        if (count == 0 || index >= count) return null
        if (count == 1) return fragment.copyOfRange(Fragmenter.HEADER, fragment.size)
        expire(now)
        var p = pending[seq]
        // A link delivers in order, so a fragment index we already hold means the sequence number has
        // wrapped round onto an old packet that never completed: start over rather than mix the two.
        if (p == null || p.count != count || p.parts[index] != null) {
            if (p != null) pending.remove(seq)
            if (pending.size >= maxPending) pending.remove(pending.keys.first())
            p = Pending(count, now)
            pending[seq] = p
        }
        if (p.parts[index] == null) {
            p.parts[index] = fragment.copyOfRange(Fragmenter.HEADER, fragment.size)
            p.received++
        }
        if (p.received < count) return null
        pending.remove(seq)
        val total = p.parts.sumOf { it!!.size }
        val out = ByteArray(total)
        var pos = 0
        for (part in p.parts) {
            System.arraycopy(part!!, 0, out, pos, part.size)
            pos += part.size
        }
        return out
    }

    fun expire(now: Long) {
        val it = pending.entries.iterator()
        while (it.hasNext()) if (now - it.next().value.startedAt > timeoutMs) it.remove()
    }
}
