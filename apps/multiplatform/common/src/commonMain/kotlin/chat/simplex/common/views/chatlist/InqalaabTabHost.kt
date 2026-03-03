package chat.simplex.common.views.chatlist

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import chat.simplex.common.model.ChatModel
import chat.simplex.common.views.helpers.*
import chat.simplex.common.views.safetyhub.SafetyHubView
import chat.simplex.common.views.usersettings.SettingsView
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * CompositionLocal providing the height of the bottom tab bar.
 * ChatListView reads this to add extra bottom padding in oneHandUI mode.
 */
val LocalTabBarHeight = staticCompositionLocalOf<Dp> { 0.dp }

@Composable
fun InqalaabTabHost(
    chatModel: ChatModel,
    userPickerState: MutableStateFlow<AnimatedViewState>,
    setPerformLA: (Boolean) -> Unit,
    stopped: Boolean
) {
    val selectedTab = remember { mutableStateOf(InqalaabTab.CHATS) }

    Box(Modifier.fillMaxSize()) {
        // Content area — switches based on selected tab
        CompositionLocalProvider(LocalTabBarHeight provides BOTTOM_TAB_BAR_HEIGHT) {
            when (selectedTab.value) {
                InqalaabTab.CHATS -> {
                    CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler()) {
                        ChatListView(chatModel, userPickerState, setPerformLA, stopped)
                    }
                }
                InqalaabTab.SAFETY_HUB -> {
                    CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler()) {
                        SafetyHubView(chatModel, setPerformLA)
                    }
                }
                InqalaabTab.SETTINGS -> {
                    CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler()) {
                        // Add bottom padding so scrollable content clears the tab bar
                        Box(Modifier.padding(bottom = BOTTOM_TAB_BAR_HEIGHT)) {
                            SettingsView(chatModel, setPerformLA, close = {
                                // When Settings requests close (e.g., during database update),
                                // switch back to Chats tab
                                selectedTab.value = InqalaabTab.CHATS
                            })
                        }
                    }
                }
            }
        }

        // Bottom tab bar — positioned at bottom, overlaps content
        // Content views add bottom padding via LocalTabBarHeight to avoid overlap
        Column(Modifier.align(Alignment.BottomCenter)) {
            InqalaabBottomTabBar(
                selectedTab = selectedTab.value,
                onTabSelected = { selectedTab.value = it }
            )
        }
    }
}
