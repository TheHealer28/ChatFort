package chat.simplex.common.views.onboarding

import SectionBottomSpacer
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.Composable
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
import dev.icerock.moko.resources.compose.stringResource

@Composable
fun InqalaabMissionScreen() {
    ColumnWithScrollBarNoAppBar(
        Modifier.fillMaxSize().padding(horizontal = DEFAULT_PADDING)
    ) {
        Spacer(Modifier.height(40.dp))

        // Megaphone icon
        Icon(
            painterResource(MR.images.ic_flag_filled),
            contentDescription = null,
            modifier = Modifier.size(72.dp).align(Alignment.CenterHorizontally),
            tint = MaterialTheme.colors.primary
        )

        Spacer(Modifier.height(24.dp))

        Text(
            "Inqalaab",
            style = MaterialTheme.typography.h4.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colors.onBackground,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(8.dp))

        Text(
            "Secure communication for those who resist",
            style = MaterialTheme.typography.body1,
            color = MaterialTheme.colors.secondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(32.dp))

        // Value cards
        ValueCard(
            painterResource(MR.images.ic_shield),
            "Built for Safety",
            "Emergency wipe, duress PIN, and screen protection — designed for high-risk environments"
        )
        Spacer(Modifier.height(12.dp))

        ValueCard(
            painterResource(MR.images.ic_lock),
            "No Metadata",
            "No phone number, no email, no tracking — your identity stays yours"
        )
        Spacer(Modifier.height(12.dp))

        ValueCard(
            painterResource(MR.images.ic_wifi_tethering),
            "Works Offline",
            "Nearby Chat lets you communicate without internet using Bluetooth and WiFi Direct"
        )
        Spacer(Modifier.height(12.dp))

        ValueCard(
            painterResource(MR.images.ic_code),
            "Fully Open Source",
            "Every line of code is public and auditable — no hidden backdoors"
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

@Composable
fun InqalaabSecurityPledgeScreen() {
    ColumnWithScrollBarNoAppBar(
        Modifier.fillMaxSize().padding(horizontal = DEFAULT_PADDING)
    ) {
        Spacer(Modifier.height(40.dp))

        // Shield checkmark icon
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

        PledgeItem(3, "Panic mode for emergencies", "Wipe all data instantly if you're ever in danger. One shake is all it takes.")
        Spacer(Modifier.height(12.dp))

        PledgeItem(4, "Community-run servers", "Your messages route through independent servers that no government controls.")
        Spacer(Modifier.height(12.dp))

        PledgeItem(5, "Open source & auditable", "Our code is public. Anyone can verify we keep these promises.")

        Spacer(Modifier.weight(1f))

        Button(
            onClick = { appPrefs.onboardingStage.set(OnboardingStage.Step2_CreateProfile) },
            modifier = Modifier.padding(bottom = 8.dp).fillMaxWidth(),
            shape = RoundedCornerShape(50),
            contentPadding = PaddingValues(horizontal = DEFAULT_PADDING * 2, vertical = 17.dp),
        ) {
            Text("I understand \u2014 Create my profile", color = Color.White, fontWeight = FontWeight.Medium)
        }

        SectionBottomSpacer()
    }
}

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
        // Number badge
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
