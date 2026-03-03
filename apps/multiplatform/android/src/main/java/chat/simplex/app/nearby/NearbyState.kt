package chat.simplex.app.nearby

import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import javax.crypto.spec.SecretKeySpec

/** Connection state machine for Nearby Chat */
enum class NearbyConnectionState {
    IDLE,
    CREATING_ROOM,
    JOINING_ROOM,
    CONNECTED,
    ERROR
}

/** A nearby chat room */
data class NearbyRoom(
    val code: String,
    val displayName: String,
    val isOwner: Boolean,
    val derivedKey: SecretKeySpec
)

/** A single chat message */
data class NearbyMessage(
    val senderName: String,
    val text: String,
    val timestamp: Long,
    val isMine: Boolean,
    val isSystem: Boolean = false
)

/** A connected peer */
data class NearbyPeer(
    val name: String,
    val joinedAt: Long
)

/** A person discovered via BLE people discovery */
data class DiscoveredPerson(
    val name: String,
    val identityHash: ByteArray,
    val lastSeen: Long
) {
    override fun equals(other: Any?): Boolean =
        other is DiscoveredPerson && identityHash.contentEquals(other.identityHash)
    override fun hashCode(): Int = identityHash.contentHashCode()
}

/**
 * Observable UI state for Nearby Chat.
 * All fields are Compose-observable so the UI recomposes automatically.
 */
object NearbyUiState {
    val connectionState = mutableStateOf(NearbyConnectionState.IDLE)
    val currentRoom = mutableStateOf<NearbyRoom?>(null)
    val messages = mutableStateListOf<NearbyMessage>()
    val peers = mutableStateListOf<NearbyPeer>()
    val errorMessage = mutableStateOf<String?>(null)

    // People discovery state
    val discoveryActive = mutableStateOf(false)
    val discoveredPeople = mutableStateListOf<DiscoveredPerson>()
    val incomingRequest = mutableStateOf<DiscoveredPerson?>(null)
    val outgoingRequest = mutableStateOf<DiscoveredPerson?>(null)

    fun reset() {
        connectionState.value = NearbyConnectionState.IDLE
        currentRoom.value = null
        messages.clear()
        peers.clear()
        errorMessage.value = null
        discoveryActive.value = false
        discoveredPeople.clear()
        incomingRequest.value = null
        outgoingRequest.value = null
    }
}
