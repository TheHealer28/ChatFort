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
        AppBarTitle(generalGetString(MR.strings.inq_resources_title))

        // Quick Start Guide
        SectionView(generalGetString(MR.strings.inq_getting_started)) {
            ResourceCard(
                title = generalGetString(MR.strings.inq_qs_how_to_connect),
                description = generalGetString(MR.strings.inq_qs_connect_detail)
            )
            ResourceCard(
                title = generalGetString(MR.strings.inq_qs_making_calls),
                description = generalGetString(MR.strings.inq_qs_calls_detail)
            )
            ResourceCard(
                title = generalGetString(MR.strings.inq_qs_safety),
                description = generalGetString(MR.strings.inq_qs_safety_detail)
            )
            ResourceCard(
                title = generalGetString(MR.strings.inq_qs_emergency_wipe),
                description = generalGetString(MR.strings.inq_qs_emergency_detail)
            )
        }
        SectionDividerSpaced()

        // Internet Shutdown Guide
        SectionView(generalGetString(MR.strings.inq_during_shutdown)) {
            ResourceCard(
                title = generalGetString(MR.strings.inq_step1_title),
                description = generalGetString(MR.strings.inq_step1_desc)
            )
            ResourceCard(
                title = generalGetString(MR.strings.inq_step2_title),
                description = generalGetString(MR.strings.inq_step2_desc)
            )
            ResourceCard(
                title = generalGetString(MR.strings.inq_step3_title),
                description = generalGetString(MR.strings.inq_step3_desc)
            )
            ResourceCard(
                title = generalGetString(MR.strings.inq_step4_title),
                description = generalGetString(MR.strings.inq_step4_desc)
            )
        }
        SectionDividerSpaced()

        // Secure Communications
        SectionView(generalGetString(MR.strings.inq_secure_comm)) {
            ResourceCard(
                title = generalGetString(MR.strings.inq_use_disappearing),
                description = generalGetString(MR.strings.inq_use_disappearing_desc)
            )
            ResourceCard(
                title = generalGetString(MR.strings.inq_verify_contacts),
                description = generalGetString(MR.strings.inq_verify_contacts_desc)
            )
            ResourceCard(
                title = generalGetString(MR.strings.inq_enable_all_safety),
                description = generalGetString(MR.strings.inq_enable_all_safety_desc)
            )
            ResourceCard(
                title = generalGetString(MR.strings.inq_setup_panic),
                description = generalGetString(MR.strings.inq_setup_panic_desc)
            )
        }
        SectionDividerSpaced()

        // Digital Rights Organizations
        SectionView(generalGetString(MR.strings.inq_digital_rights)) {
            SettingsActionItem(
                painterResource(MR.images.ic_shield),
                generalGetString(MR.strings.inq_eff),
                click = { uriHandler.openUriCatching("https://ssd.eff.org/") },
                textColor = MaterialTheme.colors.primary
            )
            SettingsActionItem(
                painterResource(MR.images.ic_shield),
                generalGetString(MR.strings.inq_frontline),
                click = { uriHandler.openUriCatching("https://www.frontlinedefenders.org/en/digital-security") },
                textColor = MaterialTheme.colors.primary
            )
            SettingsActionItem(
                painterResource(MR.images.ic_shield),
                generalGetString(MR.strings.inq_privacy_intl),
                click = { uriHandler.openUriCatching("https://privacyinternational.org/") },
                textColor = MaterialTheme.colors.primary
            )
        }
        SectionDividerSpaced()

        // Safety if detained
        SectionView(generalGetString(MR.strings.inq_if_detained)) {
            ResourceCard(
                title = generalGetString(MR.strings.inq_before_it_happens),
                description = generalGetString(MR.strings.inq_before_desc)
            )
            ResourceCard(
                title = generalGetString(MR.strings.inq_if_you_have_moment),
                description = generalGetString(MR.strings.inq_moment_desc)
            )
            ResourceCard(
                title = generalGetString(MR.strings.inq_device_taken),
                description = generalGetString(MR.strings.inq_device_taken_desc)
            )
            ResourceCard(
                title = generalGetString(MR.strings.inq_after_release),
                description = generalGetString(MR.strings.inq_after_release_desc)
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
