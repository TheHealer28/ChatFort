package chat.simplex.app.nearby

import android.bluetooth.BluetoothManager
import android.bluetooth.le.*
import android.content.Context
import android.os.Handler
import android.os.Looper
import chat.simplex.common.platform.Log
import java.security.MessageDigest

/**
 * BLE advertiser + scanner for finding individual people nearby.
 *
 * Protocol — uses manufacturer data (company ID 0xFFFF):
 *   Byte 0:    mode  (0x00 = available, 0x01 = requesting, 0x02 = accepting)
 *   Bytes 1-4: sender identity hash (SHA-256 of display name, first 4 bytes)
 *   Bytes 5-8: target identity hash  (zeroed for mode 0x00)
 *   Bytes 9+:  display name (UTF-8, truncated to 15 bytes)
 */
class NearbyPeopleDiscovery(private val context: Context) {

    companion object {
        private const val COMPANY_ID = 0xFFFF   // reserved for testing
        private const val MAX_NAME_BYTES = 15
        private const val TAG = "NearbyPeople"

        /** 4-byte identity hash from a display name */
        fun identityHash(name: String): ByteArray {
            val digest = MessageDigest.getInstance("SHA-256")
            return digest.digest(name.trim().toByteArray(Charsets.UTF_8)).copyOfRange(0, 4)
        }
    }

    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var isAdvertising = false
    private var isScanning = false
    private var myName: String = ""
    private var myHash: ByteArray = ByteArray(4)
    private val mainHandler = Handler(Looper.getMainLooper())

    // Callbacks — invoked on the main thread
    var onPersonDiscovered: ((DiscoveredPerson) -> Unit)? = null
    var onConnectionRequested: ((DiscoveredPerson) -> Unit)? = null
    var onConnectionAccepted: ((DiscoveredPerson) -> Unit)? = null

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            Log.d(TAG, "People advertising started")
            isAdvertising = true
        }
        override fun onStartFailure(errorCode: Int) {
            Log.e(TAG, "People advertising failed: $errorCode")
            isAdvertising = false
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            result ?: return
            val record = result.scanRecord ?: return

            val mfgData = record.getManufacturerSpecificData(COMPANY_ID) ?: return
            if (mfgData.size < 9) return

            val mode = mfgData[0].toInt() and 0xFF
            val senderHash = mfgData.copyOfRange(1, 5)
            val targetHash = mfgData.copyOfRange(5, 9)
            val nameBytes = mfgData.copyOfRange(9, mfgData.size)
            val name = String(nameBytes, Charsets.UTF_8)

            // Ignore our own advertisements
            if (senderHash.contentEquals(myHash)) return

            val person = DiscoveredPerson(
                name = name,
                identityHash = senderHash,
                lastSeen = System.currentTimeMillis()
            )

            mainHandler.post {
                when (mode) {
                    0x00 -> onPersonDiscovered?.invoke(person)
                    0x01 -> {
                        // Someone requesting connection — is it aimed at me?
                        if (targetHash.contentEquals(myHash)) {
                            onConnectionRequested?.invoke(person)
                        }
                    }
                    0x02 -> {
                        // Someone accepted — is it my request?
                        if (targetHash.contentEquals(myHash)) {
                            onConnectionAccepted?.invoke(person)
                        }
                    }
                }
            }
        }
    }

    /** Start advertising as available and scanning for others */
    fun startDiscovery(displayName: String) {
        myName = displayName
        myHash = identityHash(displayName)

        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bluetoothManager?.adapter
        if (adapter == null || !adapter.isEnabled) {
            Log.e(TAG, "Bluetooth not available or not enabled")
            return
        }

        advertiser = adapter.bluetoothLeAdvertiser
        scanner = adapter.bluetoothLeScanner

        // Advertise as available
        advertiseMode(0x00, ByteArray(4))
        // Start scanning
        startScanning()
    }

    /** Switch to "requesting connection" mode targeting a specific person */
    fun requestConnection(target: DiscoveredPerson) {
        stopAdvertising()
        advertiseMode(0x01, target.identityHash)
    }

    /** Switch to "accepting connection" mode targeting the requester */
    fun acceptConnection(requester: DiscoveredPerson) {
        stopAdvertising()
        advertiseMode(0x02, requester.identityHash)
    }

    private fun advertiseMode(mode: Int, targetHash: ByteArray) {
        val nameBytes = myName.toByteArray(Charsets.UTF_8).let {
            if (it.size > MAX_NAME_BYTES) it.copyOfRange(0, MAX_NAME_BYTES) else it
        }

        val payload = ByteArray(9 + nameBytes.size)
        payload[0] = mode.toByte()
        System.arraycopy(myHash, 0, payload, 1, 4)
        System.arraycopy(targetHash, 0, payload, 5, 4)
        System.arraycopy(nameBytes, 0, payload, 9, nameBytes.size)

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(false)
            .setTimeout(0)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addManufacturerData(COMPANY_ID, payload)
            .build()

        try {
            advertiser?.startAdvertising(settings, data, advertiseCallback)
        } catch (e: SecurityException) {
            Log.e(TAG, "Advertise permission denied: ${e.message}")
        }
    }

    private fun startScanning() {
        // Filter by manufacturer data company ID
        val filterData = ByteArray(1)  // at least 1 byte so the filter matches
        val filterMask = ByteArray(1)  // mask=0 means don't check the byte values, just company ID

        val filter = ScanFilter.Builder()
            .setManufacturerData(COMPANY_ID, filterData, filterMask)
            .build()

        val scanSettings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        try {
            scanner?.startScan(listOf(filter), scanSettings, scanCallback)
            isScanning = true
            Log.d(TAG, "People scanning started")
        } catch (e: SecurityException) {
            Log.e(TAG, "Scan permission denied: ${e.message}")
        }
    }

    private fun stopAdvertising() {
        if (isAdvertising) {
            try { advertiser?.stopAdvertising(advertiseCallback) } catch (_: SecurityException) {}
            isAdvertising = false
        }
    }

    /** Stop all BLE activity */
    fun stopDiscovery() {
        stopAdvertising()
        if (isScanning) {
            try { scanner?.stopScan(scanCallback) } catch (_: SecurityException) {}
            isScanning = false
        }
        advertiser = null
        scanner = null
    }
}
