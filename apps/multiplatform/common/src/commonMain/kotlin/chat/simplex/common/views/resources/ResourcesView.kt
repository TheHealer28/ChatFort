package chat.simplex.common.views.resources

import SectionBottomSpacer
import SectionDividerSpaced
import SectionItemView
import SectionView
import androidx.compose.foundation.layout.*
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.simplex.common.platform.ColumnWithScrollBar
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.chatlist.LocalTabBarHeight
import chat.simplex.common.views.helpers.*
import chat.simplex.common.views.usersettings.SettingsActionItem
import chat.simplex.res.MR
import dev.icerock.moko.resources.compose.painterResource

@Composable
fun ResourcesView() {
    val tabBarHeight = LocalTabBarHeight.current
    val uriHandler = LocalUriHandler.current

    ColumnWithScrollBar(
        Modifier.fillMaxSize().padding(bottom = tabBarHeight)
    ) {
        AppBarTitle("Resources")

        // Internet Shutdown Guide
        SectionView("DURING AN INTERNET SHUTDOWN") {
            ResourceCard(
                title = "1. Enable Nearby Mode",
                description = "Switch to the Nearby tab and turn on device discovery. Your phone uses Bluetooth and WiFi Direct — no internet needed."
            )
            ResourceCard(
                title = "2. Find People Around You",
                description = "Use 'Find People Nearby' to discover other Inqalaab users within range. Both devices must have the app open."
            )
            ResourceCard(
                title = "3. Create or Join a Room",
                description = "Start a group chat room with a code. Share the code verbally with people near you so they can join."
            )
            ResourceCard(
                title = "4. Relay Messages",
                description = "If someone needs to reach people outside your range, pass messages along through trusted contacts who can bridge the gap."
            )
        }
        SectionDividerSpaced()

        // Secure Communications
        SectionView("SECURE COMMUNICATIONS") {
            ResourceCard(
                title = "Use disappearing messages",
                description = "Enable auto-delete for sensitive conversations. Messages vanish after a set time on both devices."
            )
            ResourceCard(
                title = "Verify contacts in person",
                description = "Scan QR codes face-to-face when possible. This confirms you're talking to who you think you are."
            )
            ResourceCard(
                title = "Enable all Safety Hub features",
                description = "App lock, screen protection, and database encryption work together to keep your data safe if your device is seized."
            )
            ResourceCard(
                title = "Set up your panic code",
                description = "The self-destruct code wipes all data instantly. Memorize it — you may need it under pressure."
            )
        }
        SectionDividerSpaced()

        // Digital Rights Organizations
        SectionView("KNOW YOUR DIGITAL RIGHTS") {
            SettingsActionItem(
                painterResource(MR.images.ic_shield),
                "Electronic Frontier Foundation",
                click = { uriHandler.openUriCatching("https://ssd.eff.org/") },
                textColor = MaterialTheme.colors.primary
            )
            SettingsActionItem(
                painterResource(MR.images.ic_shield),
                "Frontline Defenders",
                click = { uriHandler.openUriCatching("https://www.frontlinedefenders.org/en/digital-security") },
                textColor = MaterialTheme.colors.primary
            )
            SettingsActionItem(
                painterResource(MR.images.ic_shield),
                "Privacy International",
                click = { uriHandler.openUriCatching("https://privacyinternational.org/") },
                textColor = MaterialTheme.colors.primary
            )
            SettingsActionItem(
                painterResource(MR.images.ic_shield),
                "Digital Rights Foundation",
                click = { uriHandler.openUriCatching("https://digitalrightsfoundation.pk/") },
                textColor = MaterialTheme.colors.primary
            )
        }
        SectionDividerSpaced()

        // Safety if detained
        SectionView("IF YOU ARE DETAINED") {
            ResourceCard(
                title = "Before it happens",
                description = "Set up your panic code now. Tell a trusted contact your self-destruct plan. Enable app lock with biometrics."
            )
            ResourceCard(
                title = "If you have a moment",
                description = "Trigger your panic code to wipe all data. The app will show an empty profile — nothing to find."
            )
            ResourceCard(
                title = "If your device is taken",
                description = "With screen protection enabled, no screenshots or screen recordings exist. Database encryption protects data at rest."
            )
            ResourceCard(
                title = "After release",
                description = "Reinstall Inqalaab and reconnect with trusted contacts via QR codes. Your previous data cannot be recovered — by design."
            )
        }
        SectionBottomSpacer()
    }
}

@Composable
private fun ResourceCard(title: String, description: String) {
    SectionItemView {
        Column {
            Text(
                title,
                style = MaterialTheme.typography.body1,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colors.onBackground
            )
            Spacer(Modifier.height(2.dp))
            Text(
                description,
                style = MaterialTheme.typography.body2,
                color = MaterialTheme.colors.secondary,
                fontSize = 13.sp
            )
        }
    }
}
