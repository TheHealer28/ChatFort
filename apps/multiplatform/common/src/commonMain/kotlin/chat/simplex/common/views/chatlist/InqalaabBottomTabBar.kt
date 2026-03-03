package chat.simplex.common.views.chatlist

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.simplex.common.model.ChatController.appPrefs
import chat.simplex.common.views.helpers.mixWith
import chat.simplex.res.MR
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource

val BOTTOM_TAB_BAR_HEIGHT = 56.dp

@Composable
fun InqalaabBottomTabBar(
    selectedTab: InqalaabTab,
    onTabSelected: (InqalaabTab) -> Unit
) {
    val barAlpha = remember { appPrefs.inAppBarsAlpha.state }
    val bgColor = MaterialTheme.colors.background.mixWith(
        MaterialTheme.colors.onBackground, 0.97f
    ).copy(alpha = barAlpha.value)

    Column(Modifier.background(bgColor).navigationBarsPadding()) {
        Divider(color = MaterialTheme.colors.onBackground.copy(alpha = 0.12f))
        BottomNavigation(
            backgroundColor = bgColor,
            elevation = 0.dp
        ) {
            BottomNavigationItem(
                selected = selectedTab == InqalaabTab.CHATS,
                onClick = { onTabSelected(InqalaabTab.CHATS) },
                icon = { Icon(painterResource(MR.images.ic_chat_bubble), contentDescription = "Chats") },
                label = { Text("Chats", fontSize = 11.sp) },
                selectedContentColor = MaterialTheme.colors.primary,
                unselectedContentColor = MaterialTheme.colors.secondary
            )
            BottomNavigationItem(
                selected = selectedTab == InqalaabTab.SAFETY_HUB,
                onClick = { onTabSelected(InqalaabTab.SAFETY_HUB) },
                icon = { Icon(painterResource(MR.images.ic_shield), contentDescription = "Safety") },
                label = { Text("Safety Hub", fontSize = 11.sp) },
                selectedContentColor = MaterialTheme.colors.primary,
                unselectedContentColor = MaterialTheme.colors.secondary
            )
            BottomNavigationItem(
                selected = selectedTab == InqalaabTab.SETTINGS,
                onClick = { onTabSelected(InqalaabTab.SETTINGS) },
                icon = { Icon(painterResource(MR.images.ic_settings), contentDescription = "Settings") },
                label = { Text("Settings", fontSize = 11.sp) },
                selectedContentColor = MaterialTheme.colors.primary,
                unselectedContentColor = MaterialTheme.colors.secondary
            )
        }
    }
}
