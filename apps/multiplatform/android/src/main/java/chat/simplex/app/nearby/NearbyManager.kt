package chat.simplex.app.nearby

import android.content.Context
import chat.simplex.common.model.ChatModel
import chat.simplex.common.platform.Log
import kotlinx.coroutines.*
import org.json.JSONObject

/**
 * Central orchestrator for Nearby Chat.
 * Coordinates BLE discovery, Wi-Fi Direct connections, TCP messaging, and encryption.
 *
 * Usage:
 *   NearbyManager.init(context)
 *   val code = NearbyManager.createRoom("Ali")   // room creator
 *   NearbyManager.joinRoom("ABC123", "Sara")      // room joiner
 *   NearbyManager.sendMessage("Hello!")
 *   NearbyManager.leaveRoom()
 */
object NearbyManager {

    private const val TAG = "NearbyManager"
    private const val CODE_LENGTH = 6
    // Unambiguous alphanumeric characters (no 0/O, 1/I, 5/S)
    private const val CODE_CHARS = "ABCDEFGHJKLMNPQRTUVWXY2346789"

    private var context: Context? = null
    private var bleAdvertiser: NearbyBleAdvertiser? = null
    private var bleScanner: NearbyBleScanner? = null
    private var wifiDirect: NearbyWifiDirect? = null
    private var tcpRelay: NearbyTcpRelay? = null
    private var scope: CoroutineScope? = null
    private var peopleDiscovery: NearbyPeopleDiscovery? = null

    /** Initialize with application context. Call once from SimplexApp or MainActivity. */
    fun init(ctx: Context) {
        context = ctx.applicationContext
    }

    /**
     * Create a new nearby chat room.
     * This device becomes the Group Owner and TCP server.
     * @return the 6-character room code to share with others
     */
    fun createRoom(displayName: String, onResult: (String?) -> Unit) {
        val ctx = context ?: run {
            Log.e(TAG, "NearbyManager not initialized")
            onResult(null)
            return
        }

        scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
        NearbyUiState.reset()
        NearbyUiState.connectionState.value = NearbyConnectionState.CREATING_ROOM

        val code = generateRoomCode()
        val key = NearbyCrypto.deriveKey(code)
        val hash = NearbyCrypto.hashRoomCode(code)

        val room = NearbyRoom(code = code, displayName = displayName, isOwner = true, derivedKey = key)
        NearbyUiState.currentRoom.value = room

        // Start BLE advertising
        bleAdvertiser = NearbyBleAdvertiser(ctx).also {
            it.startAdvertising(hash)
        }

        // Start Wi-Fi Direct group
        wifiDirect = NearbyWifiDirect(ctx).also { wd ->
            wd.initialize()
            wd.createGroup { success ->
                if (success) {
                    // Start TCP server
                    tcpRelay = NearbyTcpRelay().also { relay ->
                        relay.onMessageReceived = { encrypted -> handleReceivedMessage(encrypted, room) }
                        relay.startServer()
                    }

                    NearbyUiState.connectionState.value = NearbyConnectionState.CONNECTED
                    addSystemMessage("Room created. Share code: $code")
                    onResult(code)
                } else {
                    NearbyUiState.connectionState.value = NearbyConnectionState.ERROR
                    NearbyUiState.errorMessage.value = "Failed to create Wi-Fi Direct group"
                    onResult(null)
                }
            }
        }
    }

    /**
     * Join an existing nearby chat room using the room code.
     */
    fun joinRoom(code: String, displayName: String, onResult: (Boolean) -> Unit) {
        val ctx = context ?: run {
            Log.e(TAG, "NearbyManager not initialized")
            onResult(false)
            return
        }

        scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
        NearbyUiState.reset()
        NearbyUiState.connectionState.value = NearbyConnectionState.JOINING_ROOM

        val normalizedCode = code.uppercase().trim()
        val key = NearbyCrypto.deriveKey(normalizedCode)

        val room = NearbyRoom(code = normalizedCode, displayName = displayName, isOwner = false, derivedKey = key)
        NearbyUiState.currentRoom.value = room

        // Optionally verify room exists via BLE (non-blocking, 3s timeout)
        bleScanner = NearbyBleScanner(ctx).also { it.startScanning() }

        // Start Wi-Fi Direct and discover the Group Owner
        wifiDirect = NearbyWifiDirect(ctx).also { wd ->
            wd.initialize()
            wd.discoverAndConnect { success ->
                if (success) {
                    // Wait for connection to be fully established
                    scope?.launch {
                        val connected = wd.awaitConnection(15000)
                        if (connected && wd.groupOwnerAddress != null) {
                            // Connect TCP client to GO
                            tcpRelay = NearbyTcpRelay().also { relay ->
                                relay.onMessageReceived = { encrypted -> handleReceivedMessage(encrypted, room) }
                                relay.connectToServer(wd.groupOwnerAddress!!)
                            }

                            // Brief delay for TCP connection to establish
                            delay(1000)

                            // Send join announcement
                            val joinMsg = JSONObject().apply {
                                put("type", "join")
                                put("name", displayName)
                                put("timestamp", System.currentTimeMillis())
                            }
                            val encrypted = NearbyCrypto.encrypt(joinMsg.toString().toByteArray(Charsets.UTF_8), key)
                            tcpRelay?.send(encrypted)

                            withContext(Dispatchers.Main) {
                                NearbyUiState.connectionState.value = NearbyConnectionState.CONNECTED
                                addSystemMessage("Joined the room")
                            }
                            onResult(true)
                        } else {
                            withContext(Dispatchers.Main) {
                                NearbyUiState.connectionState.value = NearbyConnectionState.ERROR
                                NearbyUiState.errorMessage.value = "Could not connect to room"
                            }
                            onResult(false)
                        }
                    }
                } else {
                    NearbyUiState.connectionState.value = NearbyConnectionState.ERROR
                    NearbyUiState.errorMessage.value = "No nearby rooms found"
                    onResult(false)
                }
            }
        }
    }

    /** Send a text message to the room */
    fun sendMessage(text: String) {
        val room = NearbyUiState.currentRoom.value ?: return
        if (text.isBlank()) return

        val msgJson = JSONObject().apply {
            put("type", "msg")
            put("name", room.displayName)
            put("text", text)
            put("timestamp", System.currentTimeMillis())
        }

        val encrypted = NearbyCrypto.encrypt(
            msgJson.toString().toByteArray(Charsets.UTF_8),
            room.derivedKey
        )

        // If we're the server (GO), the relay's send() handles self-delivery
        // If we're a client, the server relays back to us (but we add locally for responsiveness)
        if (!room.isOwner) {
            NearbyUiState.messages.add(
                NearbyMessage(
                    senderName = room.displayName,
                    text = text,
                    timestamp = System.currentTimeMillis(),
                    isMine = true
                )
            )
        }

        tcpRelay?.send(encrypted)
    }

    /** Leave the room and clean up all resources */
    fun leaveRoom() {
        val room = NearbyUiState.currentRoom.value
        if (room != null) {
            // Send leave announcement
            val leaveMsg = JSONObject().apply {
                put("type", "leave")
                put("name", room.displayName)
                put("timestamp", System.currentTimeMillis())
            }
            try {
                val encrypted = NearbyCrypto.encrypt(
                    leaveMsg.toString().toByteArray(Charsets.UTF_8),
                    room.derivedKey
                )
                tcpRelay?.send(encrypted)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to send leave message: ${e.message}")
            }
        }

        // Tear down everything
        bleAdvertiser?.stopAdvertising()
        bleAdvertiser = null

        bleScanner?.stopScanning()
        bleScanner = null

        tcpRelay?.disconnect()
        tcpRelay = null

        wifiDirect?.cleanup()
        wifiDirect = null

        scope?.cancel()
        scope = null

        NearbyUiState.reset()
        Log.d(TAG, "Left room and cleaned up")
    }

    // ========== People Discovery (1-on-1) ==========

    /** Start BLE people discovery — advertise our name and scan for others */
    fun startPeopleDiscovery() {
        val ctx = context ?: return
        val displayName = ChatModel.currentUser.value?.displayName ?: "User"

        NearbyUiState.discoveryActive.value = true
        NearbyUiState.discoveredPeople.clear()
        NearbyUiState.incomingRequest.value = null
        NearbyUiState.outgoingRequest.value = null

        peopleDiscovery = NearbyPeopleDiscovery(ctx).also { pd ->
            pd.onPersonDiscovered = { person ->
                val idx = NearbyUiState.discoveredPeople.indexOfFirst {
                    it.identityHash.contentEquals(person.identityHash)
                }
                if (idx >= 0) {
                    NearbyUiState.discoveredPeople[idx] = person
                } else {
                    NearbyUiState.discoveredPeople.add(person)
                }
            }
            pd.onConnectionRequested = { person ->
                NearbyUiState.incomingRequest.value = person
            }
            pd.onConnectionAccepted = { person ->
                // They accepted — I'm the initiator, so I create the Wi-Fi Direct group
                NearbyUiState.outgoingRequest.value = null
                initiateDirectChat(displayName, person)
            }
            pd.startDiscovery(displayName)
        }
    }

    /** Stop people discovery and return to main menu */
    fun stopPeopleDiscovery() {
        peopleDiscovery?.stopDiscovery()
        peopleDiscovery = null
        NearbyUiState.discoveryActive.value = false
        NearbyUiState.discoveredPeople.clear()
        NearbyUiState.incomingRequest.value = null
        NearbyUiState.outgoingRequest.value = null
    }

    /** Send a connection request to a discovered person */
    fun requestDirectConnection(target: DiscoveredPerson) {
        NearbyUiState.outgoingRequest.value = target
        peopleDiscovery?.requestConnection(target)
    }

    /** Cancel an outgoing connection request */
    fun cancelDirectRequest() {
        NearbyUiState.outgoingRequest.value = null
        // Re-advertise as available
        val displayName = ChatModel.currentUser.value?.displayName ?: "User"
        peopleDiscovery?.stopDiscovery()
        peopleDiscovery?.startDiscovery(displayName)
    }

    /** Accept an incoming connection request — other party will create the group */
    fun acceptDirectConnection(requester: DiscoveredPerson) {
        val ctx = context ?: return
        val displayName = ChatModel.currentUser.value?.displayName ?: "User"

        NearbyUiState.incomingRequest.value = null
        peopleDiscovery?.acceptConnection(requester)

        // Derive a shared key from both identity hashes (sorted for consistency)
        val myHash = NearbyPeopleDiscovery.identityHash(displayName).toHex()
        val theirHash = requester.identityHash.toHex()
        val combined = if (myHash < theirHash) myHash + theirHash else theirHash + myHash
        val key = NearbyCrypto.deriveKey(combined)

        val room = NearbyRoom(code = "DM", displayName = displayName, isOwner = false, derivedKey = key)
        NearbyUiState.currentRoom.value = room
        NearbyUiState.connectionState.value = NearbyConnectionState.JOINING_ROOM

        // Stop BLE, then discover and connect Wi-Fi Direct
        scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
        scope?.launch {
            delay(2000)  // Give the requester time to set up Wi-Fi Direct group
            withContext(Dispatchers.Main) {
                peopleDiscovery?.stopDiscovery()
                peopleDiscovery = null
                NearbyUiState.discoveryActive.value = false
            }

            wifiDirect = NearbyWifiDirect(ctx).also { wd ->
                withContext(Dispatchers.Main) { wd.initialize() }
                withContext(Dispatchers.Main) {
                    wd.discoverAndConnect { success ->
                        if (success) {
                            scope?.launch {
                                val connected = wd.awaitConnection(15000)
                                if (connected && wd.groupOwnerAddress != null) {
                                    tcpRelay = NearbyTcpRelay().also { relay ->
                                        relay.onMessageReceived = { encrypted -> handleReceivedMessage(encrypted, room) }
                                        relay.connectToServer(wd.groupOwnerAddress!!)
                                    }
                                    delay(1000)
                                    val joinMsg = JSONObject().apply {
                                        put("type", "join")
                                        put("name", displayName)
                                        put("timestamp", System.currentTimeMillis())
                                    }
                                    val encrypted = NearbyCrypto.encrypt(joinMsg.toString().toByteArray(Charsets.UTF_8), key)
                                    tcpRelay?.send(encrypted)
                                    withContext(Dispatchers.Main) {
                                        NearbyUiState.connectionState.value = NearbyConnectionState.CONNECTED
                                        addSystemMessage("Connected with ${requester.name}")
                                    }
                                } else {
                                    withContext(Dispatchers.Main) {
                                        NearbyUiState.connectionState.value = NearbyConnectionState.ERROR
                                        NearbyUiState.errorMessage.value = "Could not connect"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /** Called when the other party accepts — the initiator creates Wi-Fi Direct group */
    private fun initiateDirectChat(displayName: String, target: DiscoveredPerson) {
        val ctx = context ?: return

        val myHash = NearbyPeopleDiscovery.identityHash(displayName).toHex()
        val theirHash = target.identityHash.toHex()
        val combined = if (myHash < theirHash) myHash + theirHash else theirHash + myHash
        val key = NearbyCrypto.deriveKey(combined)

        val room = NearbyRoom(code = "DM", displayName = displayName, isOwner = true, derivedKey = key)
        NearbyUiState.currentRoom.value = room
        NearbyUiState.connectionState.value = NearbyConnectionState.CREATING_ROOM

        // Stop BLE discovery
        peopleDiscovery?.stopDiscovery()
        peopleDiscovery = null
        NearbyUiState.discoveryActive.value = false

        scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

        wifiDirect = NearbyWifiDirect(ctx).also { wd ->
            wd.initialize()
            wd.createGroup { success ->
                if (success) {
                    tcpRelay = NearbyTcpRelay().also { relay ->
                        relay.onMessageReceived = { encrypted -> handleReceivedMessage(encrypted, room) }
                        relay.startServer()
                    }
                    NearbyUiState.connectionState.value = NearbyConnectionState.CONNECTED
                    addSystemMessage("Connected with ${target.name}")
                } else {
                    NearbyUiState.connectionState.value = NearbyConnectionState.ERROR
                    NearbyUiState.errorMessage.value = "Connection failed"
                }
            }
        }
    }

    /** Clean up on app lifecycle (Activity pause/destroy) */
    fun cleanup() {
        stopPeopleDiscovery()
        leaveRoom()
    }

    // --- Internal message handling ---

    private fun handleReceivedMessage(encrypted: ByteArray, room: NearbyRoom) {
        try {
            val decrypted = NearbyCrypto.decrypt(encrypted, room.derivedKey)
            val json = JSONObject(String(decrypted, Charsets.UTF_8))
            val type = json.getString("type")
            val name = json.getString("name")
            val timestamp = json.getLong("timestamp")

            // Skip our own messages if we're the server (GO already self-delivered in send())
            if (name == room.displayName && room.isOwner) return

            when (type) {
                "join" -> {
                    NearbyUiState.peers.add(NearbyPeer(name, timestamp))
                    addSystemMessage("$name joined")
                }
                "msg" -> {
                    val text = json.getString("text")
                    NearbyUiState.messages.add(
                        NearbyMessage(
                            senderName = name,
                            text = text,
                            timestamp = timestamp,
                            isMine = (name == room.displayName)
                        )
                    )
                }
                "leave" -> {
                    NearbyUiState.peers.removeAll { it.name == name }
                    addSystemMessage("$name left")
                }
                else -> Log.w(TAG, "Unknown message type: $type")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to process message: ${e.message}")
        }
    }

    private fun addSystemMessage(text: String) {
        NearbyUiState.messages.add(
            NearbyMessage(
                senderName = "",
                text = text,
                timestamp = System.currentTimeMillis(),
                isMine = false,
                isSystem = true
            )
        )
    }

    private fun generateRoomCode(): String {
        val random = java.security.SecureRandom()
        return (1..CODE_LENGTH)
            .map { CODE_CHARS[random.nextInt(CODE_CHARS.length)] }
            .joinToString("")
    }
}
