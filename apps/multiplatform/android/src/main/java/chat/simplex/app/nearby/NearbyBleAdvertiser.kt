package chat.simplex.app.nearby

import android.bluetooth.BluetoothManager
import android.bluetooth.le.*
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import chat.simplex.common.platform.Log
import java.util.UUID

/**
 * BLE advertiser for Nearby Chat room discovery.
 * The room creator advertises the room code hash so nearby devices can detect
 * that a room exists before attempting a Wi-Fi Direct connection.
 *
 * BLE is used ONLY for discovery — not for data transfer.
 */
class NearbyBleAdvertiser(private val context: Context) {

    companion object {
        /** Custom 128-bit UUID identifying Inqalaab Nearby Chat service */
        val SERVICE_UUID: UUID = UUID.fromString("0000ab01-0000-1000-8000-00805f9b34fb")
        private const val TAG = "NearbyBleAdv"
    }

    private var advertiser: BluetoothLeAdvertiser? = null
    private var isAdvertising = false

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            Log.d(TAG, "BLE advertising started successfully")
            isAdvertising = true
        }

        override fun onStartFailure(errorCode: Int) {
            Log.e(TAG, "BLE advertising failed with error code: $errorCode")
            isAdvertising = false
        }
    }

    /**
     * Start advertising the room's presence.
     * @param roomCodeHash 8-byte hash from NearbyCrypto.hashRoomCode()
     */
    fun startAdvertising(roomCodeHash: ByteArray) {
        if (isAdvertising) return

        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bluetoothManager?.adapter
        if (adapter == null || !adapter.isEnabled) {
            Log.e(TAG, "Bluetooth not available or not enabled")
            return
        }

        advertiser = adapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            Log.e(TAG, "BLE advertising not supported on this device")
            return
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(false)
            .setTimeout(0)  // advertise indefinitely
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .addServiceData(ParcelUuid(SERVICE_UUID), roomCodeHash)
            .build()

        try {
            advertiser?.startAdvertising(settings, data, advertiseCallback)
        } catch (e: SecurityException) {
            Log.e(TAG, "BLE advertise permission denied: ${e.message}")
        }
    }

    /** Stop advertising */
    fun stopAdvertising() {
        if (!isAdvertising) return
        try {
            advertiser?.stopAdvertising(advertiseCallback)
        } catch (e: SecurityException) {
            Log.e(TAG, "BLE stop advertise permission denied: ${e.message}")
        }
        isAdvertising = false
        advertiser = null
    }
}
