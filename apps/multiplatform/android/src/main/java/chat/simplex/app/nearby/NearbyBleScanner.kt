package chat.simplex.app.nearby

import android.bluetooth.BluetoothManager
import android.bluetooth.le.*
import android.content.Context
import android.os.ParcelUuid
import chat.simplex.common.platform.Log

/**
 * BLE scanner for Nearby Chat room discovery.
 * Scans for nearby devices advertising the Inqalaab Nearby service UUID.
 * Extracts room code hashes from service data.
 *
 * Used by room joiners to verify a room exists nearby before
 * attempting Wi-Fi Direct connection.
 */
class NearbyBleScanner(private val context: Context) {

    companion object {
        private const val TAG = "NearbyBleScan"
    }

    private var scanner: BluetoothLeScanner? = null
    private var isScanning = false

    /** Callback invoked when a room is discovered. Receives the 8-byte room code hash. */
    var onRoomDiscovered: ((ByteArray) -> Unit)? = null

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            result?.scanRecord?.let { record ->
                val serviceData = record.getServiceData(ParcelUuid(NearbyBleAdvertiser.SERVICE_UUID))
                if (serviceData != null && serviceData.size >= 8) {
                    val hash = serviceData.copyOfRange(0, 8)
                    Log.d(TAG, "Discovered nearby room: ${hash.toHex()}")
                    onRoomDiscovered?.invoke(hash)
                }
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "BLE scan failed with error code: $errorCode")
            isScanning = false
        }
    }

    /** Start scanning for nearby rooms */
    fun startScanning() {
        if (isScanning) return

        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bluetoothManager?.adapter
        if (adapter == null || !adapter.isEnabled) {
            Log.e(TAG, "Bluetooth not available or not enabled")
            return
        }

        scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            Log.e(TAG, "BLE scanning not supported on this device")
            return
        }

        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(NearbyBleAdvertiser.SERVICE_UUID))
            .build()

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        try {
            scanner?.startScan(listOf(filter), settings, scanCallback)
            isScanning = true
            Log.d(TAG, "BLE scanning started")
        } catch (e: SecurityException) {
            Log.e(TAG, "BLE scan permission denied: ${e.message}")
        }
    }

    /** Stop scanning */
    fun stopScanning() {
        if (!isScanning) return
        try {
            scanner?.stopScan(scanCallback)
        } catch (e: SecurityException) {
            Log.e(TAG, "BLE stop scan permission denied: ${e.message}")
        }
        isScanning = false
        scanner = null
    }

    /** Check if a specific room code hash has been discovered */
    private val discoveredHashes = mutableSetOf<String>()

    fun isRoomNearby(roomCodeHash: ByteArray): Boolean {
        return discoveredHashes.contains(roomCodeHash.toHex())
    }

    /** Internal: record discovered hashes */
    init {
        onRoomDiscovered = { hash ->
            discoveredHashes.add(hash.toHex())
        }
    }
}
