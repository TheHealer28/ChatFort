package chat.simplex.common.views.chatlist

import androidx.compose.runtime.mutableStateOf

/** Set to switch the tab bar to a tab (e.g. when a crowd mesh notification is tapped). */
val requestedInqalaabTab = mutableStateOf<InqalaabTab?>(null)

enum class InqalaabTab {
    SAFETY_HUB,
    NEARBY,
    CHATS,
    RESOURCES,
    SETTINGS
}
