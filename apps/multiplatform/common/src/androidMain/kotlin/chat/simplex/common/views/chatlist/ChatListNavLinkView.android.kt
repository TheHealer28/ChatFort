package chat.simplex.common.views.chatlist

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Divider
import androidx.compose.material.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import chat.simplex.common.platform.onRightClick
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.helpers.*

/**
 * Inqalaab-specific chat list row layout.
 * Structural differences from upstream SimpleX:
 * - Rounded card style with subtle background
 * - Increased vertical padding for breathing room
 * - No divider between items (gap-based separation)
 * - Selected state uses rounded highlight
 */
@Composable
actual fun ChatListNavLinkLayout(
  chatLinkPreview: @Composable () -> Unit,
  click: () -> Unit,
  dropdownMenuItems: (@Composable () -> Unit)?,
  showMenu: MutableState<Boolean>,
  disabled: Boolean,
  selectedChat: State<Boolean>,
  nextChatSelected: State<Boolean>,
) {
  val isSelected = selectedChat.value
  var modifier = Modifier
    .fillMaxWidth()
    .padding(horizontal = 6.dp, vertical = 3.dp)
    .clip(RoundedCornerShape(12.dp))

  if (isSelected) {
    modifier = modifier.background(MaterialTheme.colors.primary.copy(alpha = 0.08f))
  }

  if (!disabled) modifier = modifier
    .combinedClickable(onClick = click, onLongClick = { showMenu.value = true })
    .onRightClick { showMenu.value = true }

  Box(modifier) {
    Row(
      modifier = Modifier
        .fillMaxWidth()
        .padding(start = 10.dp, top = 10.dp, end = 14.dp, bottom = 10.dp),
      verticalAlignment = Alignment.Top
    ) {
      chatLinkPreview()
    }
    if (dropdownMenuItems != null) {
      DefaultDropdownMenu(showMenu, dropdownMenuItems = dropdownMenuItems)
    }
  }
}
