package chat.simplex.common.views.call

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import chat.simplex.common.platform.appPlatform
import chat.simplex.common.ui.theme.DEFAULT_PADDING

//
// Minimal group-call overlay (Phase 3 scaffold). Shows the incoming-call ring
// (Accept/Decline) and an active-call banner (roster + End). Audio-first; the
// full call screen + WebView hosting come later. Android-only for now.
//
// Reads GroupCallCoordinator's mutableStateOf properties directly, so it
// recomposes as call state changes.
//
@Composable
fun GroupCallOverlay() {
  if (!appPlatform.isAndroid) return
  val pending = GroupCallCoordinator.pendingIncomingCall
  val active = GroupCallCoordinator.activeGroupCall
  when {
    pending != null -> IncomingGroupCallDialog(pending)
    active != null -> ActiveGroupCallBanner(active)
  }
}

@Composable
private fun IncomingGroupCallDialog(pending: PendingGroupCall) {
  Box(
    Modifier.fillMaxSize().zIndex(110f).background(Color.Black.copy(alpha = 0.6f)),
    contentAlignment = Alignment.Center
  ) {
    Column(
      Modifier
        .padding(DEFAULT_PADDING)
        .clip(RoundedCornerShape(16.dp))
        .background(MaterialTheme.colors.surface)
        .padding(24.dp)
        .widthIn(max = 360.dp),
      horizontalAlignment = Alignment.CenterHorizontally
    ) {
      Text("Incoming group call", style = MaterialTheme.typography.h6, fontWeight = FontWeight.Bold)
      Spacer(Modifier.height(8.dp))
      Text(pending.groupName, style = MaterialTheme.typography.subtitle1, color = MaterialTheme.colors.primary)
      Spacer(Modifier.height(4.dp))
      Text("${pending.callerName} is calling", color = MaterialTheme.colors.secondary)
      Spacer(Modifier.height(24.dp))
      Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Button(
          onClick = { GroupCallCoordinator.declinePendingCall() },
          colors = ButtonDefaults.buttonColors(backgroundColor = MaterialTheme.colors.error)
        ) { Text("Decline", color = Color.White) }
        Button(onClick = { GroupCallCoordinator.acceptPendingCall() }) { Text("Accept") }
      }
    }
  }
}

@Composable
private fun ActiveGroupCallBanner(call: GroupCall) {
  Box(Modifier.fillMaxSize().zIndex(105f), contentAlignment = Alignment.TopCenter) {
    Column(
      Modifier
        .statusBarsPadding()
        .padding(horizontal = DEFAULT_PADDING, vertical = 8.dp)
        .clip(RoundedCornerShape(12.dp))
        .background(MaterialTheme.colors.primary)
        .padding(horizontal = 16.dp, vertical = 10.dp)
        .widthIn(max = 420.dp),
      horizontalAlignment = Alignment.CenterHorizontally
    ) {
      Text(call.groupName, color = Color.White, fontWeight = FontWeight.SemiBold)
      Text(
        "${call.connectedCount} of ${call.participants.size} connected",
        color = Color.White.copy(alpha = 0.85f),
        style = MaterialTheme.typography.caption
      )
      Spacer(Modifier.height(8.dp))
      Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = { GroupCallCoordinator.setMic(!GroupCallCoordinator.micEnabled) }) {
          Text(if (GroupCallCoordinator.micEnabled) "Mute" else "Unmute", color = Color.White)
        }
        Button(
          onClick = { GroupCallCoordinator.endGroupCall() },
          colors = ButtonDefaults.buttonColors(backgroundColor = MaterialTheme.colors.error)
        ) { Text("End", color = Color.White) }
      }
    }
  }
}
