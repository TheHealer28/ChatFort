package chat.simplex.mesh.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import android.os.SystemClock
import chat.simplex.mesh.core.LinkListener
import chat.simplex.mesh.core.LinkSender
import chat.simplex.mesh.protocol.Fragmenter
import chat.simplex.mesh.protocol.MeshCrypto
import chat.simplex.mesh.protocol.Reassembler
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.UUID

/**
 * Bluetooth LE links for the crowd mesh. Every phone is both a GATT server (advertising the
 * ChatFort mesh service) and a GATT client (scanning and connecting to up to [MAX_CLIENT_LINKS]
 * neighbours). Frames are fragmented to the negotiated MTU and sent one write/notification at a time.
 *
 * The service has two characteristics: the phone that opened a link writes to RX, and the other
 * phone answers with notifications on TX. Keeping the directions apart matters on Android 12 and
 * older, where a characteristic's value is shared between outgoing writes and incoming notifications.
 *
 * All methods and callbacks run on [thread].
 */
@SuppressLint("MissingPermission")
class BleLinkLayer(
    private val context: Context,
    private val thread: MeshThread,
    private val listener: LinkListener,
    private val log: (String) -> Unit
) : LinkSender {

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("5d8a9e20-3b61-4c7a-9f0e-2a6b1c4d8e70")
        val RX_UUID: UUID = UUID.fromString("5d8a9e21-3b61-4c7a-9f0e-2a6b1c4d8e70")
        val TX_UUID: UUID = UUID.fromString("5d8a9e22-3b61-4c7a-9f0e-2a6b1c4d8e70")
        private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val MANUFACTURER_ID = 0xFFFF
        /** Links this phone opens itself. */
        const val MAX_CLIENT_LINKS = 4
        /** Links it accepts. Kept separate, so strangers connecting in can't take every slot. */
        const val MAX_SERVER_LINKS = 4
        private const val REQUESTED_MTU = 517
        /** Android rejects attribute values over 512 bytes, whatever the MTU. */
        private const val MAX_ATTRIBUTE_VALUE = 512
        private const val CONNECT_TIMEOUT_MS = 15_000L
        private const val WRITE_TIMEOUT_MS = 3_000L
        private const val MAX_QUEUED_FRAMES = 300
        private const val MAX_WRITE_RETRIES = 100
        private const val RETRY_DELAY_MS = 40L
        private const val HOUSEKEEPING_MS = 5_000L
        private const val SCAN_RESTART_MS = 5 * 60_000L
        private const val SCAN_MODE_SWITCH_MIN_MS = 60_000L
        private const val SCAN_RETRY_MS = 30_000L
        private const val ADVERTISE_RETRY_MS = 30_000L
        private const val SERVER_RETRY_MS = 30_000L
        private const val CANDIDATE_TTL_MS = 60_000L
        /** Only connect to phones heard recently: old addresses stop working when a phone re-advertises. */
        private const val CANDIDATE_FRESH_MS = 15_000L
        private const val SYMMETRY_OVERRIDE_MS = 20_000L
        private const val ROTATE_EVERY_MS = 120_000L
        private const val MIN_AGE_TO_ROTATE_MS = 180_000L
        private const val ROTATED_OUT_BACKOFF_MS = 60_000L
        /** A phone advertising without a token (an iPhone can't add one) that turned out to be a duplicate link. */
        private const val TOKENLESS_TWIN_BACKOFF_MS = 5 * 60_000L
        /** Largest long (prepared) write accepted from a neighbour. */
        private const val MAX_PREPARED_WRITE = 4096
        private const val TOKEN_ROTATE_MS = 15 * 60_000L
        /** A link that stays silent this long is dead (e.g. the other phone's app was killed). */
        private const val LINK_SILENT_MS = 90_000L
        /** Idle links send a hello this often, which keeps them provably alive. */
        private const val KEEPALIVE_MS = 30_000L
        /** A new link must identify itself this quickly. */
        private const val HELLO_DEADLINE_MS = 15_000L
        /** How long a closing incoming link stays around to deliver its bye. */
        private const val BYE_GRACE_MS = 2_000L
        private const val ATT_INSUFFICIENT_RESOURCES = 0x11

        // Link frames: 'L', version, type, token. A hello tells a neighbour which advertised phone a link
        // goes to; a bye asks the phone that opened a link to close it.
        private const val LINK_MAGIC = 0x4C
        private const val LINK_VERSION = 1
        private const val HELLO = 1
        private const val BYE = 2
        private const val LINK_FRAME_SIZE = 7
    }

    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter get() = manager.adapter

    /**
     * Random, advertised, and changed every [TOKEN_ROTATE_MS] so the phone can't be followed through
     * the day by it. The phone with the lower token opens the connection, so each pair links once.
     */
    private var token = MeshCrypto.randomInt()
    private var tokenSince = 0L

    private var running = false
    /** Bumped on every start so a stale housekeeping loop from an earlier run exits. */
    private var generation = 0
    private var server: BluetoothGattServer? = null
    private var txCharacteristic: BluetoothGattCharacteristic? = null
    private var serviceReady = false
    private var lastServerAttempt = 0L
    private var canAdvertise = true
    private var advertising = false
    private var lastAdvertiseAttempt = 0L
    private var lastScanStart = 0L
    private var scanMode = ScanSettings.SCAN_MODE_LOW_LATENCY
    private var lastRotation = 0L
    private val serverMtu = HashMap<String, Int>()
    /** Long writes in progress, by device address (other implementations may use them for big fragments). */
    private val preparedWrites = HashMap<String, ByteArrayOutputStream>()

    private inner class Link(val id: String, val address: String, val isClient: Boolean, val device: BluetoothDevice) {
        var gatt: BluetoothGatt? = null
        /** Client links: the neighbour's RX characteristic we write to. */
        var rx: BluetoothGattCharacteristic? = null
        var mtu = 23
        var up = false
        /** The neighbour's advertised token, from its hello. */
        var peerToken: Int? = null
        /** Every token the neighbour has used on this link; stale adverts can still carry an old one. */
        val peerTokens = HashSet<Int>()
        /** An incoming link being wound down: it only carries our bye now. */
        var closing = false
        val live = ArrayDeque<ByteArray>()
        val bulk = ArrayDeque<ByteArray>()
        var fragments: List<ByteArray> = emptyList()
        var nextFragment = 0
        var inFlight = false
        var inFlightSince = 0L
        var retryScheduled = false
        var writeRetries = 0
        val fragmenter = Fragmenter()
        val reassembler = Reassembler()
        val createdAt = now()
        var lastReceived = createdAt
        var lastSent = createdAt
    }

    /** [token] is null for phones that can't advertise one (iPhones); links to them are de-duplicated by hello. */
    private class Candidate(val device: BluetoothDevice, var token: Int?, var lastSeen: Long, val firstSeen: Long)

    private val links = HashMap<String, Link>()
    private val candidates = HashMap<String, Candidate>()
    private val backoff = HashMap<String, Pair<Int, Long>>()

    /** Links that are connected and ready to carry packets. */
    val activeLinks: Int get() = links.values.count { it.up && !it.closing }

    val isRunning: Boolean get() = running

    fun start() {
        if (running) return
        val a = adapter
        if (a == null || !a.isEnabled) {
            log("Bluetooth is off or unavailable")
            return
        }
        running = true
        val gen = ++generation
        tokenSince = now()
        openServer()
        startScan()
        thread.schedule(HOUSEKEEPING_MS) { housekeeping(gen) }
        log("BLE link layer started")
    }

    fun stop() {
        if (!running) return
        running = false
        try { adapter?.bluetoothLeScanner?.stopScan(scanCallback) } catch (_: Exception) { }
        stopAdvertising()
        links.values.toList().forEach { link ->
            if (link.isClient) {
                try {
                    link.gatt?.disconnect()
                    link.gatt?.close()
                } catch (_: Exception) { }
            } else {
                disconnectIncoming(link.device)
            }
            if (link.up && !link.closing) listener.onLinkDown(link.id)
        }
        links.clear()
        candidates.clear()
        backoff.clear()
        serverMtu.clear()
        preparedWrites.clear()
        closeServer()
        log("BLE link layer stopped")
    }

    override fun send(linkId: String, data: ByteArray, bulk: Boolean) {
        val link = links[linkId] ?: return
        if (link.up && !link.closing) enqueue(link, data, bulk)
    }

    private fun enqueue(link: Link, data: ByteArray, bulk: Boolean) {
        if (link.live.size + link.bulk.size >= MAX_QUEUED_FRAMES) {
            // Shed catch-up traffic first; the minute-by-minute resync recovers anything dropped.
            if (link.bulk.isNotEmpty()) {
                link.bulk.removeFirst()
            } else {
                log("a link's queue is full; dropped a frame")
                return
            }
        }
        (if (bulk) link.bulk else link.live).addLast(data)
        pump(link)
    }

    // ---- GATT server + advertising ----

    private fun openServer() {
        lastServerAttempt = now()
        serviceReady = false
        val s = try { manager.openGattServer(context, serverCallback) } catch (_: Exception) { null }
        if (s == null) {
            log("could not open GATT server; retrying shortly")
            return
        }
        server = s
        val rx = BluetoothGattCharacteristic(
            RX_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        val tx = BluetoothGattCharacteristic(TX_UUID, BluetoothGattCharacteristic.PROPERTY_NOTIFY, 0)
        tx.addDescriptor(
            BluetoothGattDescriptor(CCCD_UUID, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE)
        )
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(rx)
        service.addCharacteristic(tx)
        txCharacteristic = tx
        if (!s.addService(service)) log("GATT service could not be added; retrying shortly")
        // Advertising starts once the service is registered (onServiceAdded).
    }

    private fun closeServer() {
        try { server?.close() } catch (_: Exception) { }
        server = null
        txCharacteristic = null
        serviceReady = false
    }

    private fun startAdvertising() {
        lastAdvertiseAttempt = now()
        val advertiser = adapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            if (canAdvertise) log("this phone can't advertise over BLE; it can still connect to others")
            canAdvertise = false
            return
        }
        // A failed start can leave the callback registered, and every retry would then be "already started".
        try { advertiser.stopAdvertising(advertiseCallback) } catch (_: Exception) { }
        advertising = false
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .addManufacturerData(MANUFACTURER_ID, ByteBuffer.allocate(4).putInt(token).array())
            .build()
        try {
            advertiser.startAdvertising(settings, data, advertiseCallback)
        } catch (e: Exception) {
            log("advertising not possible: ${e.message}")
        }
    }

    private fun stopAdvertising() {
        advertising = false
        try { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) } catch (_: Exception) { }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            thread.post {
                advertising = true
                log("advertising")
            }
        }

        override fun onStartFailure(errorCode: Int) {
            thread.post {
                advertising = false
                if (errorCode == AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED) canAdvertise = false
                log("advertising failed ($errorCode); retrying shortly")
            }
        }
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            thread.post {
                if (!running) return@post
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    serviceReady = true
                    startAdvertising()
                } else {
                    log("GATT service registration failed ($status); retrying shortly")
                }
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                thread.post {
                    serverMtu.remove(device.address)
                    preparedWrites.remove(device.address)
                    links["s:" + device.address]?.let { dropServerLink(it) }
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            thread.post {
                serverMtu[device.address] = mtu
                links["s:" + device.address]?.mtu = mtu
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?
        ) {
            val v = value?.copyOf()
            thread.post {
                val id = "s:" + device.address
                val enable = descriptor.uuid == CCCD_UUID && v != null && v.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                // Android can't reliably disconnect a phone from this side, so refuse with an error the
                // other phone sees: it then closes the connection and backs off.
                val refuse = enable && (!running || (links[id] == null && links.values.count { !it.isClient } >= MAX_SERVER_LINKS))
                if (responseNeeded) respond(device, requestId, if (refuse) ATT_INSUFFICIENT_RESOURCES else BluetoothGatt.GATT_SUCCESS)
                if (descriptor.uuid != CCCD_UUID || !running) return@post
                if (refuse) {
                    log("incoming link limit reached; refusing a phone")
                    return@post
                }
                if (enable) {
                    if (links[id] != null) return@post
                    val link = Link(id, device.address, false, device).apply { mtu = serverMtu[device.address] ?: 23 }
                    links[id] = link
                    markUp(link)
                } else {
                    links[id]?.let { dropServerLink(it) }
                }
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?
        ) {
            val v = value?.copyOf()
            thread.post {
                if (preparedWrite) {
                    // Long write: collect the parts, deliver on execute. The response echoes the part.
                    val buffer = preparedWrites.getOrPut(device.address) { ByteArrayOutputStream() }
                    val ok = characteristic.uuid == RX_UUID && v != null && offset == buffer.size() && offset + v.size <= MAX_PREPARED_WRITE
                    if (ok) buffer.write(v!!) else preparedWrites.remove(device.address)
                    if (responseNeeded) {
                        try {
                            server?.sendResponse(device, requestId, if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_INVALID_OFFSET, offset, v)
                        } catch (_: Exception) { }
                    }
                    return@post
                }
                if (responseNeeded) respond(device, requestId)
                if (characteristic.uuid != RX_UUID || v == null) return@post
                links["s:" + device.address]?.let { receive(it, v) }
            }
        }

        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            thread.post {
                val data = preparedWrites.remove(device.address)?.toByteArray()
                respond(device, requestId)
                if (execute && data != null && data.isNotEmpty()) links["s:" + device.address]?.let { receive(it, data) }
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            thread.post { links["s:" + device.address]?.let { sent(it, status == BluetoothGatt.GATT_SUCCESS) } }
        }
    }

    private fun respond(device: BluetoothDevice, requestId: Int, status: Int = BluetoothGatt.GATT_SUCCESS) {
        try { server?.sendResponse(device, requestId, status, 0, null) } catch (_: Exception) { }
    }

    private fun dropServerLink(link: Link) {
        if (links[link.id] !== link) return
        links.remove(link.id)
        if (link.up && !link.closing) listener.onLinkDown(link.id)
    }

    /** cancelConnection only works for connections the server holds; connect() makes it hold this one. */
    private fun disconnectIncoming(device: BluetoothDevice) {
        val s = server ?: return
        try {
            s.connect(device, false)
            s.cancelConnection(device)
        } catch (_: Exception) { }
    }

    // ---- Scanning + GATT client ----

    private fun startScan() {
        val scanner = adapter?.bluetoothLeScanner ?: return
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build())
        val mode = desiredScanMode()
        val settings = ScanSettings.Builder()
            .setScanMode(mode)
            .setReportDelay(0)
            .build()
        try {
            scanner.startScan(filters, settings, scanCallback)
            scanMode = mode
            lastScanStart = now()
        } catch (e: Exception) {
            log("scan could not start: ${e.message}")
        }
    }

    private fun restartScan() {
        try { adapter?.bluetoothLeScanner?.stopScan(scanCallback) } catch (_: Exception) { }
        lastScanStart = now()
        thread.schedule(500) { if (running) startScan() }
    }

    /** Scan hard while looking for neighbours; ease off once every outgoing slot is in use. */
    private fun desiredScanMode(): Int =
        if (clientLinkCount() < MAX_CLIENT_LINKS) ScanSettings.SCAN_MODE_LOW_LATENCY else ScanSettings.SCAN_MODE_BALANCED

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            thread.post { onFound(result) }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            val copy = results.toList()
            thread.post { copy.forEach(::onFound) }
        }

        override fun onScanFailed(errorCode: Int) {
            thread.post {
                log("scan failed ($errorCode); retrying shortly")
                // Android throttles apps that start scans too often, so wait before trying again.
                lastScanStart = now() - SCAN_RESTART_MS + SCAN_RETRY_MS
            }
        }
    }

    private fun onFound(result: ScanResult) {
        if (!running) return
        // The scan filter already matched the mesh service. Android phones add a token; iPhones can't.
        val data = result.scanRecord?.getManufacturerSpecificData(MANUFACTURER_ID)
        val peerToken = if (data != null && data.size >= 4) ByteBuffer.wrap(data, 0, 4).int else null
        if (peerToken == token) return
        val address = result.device.address
        val t = now()
        val candidate = candidates[address]
        if (candidate == null) {
            candidates[address] = Candidate(result.device, peerToken, t, t)
        } else {
            candidate.token = peerToken
            candidate.lastSeen = t
        }
        maybeConnect(address)
    }

    private fun clientLinkCount() = links.values.count { it.isClient }

    /** Phones connect from a different address than they advertise, so match on the token too. */
    private fun isLinked(address: String, peerToken: Int?) =
        links.containsKey("c:$address") || links.containsKey("s:$address") ||
            (peerToken != null && links.values.any { peerToken in it.peerTokens })

    private fun maybeConnect(address: String) {
        val candidate = candidates[address] ?: return
        if (isLinked(address, candidate.token)) return
        val t = now()
        if (t - candidate.lastSeen > CANDIDATE_FRESH_MS) return
        backoff[address]?.let { if (t < it.second) return }
        if (clientLinkCount() >= MAX_CLIENT_LINKS) return
        // The lower token connects; the other side takes over if no link has formed after a while.
        // A phone without a token can't connect to us by that rule, so we always do.
        val peerToken = candidate.token
        val ours = peerToken == null || Integer.compareUnsigned(token, peerToken) < 0
        if (!ours && t - candidate.firstSeen < SYMMETRY_OVERRIDE_MS) return
        connect(candidate.device)
    }

    private fun connect(device: BluetoothDevice) {
        val id = "c:" + device.address
        val link = Link(id, device.address, true, device)
        links[id] = link
        link.gatt = try {
            device.connectGatt(context, false, clientCallback, BluetoothDevice.TRANSPORT_LE)
        } catch (_: Exception) {
            null
        }
        if (link.gatt == null) {
            links.remove(id)
            fail(device.address)
            return
        }
        thread.schedule(CONNECT_TIMEOUT_MS) {
            if (links[id] === link && !link.up) {
                log("connection to a phone timed out")
                dropClientLink(link, failed = true)
            }
        }
    }

    private fun clientLink(gatt: BluetoothGatt): Link? {
        val link = links["c:" + gatt.device.address]
        return if (link != null && link.gatt === gatt) link else null
    }

    private val clientCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            thread.post {
                val link = clientLink(gatt)
                if (link == null) {
                    try { gatt.close() } catch (_: Exception) { }
                    return@post
                }
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    if (!gatt.requestMtu(REQUESTED_MTU) && !gatt.discoverServices()) dropClientLink(link, failed = true)
                } else {
                    // A link that never came up, or one that was cut, backs off before the next try.
                    dropClientLink(link, failed = true)
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            thread.post {
                val link = clientLink(gatt) ?: return@post
                if (status == BluetoothGatt.GATT_SUCCESS) link.mtu = mtu
                if (link.rx == null && !gatt.discoverServices()) dropClientLink(link, failed = true)
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            thread.post {
                val link = clientLink(gatt) ?: return@post
                val service = gatt.getService(SERVICE_UUID)
                val rx = service?.getCharacteristic(RX_UUID)
                val tx = service?.getCharacteristic(TX_UUID)
                val cccd = tx?.getDescriptor(CCCD_UUID)
                if (status != BluetoothGatt.GATT_SUCCESS || rx == null || tx == null || cccd == null) {
                    dropClientLink(link, failed = true)
                    return@post
                }
                link.rx = rx
                gatt.setCharacteristicNotification(tx, true)
                val ok = try {
                    if (Build.VERSION.SDK_INT >= 33) {
                        gatt.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS
                    } else {
                        @Suppress("DEPRECATION")
                        cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        @Suppress("DEPRECATION")
                        gatt.writeDescriptor(cccd)
                    }
                } catch (_: Exception) {
                    false
                }
                if (!ok) dropClientLink(link, failed = true)
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            thread.post {
                val link = clientLink(gatt) ?: return@post
                // An error here means the other phone refused the link (e.g. it's full).
                if (status == BluetoothGatt.GATT_SUCCESS) markUp(link) else dropClientLink(link, failed = true)
            }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            if (characteristic.uuid != TX_UUID) return
            val copy = value.copyOf()
            thread.post { clientLink(gatt)?.let { receive(it, copy) } }
        }

        @Deprecated("Used on Android 12 and older")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= 33 || characteristic.uuid != TX_UUID) return
            @Suppress("DEPRECATION")
            val copy = characteristic.value?.copyOf() ?: return
            thread.post { clientLink(gatt)?.let { receive(it, copy) } }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            thread.post { clientLink(gatt)?.let { sent(it, status == BluetoothGatt.GATT_SUCCESS) } }
        }
    }

    private fun dropClientLink(link: Link, failed: Boolean) {
        if (links[link.id] !== link) return
        links.remove(link.id)
        try {
            link.gatt?.disconnect()
            link.gatt?.close()
        } catch (_: Exception) { }
        if (link.up) listener.onLinkDown(link.id)
        if (failed) fail(link.address) else backoff.remove(link.address)
    }

    private fun closeLink(link: Link, failed: Boolean = false) {
        if (link.isClient) {
            dropClientLink(link, failed)
            return
        }
        if (link.closing) return
        // Android can't reliably disconnect a phone from the accepting side, so ask it to go:
        // stop routing over the link, send a bye, and cut the connection shortly after.
        if (link.up) listener.onLinkDown(link.id)
        link.closing = true
        link.live.clear()
        link.bulk.clear()
        if (link.up) {
            link.live.addLast(linkFrame(BYE))
            pump(link)
        }
        thread.schedule(BYE_GRACE_MS) {
            disconnectIncoming(link.device)
            if (links[link.id] === link) links.remove(link.id)
        }
    }

    private fun fail(address: String) {
        val failures = (backoff[address]?.first ?: 0) + 1
        backoff[address] = failures to now() + minOf(60_000L, 2_000L shl minOf(failures, 5))
    }

    // ---- Link data path ----

    private fun markUp(link: Link) {
        if (link.up) return
        link.up = true
        link.lastReceived = now()
        backoff.remove(link.address)
        log("link up: ${link.id.take(2)}… (mtu ${link.mtu})")
        enqueue(link, linkFrame(HELLO), bulk = false)
        listener.onLinkUp(link.id)
    }

    private fun linkFrame(type: Int): ByteArray =
        ByteBuffer.allocate(LINK_FRAME_SIZE)
            .put(LINK_MAGIC.toByte()).put(LINK_VERSION.toByte()).put(type.toByte()).putInt(token)
            .array()

    private fun receive(link: Link, fragment: ByteArray) {
        if (link.closing) return
        if (!link.up) {
            // A notification can overtake the descriptor-write callback. It proves notifications are on.
            if (link.isClient && link.rx != null) markUp(link) else return
        }
        link.lastReceived = now()
        val frame = link.reassembler.accept(fragment, now()) ?: return
        if (frame.size == LINK_FRAME_SIZE && frame[0] == LINK_MAGIC.toByte()) {
            if (frame[1] != LINK_VERSION.toByte()) return
            val peerToken = ByteBuffer.wrap(frame, 3, 4).int
            when (frame[2].toInt()) {
                HELLO -> onHello(link, peerToken)
                BYE -> if (link.isClient) {
                    log("a phone asked to close a link")
                    dropClientLink(link, failed = false)
                    backoff[link.address] = 0 to now() + ROTATED_OUT_BACKOFF_MS
                }
            }
            return
        }
        listener.onData(link.id, frame)
    }

    /**
     * Two links to the same phone happen because phones connect from a different address than they
     * advertise. Both phones keep the one opened by the phone with the lower token and close the other.
     */
    private fun onHello(link: Link, peerToken: Int) {
        link.peerToken = peerToken
        link.peerTokens += peerToken
        val twin = links.values.firstOrNull { it !== link && !it.closing && peerToken in it.peerTokens } ?: return
        val weOpen = Integer.compareUnsigned(token, peerToken) < 0
        val drop = if (link.isClient != twin.isClient) {
            if (link.isClient == weOpen) twin else link
        } else {
            if (link.createdAt >= twin.createdAt) link else twin
        }
        log("closing a duplicate link")
        val tokenlessTwin = drop.isClient && candidates[drop.address]?.token == null
        closeLink(drop)
        // A tokenless advert (an iPhone) can't be matched to this phone, so don't keep reconnecting to it.
        // Set after closing: closing a client link clears the address's backoff.
        if (tokenlessTwin) backoff[drop.address] = 0 to now() + TOKENLESS_TWIN_BACKOFF_MS
    }

    private fun pump(link: Link) {
        if (!link.up || link.inFlight || link.retryScheduled || links[link.id] !== link) return
        while (link.nextFragment >= link.fragments.size) {
            val frame = link.live.removeFirstOrNull() ?: link.bulk.removeFirstOrNull() ?: return
            link.fragments = link.fragmenter.split(frame, minOf(link.mtu - 3, MAX_ATTRIBUTE_VALUE))
            link.nextFragment = 0
        }
        val fragment = link.fragments[link.nextFragment]
        val ok = if (link.isClient) writeToServer(link, fragment) else notifyClient(link, fragment)
        if (ok) {
            link.nextFragment++
            link.inFlight = true
            link.inFlightSince = now()
            link.lastSent = link.inFlightSince
            return
        }
        // The Bluetooth stack is busy: try again shortly.
        retryLater(link)
    }

    /** A write or notification finished. On failure, send the same fragment again. */
    private fun sent(link: Link, success: Boolean) {
        link.inFlight = false
        if (success) {
            link.writeRetries = 0
            pump(link)
        } else {
            if (link.nextFragment > 0) link.nextFragment--
            retryLater(link)
        }
    }

    private fun retryLater(link: Link) {
        if (link.retryScheduled) return
        if (++link.writeRetries > MAX_WRITE_RETRIES) {
            log("a link stopped accepting data; closing it")
            closeLink(link, failed = true)
            return
        }
        link.retryScheduled = true
        thread.schedule(RETRY_DELAY_MS) {
            link.retryScheduled = false
            pump(link)
        }
    }

    private fun writeToServer(link: Link, data: ByteArray): Boolean {
        val gatt = link.gatt ?: return false
        val rx = link.rx ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= 33) {
                gatt.writeCharacteristic(rx, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) == BluetoothStatusCodes.SUCCESS
            } else {
                rx.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                @Suppress("DEPRECATION")
                rx.value = data
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(rx)
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun notifyClient(link: Link, data: ByteArray): Boolean {
        val s = server ?: return false
        val tx = txCharacteristic ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= 33) {
                s.notifyCharacteristicChanged(link.device, tx, false, data) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                tx.value = data
                @Suppress("DEPRECATION")
                s.notifyCharacteristicChanged(link.device, tx, false)
            }
        } catch (_: Exception) {
            false
        }
    }

    // ---- Housekeeping ----

    private fun housekeeping(gen: Int) {
        if (!running || gen != generation) return
        try {
            tidy(now())
        } finally {
            thread.schedule(HOUSEKEEPING_MS) { housekeeping(gen) }
        }
    }

    private fun tidy(t: Long) {
        links.values.toList().forEach { link ->
            if (link.inFlight && t - link.inFlightSince > WRITE_TIMEOUT_MS) {
                link.inFlight = false
                pump(link)
            }
            link.reassembler.expire(t)
            if (!link.up || link.closing) return@forEach
            when {
                // Half-open links (refused, or the other app died) would otherwise swallow messages.
                link.peerToken == null && t - link.createdAt > HELLO_DEADLINE_MS ||
                    t - link.lastReceived > LINK_SILENT_MS -> {
                    log("closing a silent link")
                    closeLink(link, failed = true)
                }
                t - link.lastSent > KEEPALIVE_MS && link.live.isEmpty() && link.bulk.isEmpty() ->
                    enqueue(link, linkFrame(HELLO), bulk = false)
            }
        }
        candidates.entries.removeIf { t - it.value.lastSeen > CANDIDATE_TTL_MS }
        if (t - tokenSince > TOKEN_ROTATE_MS) rotateToken(t)
        if (t - lastRotation > ROTATE_EVERY_MS) {
            lastRotation = t
            rotateLinks(t)
        }
        candidates.keys.toList().forEach(::maybeConnect)
        val modeChanged = desiredScanMode() != scanMode && t - lastScanStart > SCAN_MODE_SWITCH_MIN_MS
        if (t - lastScanStart > SCAN_RESTART_MS || modeChanged) restartScan()
        if (!serviceReady && t - lastServerAttempt > SERVER_RETRY_MS) {
            closeServer()
            openServer()
        }
        if (serviceReady && canAdvertise && !advertising && t - lastAdvertiseAttempt > ADVERTISE_RETRY_MS) startAdvertising()
    }

    /** Called when the mesh identity rotates, so the Bluetooth token changes at the same moment. */
    fun rotateTokenNow() {
        if (running) rotateToken(now())
    }

    /** New token: tell current neighbours first, then advertise it, so they don't mistake us for a new phone. */
    private fun rotateToken(t: Long) {
        token = MeshCrypto.randomInt()
        tokenSince = t
        val hello = linkFrame(HELLO)
        links.values.filter { it.up && !it.closing }.forEach { enqueue(it, hello, bulk = false) }
        val gen = generation
        thread.schedule(2_000) {
            if (running && gen == generation && serviceReady) startAdvertising()
        }
    }

    /**
     * In a moving crowd, drop the oldest outgoing link now and then when other phones are waiting,
     * so the mesh keeps re-forming around people as they move.
     */
    private fun rotateLinks(t: Long) {
        val clients = links.values.filter { it.isClient && it.up }
        if (clients.size < MAX_CLIENT_LINKS) return
        val waiting = candidates.any { (address, c) ->
            !isLinked(address, c.token) && t - c.lastSeen < CANDIDATE_FRESH_MS && (backoff[address]?.second ?: 0L) <= t
        }
        if (!waiting) return
        val oldest = clients.minByOrNull { it.createdAt } ?: return
        if (t - oldest.createdAt < MIN_AGE_TO_ROTATE_MS) return
        log("rotating out an old link to reach new neighbours")
        dropClientLink(oldest, failed = false)
        backoff[oldest.address] = 0 to t + ROTATED_OUT_BACKOFF_MS
    }

    private fun now() = SystemClock.elapsedRealtime()
}
