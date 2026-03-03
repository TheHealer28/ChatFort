package chat.simplex.app.nearby

import chat.simplex.common.platform.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.*
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer

/**
 * TCP message relay for Nearby Chat over Wi-Fi Direct.
 *
 * Group Owner mode: runs a TCP server that accepts client connections
 * and relays messages between all connected clients (star topology).
 *
 * Client mode: connects to the Group Owner's TCP server.
 *
 * Message framing: [4-byte big-endian length][payload]
 * Payload is already encrypted by NearbyCrypto before being passed here.
 */
class NearbyTcpRelay {

    companion object {
        const val PORT = 19847
        private const val TAG = "NearbyTcpRelay"
    }

    /** Callback for received messages (encrypted bytes) */
    var onMessageReceived: ((ByteArray) -> Unit)? = null

    /** Callback when a client disconnects (server mode only) */
    var onClientDisconnected: (() -> Unit)? = null

    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private val clients = mutableListOf<Socket>()
    private val clientsMutex = Mutex()
    private var scope: CoroutineScope? = null

    // --- Server mode (Group Owner) ---

    /** Start TCP server to accept client connections */
    fun startServer() {
        scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

        scope?.launch {
            try {
                serverSocket = ServerSocket(PORT)
                Log.d(TAG, "TCP server started on port $PORT")

                while (isActive) {
                    val socket = serverSocket?.accept() ?: break
                    Log.d(TAG, "Client connected: ${socket.inetAddress}")
                    clientsMutex.withLock { clients.add(socket) }

                    // Handle each client in its own coroutine
                    launch { handleClient(socket) }
                }
            } catch (e: Exception) {
                if (isActive) {
                    Log.e(TAG, "Server error: ${e.message}")
                }
            }
        }
    }

    /** Handle a single client connection (read messages and relay) */
    private suspend fun handleClient(socket: Socket) {
        try {
            val input = DataInputStream(BufferedInputStream(socket.getInputStream()))

            while (scope?.isActive == true && !socket.isClosed) {
                val length = input.readInt()
                if (length <= 0 || length > 65536) {
                    Log.w(TAG, "Invalid message length: $length")
                    break
                }

                val payload = ByteArray(length)
                input.readFully(payload)

                // Deliver to the server (GO) itself
                onMessageReceived?.invoke(payload)

                // Relay to all other clients
                relayToOthers(payload, socket)
            }
        } catch (e: EOFException) {
            Log.d(TAG, "Client disconnected (EOF)")
        } catch (e: Exception) {
            if (scope?.isActive == true) {
                Log.e(TAG, "Client handler error: ${e.message}")
            }
        } finally {
            clientsMutex.withLock { clients.remove(socket) }
            socket.safeClose()
            onClientDisconnected?.invoke()
        }
    }

    /** Relay a message to all connected clients except the sender */
    private suspend fun relayToOthers(payload: ByteArray, sender: Socket) {
        val frame = frameMessage(payload)
        clientsMutex.withLock {
            clients.filter { it !== sender && !it.isClosed }.forEach { client ->
                try {
                    val output = client.getOutputStream()
                    output.write(frame)
                    output.flush()
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to relay to client: ${e.message}")
                }
            }
        }
    }

    // --- Client mode (joiner) ---

    /** Connect to the Group Owner's TCP server */
    fun connectToServer(address: InetAddress) {
        scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

        scope?.launch {
            var retries = 0
            val maxRetries = 3

            while (retries < maxRetries && isActive) {
                try {
                    clientSocket = Socket(address, PORT)
                    Log.d(TAG, "Connected to server at $address:$PORT")

                    // Start reading messages
                    readFromServer(clientSocket!!)
                    break
                } catch (e: Exception) {
                    retries++
                    Log.w(TAG, "Connection attempt $retries failed: ${e.message}")
                    if (retries < maxRetries) {
                        delay(1000L * retries)  // exponential backoff
                    } else {
                        Log.e(TAG, "Failed to connect after $maxRetries attempts")
                    }
                }
            }
        }
    }

    /** Read messages from the server */
    private suspend fun readFromServer(socket: Socket) {
        try {
            val input = DataInputStream(BufferedInputStream(socket.getInputStream()))

            while (scope?.isActive == true && !socket.isClosed) {
                val length = input.readInt()
                if (length <= 0 || length > 65536) {
                    Log.w(TAG, "Invalid message length from server: $length")
                    break
                }

                val payload = ByteArray(length)
                input.readFully(payload)
                onMessageReceived?.invoke(payload)
            }
        } catch (e: EOFException) {
            Log.d(TAG, "Server disconnected (EOF)")
        } catch (e: Exception) {
            if (scope?.isActive == true) {
                Log.e(TAG, "Server read error: ${e.message}")
            }
        }
    }

    // --- Common operations ---

    /** Send an encrypted message (works in both server and client mode) */
    fun send(payload: ByteArray) {
        scope?.launch {
            val frame = frameMessage(payload)

            if (serverSocket != null) {
                // Server mode: send to ALL clients
                clientsMutex.withLock {
                    clients.filter { !it.isClosed }.forEach { client ->
                        try {
                            val output = client.getOutputStream()
                            output.write(frame)
                            output.flush()
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to send to client: ${e.message}")
                        }
                    }
                }
                // Also deliver to ourselves
                onMessageReceived?.invoke(payload)
            } else if (clientSocket != null && !clientSocket!!.isClosed) {
                // Client mode: send to server
                try {
                    val output = clientSocket!!.getOutputStream()
                    output.write(frame)
                    output.flush()
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to send to server: ${e.message}")
                }
            }
        }
    }

    /** Create a length-prefixed frame: [4-byte BE length][payload] */
    private fun frameMessage(payload: ByteArray): ByteArray {
        val buffer = ByteBuffer.allocate(4 + payload.size)
        buffer.putInt(payload.size)
        buffer.put(payload)
        return buffer.array()
    }

    /** Disconnect and clean up all resources */
    fun disconnect() {
        scope?.cancel()
        scope = null

        // Close all client sockets
        runBlocking {
            clientsMutex.withLock {
                clients.forEach { it.safeClose() }
                clients.clear()
            }
        }

        clientSocket?.safeClose()
        clientSocket = null

        serverSocket?.safeClose()
        serverSocket = null

        Log.d(TAG, "TCP relay disconnected")
    }

    private fun Socket.safeClose() {
        try { close() } catch (_: Exception) {}
    }

    private fun ServerSocket.safeClose() {
        try { close() } catch (_: Exception) {}
    }
}
