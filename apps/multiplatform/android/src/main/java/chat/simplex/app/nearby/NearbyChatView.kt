package chat.simplex.app.nearby

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.icerock.moko.resources.compose.painterResource
import chat.simplex.common.ui.theme.*
import chat.simplex.res.MR
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*

/**
 * The actual nearby chat screen showing messages and a text input.
 * Displayed after successfully creating or joining a room.
 */
@Composable
fun NearbyChatView(onLeave: () -> Unit) {
    val room = NearbyUiState.currentRoom.value
    val messages = NearbyUiState.messages
    val peers = NearbyUiState.peers
    val connectionState = NearbyUiState.connectionState.value

    var inputText by remember { mutableStateOf("") }
    val listState = rememberLazyListState()
    val coroutineScope = rememberCoroutineScope()

    // Auto-scroll to bottom on new messages
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.size - 1)
        }
    }

    // Handle disconnection
    LaunchedEffect(connectionState) {
        if (connectionState != NearbyConnectionState.CONNECTED) {
            // Room was closed or we got disconnected
        }
    }

    Column(Modifier.fillMaxSize().navigationBarsPadding().imePadding()) {
        // Top bar
        Surface(
            Modifier.fillMaxWidth().statusBarsPadding(),
            elevation = 4.dp,
            color = MaterialTheme.colors.background
        ) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        "Nearby Chat",
                        style = MaterialTheme.typography.h3,
                        fontWeight = FontWeight.Bold
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (room != null) {
                            Text(
                                "Room: ${room.code}",
                                style = MaterialTheme.typography.body2,
                                color = MaterialTheme.colors.secondary
                            )
                            Text(
                                "  •  ${peers.size + 1} members",
                                style = MaterialTheme.typography.body2,
                                color = MaterialTheme.colors.secondary
                            )
                        }
                    }
                }

                TextButton(
                    onClick = {
                        NearbyManager.leaveRoom()
                        onLeave()
                    }
                ) {
                    Text(
                        "Leave",
                        color = MaterialTheme.colors.error,
                        fontWeight = FontWeight.Bold
                    )
                }
            }
        }

        // Message list
        LazyColumn(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = 8.dp),
            state = listState,
            contentPadding = PaddingValues(vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            items(messages.toList()) { message ->
                if (message.isSystem) {
                    SystemMessageBubble(message)
                } else if (message.isMine) {
                    SentMessageBubble(message)
                } else {
                    ReceivedMessageBubble(message)
                }
            }
        }

        // Input bar
        Surface(
            Modifier.fillMaxWidth(),
            elevation = 8.dp,
            color = MaterialTheme.colors.background
        ) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OutlinedTextField(
                    value = inputText,
                    onValueChange = { inputText = it },
                    placeholder = { Text("Type a message") },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(24.dp),
                    singleLine = false,
                    maxLines = 4
                )

                Spacer(Modifier.width(8.dp))

                IconButton(
                    onClick = {
                        if (inputText.isNotBlank()) {
                            NearbyManager.sendMessage(inputText.trim())
                            inputText = ""
                        }
                    },
                    enabled = inputText.isNotBlank()
                ) {
                    Icon(
                        painterResource(MR.images.ic_arrow_upward),
                        contentDescription = "Send",
                        tint = if (inputText.isNotBlank()) MaterialTheme.colors.primary
                        else MaterialTheme.colors.secondary.copy(alpha = 0.5f)
                    )
                }
            }
        }
    }
}

@Composable
private fun SentMessageBubble(message: NearbyMessage) {
    Column(
        Modifier.fillMaxWidth().padding(start = 48.dp),
        horizontalAlignment = Alignment.End
    ) {
        Box(
            Modifier
                .clip(RoundedCornerShape(16.dp, 16.dp, 4.dp, 16.dp))
                .background(MaterialTheme.colors.primary.copy(alpha = 0.15f))
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            Text(
                message.text,
                style = MaterialTheme.typography.body1,
                color = MaterialTheme.colors.onBackground
            )
        }
        Text(
            formatTime(message.timestamp),
            style = MaterialTheme.typography.caption,
            color = MaterialTheme.colors.secondary.copy(alpha = 0.6f),
            modifier = Modifier.padding(top = 2.dp, end = 4.dp)
        )
    }
}

@Composable
private fun ReceivedMessageBubble(message: NearbyMessage) {
    Column(
        Modifier.fillMaxWidth().padding(end = 48.dp),
        horizontalAlignment = Alignment.Start
    ) {
        Text(
            message.senderName,
            style = MaterialTheme.typography.caption,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colors.primary,
            modifier = Modifier.padding(start = 12.dp, bottom = 2.dp)
        )
        Box(
            Modifier
                .clip(RoundedCornerShape(16.dp, 16.dp, 16.dp, 4.dp))
                .background(MaterialTheme.colors.surface)
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            Text(
                message.text,
                style = MaterialTheme.typography.body1,
                color = MaterialTheme.colors.onSurface
            )
        }
        Text(
            formatTime(message.timestamp),
            style = MaterialTheme.typography.caption,
            color = MaterialTheme.colors.secondary.copy(alpha = 0.6f),
            modifier = Modifier.padding(top = 2.dp, start = 12.dp)
        )
    }
}

@Composable
private fun SystemMessageBubble(message: NearbyMessage) {
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Text(
            message.text,
            style = MaterialTheme.typography.caption,
            fontStyle = FontStyle.Italic,
            color = MaterialTheme.colors.secondary.copy(alpha = 0.7f),
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(vertical = 4.dp)
        )
    }
}

private fun formatTime(timestamp: Long): String {
    val sdf = SimpleDateFormat("HH:mm", Locale.getDefault())
    return sdf.format(Date(timestamp))
}
