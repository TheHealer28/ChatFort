package chat.simplex.app.nearby

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.p2p.*
import android.os.Build
import android.os.Looper
import chat.simplex.common.platform.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import java.net.InetAddress

/**
 * Manages Wi-Fi Direct (Wi-Fi P2P) connections for Nearby Chat.
 *
 * Room creator → Group Owner (GO) that hosts the Wi-Fi Direct group
 * Room joiner → Client that discovers and connects to the GO
 *
 * After connection, [groupOwnerAddress] provides the GO's IP for TCP socket communication.
 */
class NearbyWifiDirect(private val context: Context) {

    companion object {
        private const val TAG = "NearbyWifiP2P"
    }

    private var manager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    private var isRegistered = false

    /** Emits when we have a connection with group info */
    val connectionReady = MutableStateFlow(false)

    /** The Group Owner's IP address (available after connection) */
    var groupOwnerAddress: InetAddress? = null
        private set

    /** Whether this device is the Group Owner */
    var isGroupOwner: Boolean = false
        private set

    /** Initialize Wi-Fi P2P manager and register receiver */
    fun initialize() {
        manager = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        channel = manager?.initialize(context, Looper.getMainLooper(), null)

        if (manager == null || channel == null) {
            Log.e(TAG, "Wi-Fi Direct is not supported on this device")
            return
        }

        receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                when (intent?.action) {
                    WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                        val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                        if (state == WifiP2pManager.WIFI_P2P_STATE_ENABLED) {
                            Log.d(TAG, "Wi-Fi P2P is enabled")
                        } else {
                            Log.w(TAG, "Wi-Fi P2P is NOT enabled")
                        }
                    }

                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                        Log.d(TAG, "Peers list changed")
                    }

                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(WifiP2pManager.EXTRA_WIFI_P2P_INFO, WifiP2pInfo::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(WifiP2pManager.EXTRA_WIFI_P2P_INFO)
                        }

                        if (info != null && info.groupFormed) {
                            isGroupOwner = info.isGroupOwner
                            groupOwnerAddress = info.groupOwnerAddress
                            Log.d(TAG, "Connected! isGO=$isGroupOwner goAddr=$groupOwnerAddress")
                            connectionReady.value = true
                        } else {
                            Log.d(TAG, "Disconnected from Wi-Fi Direct group")
                            connectionReady.value = false
                            groupOwnerAddress = null
                        }
                    }

                    WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION -> {
                        Log.d(TAG, "This device info changed")
                    }
                }
            }
        }

        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        isRegistered = true
        Log.d(TAG, "Wi-Fi Direct initialized")
    }

    /**
     * Create a Wi-Fi Direct group (become Group Owner).
     * Clears any stale group from a previous session first.
     */
    @SuppressLint("MissingPermission")
    fun createGroup(onResult: (Boolean) -> Unit) {
        // Remove any lingering group first, then create fresh
        manager?.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Cleaned up old group")
                doCreateGroup(onResult)
            }
            override fun onFailure(reason: Int) {
                // No existing group — fine, proceed
                doCreateGroup(onResult)
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun doCreateGroup(onResult: (Boolean) -> Unit) {
        manager?.createGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Group creation initiated")
                onResult(true)
            }

            override fun onFailure(reason: Int) {
                Log.e(TAG, "Group creation failed: reason=$reason")
                onResult(false)
            }
        })
    }

    /**
     * Discover peers and connect to the Group Owner.
     * Called by the room joiner.
     */
    @SuppressLint("MissingPermission")
    fun discoverAndConnect(onResult: (Boolean) -> Unit) {
        manager?.discoverPeers(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Peer discovery initiated")
                // Wait briefly for peers, then request the list
                android.os.Handler(Looper.getMainLooper()).postDelayed({
                    requestPeersAndConnect(onResult)
                }, 3000)
            }

            override fun onFailure(reason: Int) {
                Log.e(TAG, "Peer discovery failed: reason=$reason")
                onResult(false)
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun requestPeersAndConnect(onResult: (Boolean) -> Unit) {
        manager?.requestPeers(channel) { peerList ->
            val peers = peerList?.deviceList?.toList() ?: emptyList()
            Log.d(TAG, "Found ${peers.size} peers")

            if (peers.isEmpty()) {
                Log.w(TAG, "No peers found")
                onResult(false)
                return@requestPeers
            }

            // Connect to the first available peer (the Group Owner)
            // In v2, we could filter by device name containing room code hash
            val device = peers.first()
            val config = WifiP2pConfig().apply {
                deviceAddress = device.deviceAddress
            }

            manager?.connect(channel, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    Log.d(TAG, "Connection initiated to ${device.deviceName}")
                    onResult(true)
                }

                override fun onFailure(reason: Int) {
                    Log.e(TAG, "Connection failed: reason=$reason")
                    onResult(false)
                }
            })
        }
    }

    /**
     * Wait for the connection to be fully established.
     * Returns true when connected, false on timeout.
     */
    suspend fun awaitConnection(timeoutMs: Long = 15000): Boolean {
        return withTimeoutOrNull(timeoutMs) {
            connectionReady.first { it }
            true
        } ?: false
    }

    /** Remove the Wi-Fi Direct group and disconnect */
    @SuppressLint("MissingPermission")
    fun removeGroup() {
        manager?.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Group removed")
            }

            override fun onFailure(reason: Int) {
                Log.e(TAG, "Failed to remove group: reason=$reason")
            }
        })
        connectionReady.value = false
        groupOwnerAddress = null
        isGroupOwner = false
    }

    /** Clean up all resources */
    fun cleanup() {
        removeGroup()
        if (isRegistered) {
            try {
                context.unregisterReceiver(receiver)
            } catch (e: Exception) {
                Log.w(TAG, "Receiver already unregistered")
            }
            isRegistered = false
        }
        receiver = null
        channel = null
        manager = null
    }
}
