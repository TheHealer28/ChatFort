package chat.simplex.common.views.chatlist

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import chat.simplex.common.model.ChatModel
import chat.simplex.common.platform.appPlatform
import chat.simplex.common.views.helpers.*
import chat.simplex.common.views.resources.ResourcesView
import chat.simplex.common.views.safetyhub.SafetyHubView
import chat.simplex.common.views.usersettings.SettingsView
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * CompositionLocal providing the height of the bottom tab bar (including system nav bar inset).
 * All tab content views read this to add extra bottom padding so content
 * doesn't get hidden behind the tab bar.
 */
val LocalTabBarHeight = staticCompositionLocalOf<Dp> { 0.dp }

// 56dp for the tab bar itself + ~48dp typical system nav bar.
// The actual system nav bar padding is handled by navigationBarsPadding() in InqalaabBottomTabBar.
// This constant just needs to be large enough to prevent content from hiding behind the tab bar.
private val TOTAL_TAB_BAR_HEIGHT = 110.dp

@Composable
fun InqalaabTabHost(
    chatModel: ChatModel,
    userPickerState: MutableStateFlow<AnimatedViewState>,
    setPerformLA: (Boolean) -> Unit,
    stopped: Boolean
) {
    // Safety Hub is the default landing screen
    val selectedTab = remember { mutableStateOf(InqalaabTab.SAFETY_HUB) }

    Box(Modifier.fillMaxSize()) {
        // Content area — switches based on selected tab
        CompositionLocalProvider(LocalTabBarHeight provides TOTAL_TAB_BAR_HEIGHT) {
            when (selectedTab.value) {
                InqalaabTab.SAFETY_HUB -> {
                    CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler()) {
                        SafetyHubView(chatModel, setPerformLA)
                    }
                }
                InqalaabTab.NEARBY -> {
                    val nearbyContent = LocalNearbyContent.current
                    if (nearbyContent != null && appPlatform.isAndroid) {
                        nearbyContent { /* no-op: tab stays visible */ }
                    }
                }
                InqalaabTab.CHATS -> {
                    CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler()) {
                        ChatListView(chatModel, userPickerState, setPerformLA, stopped)
                    }
                }
                InqalaabTab.RESOURCES -> {
                    CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler()) {
                        ResourcesView()
                    }
                }
                InqalaabTab.SETTINGS -> {
                    CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler()) {
                        Box(Modifier.padding(bottom = TOTAL_TAB_BAR_HEIGHT)) {
                            SettingsView(chatModel, setPerformLA, close = {
                                selectedTab.value = InqalaabTab.SAFETY_HUB
                            })
                        }
                    }
                }
            }
        }

        // Bottom tab bar — positioned at bottom
        // navigationBarsPadding() inside InqalaabBottomTabBar pushes it above system nav buttons
        Column(Modifier.align(Alignment.BottomCenter)) {
            InqalaabBottomTabBar(
                selectedTab = selectedTab.value,
                onTabSelected = { selectedTab.value = it }
            )
        }
    }
}
