package chat.simplex.common.views.onboarding

import SectionBottomSpacer
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
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.simplex.common.model.ChatController.appPrefs
import chat.simplex.common.platform.ColumnWithScrollBarNoAppBar
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.helpers.*
import chat.simplex.res.MR
import dev.icerock.moko.resources.compose.painterResource

// Screen 1: Why Inqalaab Exists
@Composable
fun InqalaabMissionScreen() {
    ColumnWithScrollBarNoAppBar(
        Modifier.fillMaxSize().padding(horizontal = DEFAULT_PADDING)
    ) {
        Spacer(Modifier.height(40.dp))

        Icon(
            painterResource(MR.images.ic_flag_filled),
            contentDescription = null,
            modifier = Modifier.size(72.dp).align(Alignment.CenterHorizontally),
            tint = MaterialTheme.colors.primary
        )

        Spacer(Modifier.height(24.dp))

        Text(
            "Why Inqalaab Exists",
            style = MaterialTheme.typography.h4.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colors.onBackground,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(8.dp))

        Text(
            "Built for people who face real danger",
            style = MaterialTheme.typography.body1,
            color = MaterialTheme.colors.secondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(32.dp))

        ValueCard(
            painterResource(MR.images.ic_warning_filled),
            "Internet shutdowns are rising",
            "Governments cut access during protests, elections, and crises. You need a way to communicate when they do."
        )
        Spacer(Modifier.height(12.dp))

        ValueCard(
            painterResource(MR.images.ic_shield),
            "Activists face surveillance",
            "Standard messaging apps leak metadata — who you talk to, when, and how often. Inqalaab protects all of that."
        )
        Spacer(Modifier.height(12.dp))

        ValueCard(
            painterResource(MR.images.ic_wifi_tethering),
            "Offline-first communication",
            "Nearby Chat uses Bluetooth and WiFi Direct — no internet, no cell towers, no way to block it."
        )
        Spacer(Modifier.height(12.dp))

        ValueCard(
            painterResource(MR.images.ic_lock),
            "No identity required",
            "No phone number, no email, no account. You are invisible by default."
        )

        Spacer(Modifier.weight(1f))

        OnboardingActionButton(
            modifier = Modifier.padding(bottom = 8.dp).fillMaxWidth(),
            labelId = MR.strings.setup_protection_continue,
            onboarding = OnboardingStage.Step0_5_SecurityPledgeScreen,
            onclick = null
        )

        SectionBottomSpacer()
    }
}

// Screen 2: Security Pledge / Threat Model
@Composable
fun InqalaabSecurityPledgeScreen() {
    ColumnWithScrollBarNoAppBar(
        Modifier.fillMaxSize().padding(horizontal = DEFAULT_PADDING)
    ) {
        Spacer(Modifier.height(40.dp))

        Icon(
            painterResource(MR.images.ic_shield),
            contentDescription = null,
            modifier = Modifier.size(72.dp).align(Alignment.CenterHorizontally),
            tint = SimplexGreen
        )

        Spacer(Modifier.height(24.dp))

        Text(
            "Your Security Pledge",
            style = MaterialTheme.typography.h4.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colors.onBackground,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(8.dp))

        Text(
            "We make these promises to you:",
            style = MaterialTheme.typography.body1,
            color = MaterialTheme.colors.secondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(32.dp))

        PledgeItem(1, "Zero data collection", "We collect nothing. No analytics, no telemetry, no usage data. Ever.")
        Spacer(Modifier.height(12.dp))

        PledgeItem(2, "No phone number required", "Your identity stays hidden. Connect via QR codes and links only.")
        Spacer(Modifier.height(12.dp))

        PledgeItem(3, "Panic mode for emergencies", "Wipe all data instantly if you're ever in danger.")
        Spacer(Modifier.height(12.dp))

        PledgeItem(4, "Community-run servers", "Your messages route through independent servers that no government controls.")
        Spacer(Modifier.height(12.dp))

        PledgeItem(5, "Open source & auditable", "Our code is public. Anyone can verify we keep these promises.")

        Spacer(Modifier.weight(1f))

        OnboardingActionButton(
            modifier = Modifier.padding(bottom = 8.dp).fillMaxWidth(),
            labelId = MR.strings.setup_protection_continue,
            onboarding = OnboardingStage.Step0_2_EnableSafety,
            onclick = null
        )

        SectionBottomSpacer()
    }
}

// Screen 3: Enable Safety Features
@Composable
fun InqalaabEnableSafetyScreen() {
    val screenProtection = remember { appPrefs.privacyProtectScreen.state }
    val localFilesEncrypted = remember { appPrefs.privacyEncryptLocalFiles.state }

    ColumnWithScrollBarNoAppBar(
        Modifier.fillMaxSize().padding(horizontal = DEFAULT_PADDING)
    ) {
        Spacer(Modifier.height(40.dp))

        Icon(
            painterResource(MR.images.ic_security),
            contentDescription = null,
            modifier = Modifier.size(72.dp).align(Alignment.CenterHorizontally),
            tint = MaterialTheme.colors.primary
        )

        Spacer(Modifier.height(24.dp))

        Text(
            "Enable Safety Features",
            style = MaterialTheme.typography.h4.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colors.onBackground,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(8.dp))

        Text(
            "These protect you if your device is seized or inspected",
            style = MaterialTheme.typography.body1,
            color = MaterialTheme.colors.secondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(32.dp))

        // Screen Protection toggle
        SafetyToggleCard(
            icon = painterResource(MR.images.ic_visibility_off),
            title = "Screen Protection",
            description = "Block screenshots and screen recording. Nothing gets captured.",
            checked = screenProtection.value,
            onCheckedChange = { appPrefs.privacyProtectScreen.set(it) }
        )
        Spacer(Modifier.height(12.dp))

        // Encrypt local files toggle
        SafetyToggleCard(
            icon = painterResource(MR.images.ic_lock),
            title = "Encrypt Local Files",
            description = "All downloaded files are encrypted on your device.",
            checked = localFilesEncrypted.value,
            onCheckedChange = { appPrefs.privacyEncryptLocalFiles.set(it) }
        )
        Spacer(Modifier.height(12.dp))

        // Info card about panic mode (set up later)
        ValueCard(
            painterResource(MR.images.ic_delete_forever),
            "Panic Mode & Decoy PIN",
            "You'll set these up after creating your profile. The panic code instantly wipes all data."
        )

        Spacer(Modifier.weight(1f))

        OnboardingActionButton(
            modifier = Modifier.padding(bottom = 8.dp).fillMaxWidth(),
            labelId = MR.strings.setup_protection_continue,
            onboarding = OnboardingStage.Step0_3_NearbyExplainer,
            onclick = null
        )

        SectionBottomSpacer()
    }
}

// Screen 4: Nearby Mode Explainer
@Composable
fun InqalaabNearbyExplainerScreen() {
    ColumnWithScrollBarNoAppBar(
        Modifier.fillMaxSize().padding(horizontal = DEFAULT_PADDING)
    ) {
        Spacer(Modifier.height(40.dp))

        Icon(
            painterResource(MR.images.ic_wifi_tethering),
            contentDescription = null,
            modifier = Modifier.size(72.dp).align(Alignment.CenterHorizontally),
            tint = MaterialTheme.colors.primary
        )

        Spacer(Modifier.height(24.dp))

        Text(
            "Nearby Mode",
            style = MaterialTheme.typography.h4.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colors.onBackground,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(8.dp))

        Text(
            "Communicate without any internet connection",
            style = MaterialTheme.typography.body1,
            color = MaterialTheme.colors.secondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(32.dp))

        ValueCard(
            painterResource(MR.images.ic_bluetooth),
            "Find People Nearby",
            "Bluetooth Low Energy discovers other Inqalaab users within range — no internet or cell signal needed."
        )
        Spacer(Modifier.height(12.dp))

        ValueCard(
            painterResource(MR.images.ic_wifi_tethering),
            "Create a Local Chat Room",
            "WiFi Direct creates a private network between devices. Share a room code verbally and start chatting."
        )
        Spacer(Modifier.height(12.dp))

        ValueCard(
            painterResource(MR.images.ic_shield),
            "Nothing Leaves Your Device",
            "Messages stay between connected devices. No servers, no cloud, no records."
        )
        Spacer(Modifier.height(12.dp))

        ValueCard(
            painterResource(MR.images.ic_warning),
            "When the Internet Goes Down",
            "During shutdowns, switch to the Nearby tab. Everyone around you with Inqalaab can still communicate."
        )

        Spacer(Modifier.weight(1f))

        Button(
            onClick = { appPrefs.onboardingStage.set(OnboardingStage.Step2_CreateProfile) },
            modifier = Modifier.padding(bottom = 8.dp).fillMaxWidth(),
            shape = RoundedCornerShape(50),
            contentPadding = PaddingValues(horizontal = DEFAULT_PADDING * 2, vertical = 17.dp),
        ) {
            Text("Create My Profile", color = Color.White, fontWeight = FontWeight.Medium)
        }

        SectionBottomSpacer()
    }
}

// Reusable composables

@Composable
private fun ValueCard(icon: Painter, title: String, description: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colors.onBackground.copy(alpha = 0.05f))
            .padding(16.dp),
        verticalAlignment = Alignment.Top
    ) {
        Icon(
            icon,
            contentDescription = null,
            modifier = Modifier.size(28.dp),
            tint = MaterialTheme.colors.primary
        )
        Spacer(Modifier.width(12.dp))
        Column {
            Text(
                title,
                style = MaterialTheme.typography.subtitle1.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colors.onBackground
            )
            Spacer(Modifier.height(4.dp))
            Text(
                description,
                style = MaterialTheme.typography.body2,
                color = MaterialTheme.colors.secondary,
                fontSize = 13.sp
            )
        }
    }
}

@Composable
private fun PledgeItem(number: Int, title: String, description: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colors.onBackground.copy(alpha = 0.05f))
            .padding(16.dp),
        verticalAlignment = Alignment.Top
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(SimplexGreen),
            contentAlignment = Alignment.Center
        ) {
            Text(
                "$number",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 14.sp
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.subtitle1.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colors.onBackground
            )
            Spacer(Modifier.height(4.dp))
            Text(
                description,
                style = MaterialTheme.typography.body2,
                color = MaterialTheme.colors.secondary,
                fontSize = 13.sp
            )
        }
    }
}

@Composable
private fun SafetyToggleCard(
    icon: Painter,
    title: String,
    description: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colors.onBackground.copy(alpha = 0.05f))
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            icon,
            contentDescription = null,
            modifier = Modifier.size(28.dp),
            tint = if (checked) SimplexGreen else MaterialTheme.colors.secondary
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.subtitle1.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colors.onBackground
            )
            Spacer(Modifier.height(4.dp))
            Text(
                description,
                style = MaterialTheme.typography.body2,
                color = MaterialTheme.colors.secondary,
                fontSize = 13.sp
            )
        }
        Spacer(Modifier.width(8.dp))
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(checkedThumbColor = SimplexGreen)
        )
    }
}
