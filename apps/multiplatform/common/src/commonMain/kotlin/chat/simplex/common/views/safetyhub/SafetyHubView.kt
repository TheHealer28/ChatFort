package chat.simplex.common.views.safetyhub

import SectionBottomSpacer
import SectionDividerSpaced
import SectionItemView
import SectionTextFooter
import SectionView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.simplex.common.model.*
import chat.simplex.common.model.ChatController.appPrefs
import chat.simplex.common.platform.*
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.chatlist.LocalTabBarHeight
import chat.simplex.common.views.database.DatabaseView
import chat.simplex.common.views.database.restartChatOrApp
import chat.simplex.common.views.helpers.*
import chat.simplex.common.views.usersettings.*
import chat.simplex.res.MR
import dev.icerock.moko.resources.compose.painterResource
import kotlinx.coroutines.delay

private data class SecurityCheck(
    val title: String,
    val description: String,
    val isEnabled: Boolean,
    val onClick: () -> Unit
)

@Composable
fun SafetyHubView(chatModel: ChatModel, setPerformLA: (Boolean) -> Unit) {
    // Read all security preference states
    val appLockEnabled = remember { appPrefs.performLA.state }.value
    val selfDestructEnabled = remember { appPrefs.selfDestruct.state }.value
    val screenProtectionEnabled = remember { appPrefs.privacyProtectScreen.state }.value
    val dbEncrypted = chatModel.chatDbEncrypted.value == true
    val localFilesEncrypted = remember { appPrefs.privacyEncryptLocalFiles.state }.value
    val ipProtectionEnabled = remember { appPrefs.privacyAskToApproveRelays.state }.value
    val linkSanitizationEnabled = remember { appPrefs.privacySanitizeLinks.state }.value

    val checks = listOf(appLockEnabled, selfDestructEnabled, screenProtectionEnabled,
        dbEncrypted, localFilesEncrypted, ipProtectionEnabled, linkSanitizationEnabled)
    val enabledCount = checks.count { it }
    val totalCount = checks.size

    // Build modal navigation helpers (same pattern as SettingsView)
    val showSettingsModal: (@Composable (ChatModel) -> Unit) -> (() -> Unit) = { modalView ->
        { ModalManager.start.showModal(true) { modalView(chatModel) } }
    }

    val currentLAMode = remember { ChatModel.controller.appPrefs.laMode }

    val securityChecks = listOf(
        SecurityCheck(
            title = generalGetString(MR.strings.inq_app_lock),
            description = generalGetString(MR.strings.inq_app_lock_desc),
            isEnabled = appLockEnabled,
            onClick = showSettingsModal { SimplexLockView(ChatModel, currentLAMode, setPerformLA) }
        ),
        SecurityCheck(
            title = generalGetString(MR.strings.inq_self_destruct_code),
            description = generalGetString(MR.strings.inq_self_destruct_desc),
            isEnabled = selfDestructEnabled,
            onClick = showSettingsModal { SimplexLockView(ChatModel, currentLAMode, setPerformLA) }
        ),
        SecurityCheck(
            title = generalGetString(MR.strings.inq_screen_protection),
            description = generalGetString(MR.strings.inq_screen_protection_desc),
            isEnabled = screenProtectionEnabled,
            onClick = showSettingsModal { PrivacySettingsView(it, showSettingsModal, setPerformLA) }
        ),
        SecurityCheck(
            title = generalGetString(MR.strings.inq_db_encrypted),
            description = generalGetString(MR.strings.inq_db_encrypted_desc),
            isEnabled = dbEncrypted,
            onClick = { ModalManager.start.showModal(true) { DatabaseView() } }
        ),
        SecurityCheck(
            title = generalGetString(MR.strings.inq_local_files_encrypted),
            description = generalGetString(MR.strings.inq_local_files_desc),
            isEnabled = localFilesEncrypted,
            onClick = showSettingsModal { PrivacySettingsView(it, showSettingsModal, setPerformLA) }
        ),
        SecurityCheck(
            title = generalGetString(MR.strings.inq_ip_protection),
            description = generalGetString(MR.strings.inq_ip_protection_desc),
            isEnabled = ipProtectionEnabled,
            onClick = showSettingsModal { PrivacySettingsView(it, showSettingsModal, setPerformLA) }
        ),
        SecurityCheck(
            title = generalGetString(MR.strings.inq_link_sanitization),
            description = generalGetString(MR.strings.inq_link_sanitization_desc),
            isEnabled = linkSanitizationEnabled,
            onClick = showSettingsModal { PrivacySettingsView(it, showSettingsModal, setPerformLA) }
        )
    )

    val tabBarHeight = LocalTabBarHeight.current
    val safetyBounds = remember { mutableStateOf<androidx.compose.ui.geometry.Rect?>(null) }
    val safetyTooltipShown = remember { chat.simplex.common.model.ChatController.appPrefs.tooltipSafetyHubShown.state }

    Box(Modifier.fillMaxSize()) {
        ColumnWithScrollBar(
            Modifier
                .fillMaxSize()
                .padding(bottom = tabBarHeight)
        ) {
            AppBarTitle(generalGetString(MR.strings.inq_safety_hub_title))

            // Language toggle
            LanguageToggle()
            SectionDividerSpaced()

            // Get Started card when no features are enabled
            if (enabledCount == 0) {
                GetStartedCard()
                SectionDividerSpaced()
            }

            // Security Status Dashboard
            Box(Modifier.onGloballyPositioned { coordinates ->
                safetyBounds.value = coordinates.boundsInRoot()
            }) {
                SecurityStatusDashboard(enabledCount, totalCount, appLockEnabled)
            }
            SectionDividerSpaced()

            // Security Score Header
            SecurityScoreHeader(enabledCount, totalCount)
            SectionDividerSpaced()

            // Security Checklist
            SecurityChecklistSection(securityChecks)
            SectionDividerSpaced()

            // Trusted Contacts
            TrustedContactsSection()
            SectionDividerSpaced()

            // Emergency Actions
            EmergencyActionsSection()
            SectionDividerSpaced()

            // Safety Resources
            SafetyResourcesSection()
            SectionBottomSpacer()
        }

        ChatFortTooltipOverlay(
            show = !safetyTooltipShown.value,
            targetBounds = safetyBounds.value,
            message = generalGetString(MR.strings.inq_tooltip_safety_hub),
            onDismiss = { chat.simplex.common.model.ChatController.appPrefs.tooltipSafetyHubShown.set(true) }
        )
    }
}

@Composable
private fun LanguageToggle() {
    val languagePref = ChatModel.controller.appPrefs.appLanguage
    val state = rememberSaveable { mutableStateOf(languagePref.get() ?: "en") }
    val languages = listOf("en" to "English", "ur" to "اردو")

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DEFAULT_PADDING, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            generalGetString(MR.strings.settings_section_title_language),
            color = MaterialTheme.colors.onBackground
        )
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(8.dp))
                .background(MaterialTheme.colors.onBackground.copy(alpha = 0.08f))
                .padding(2.dp)
        ) {
            languages.forEach { (code, label) ->
                val selected = state.value == code
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .background(if (selected) MaterialTheme.colors.primary else Color.Transparent)
                        .clickable {
                            if (state.value != code) {
                                state.value = code
                                languagePref.set(code)
                                withApi {
                                    delay(200)
                                    restartChatOrApp()
                                }
                            }
                        }
                        .padding(horizontal = 16.dp, vertical = 6.dp)
                ) {
                    Text(
                        label,
                        color = if (selected) Color.White else MaterialTheme.colors.secondary,
                        fontWeight = FontWeight.Medium,
                        fontSize = 14.sp
                    )
                }
            }
        }
    }
}

@Composable
private fun GetStartedCard() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DEFAULT_PADDING, vertical = 8.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colors.primary.copy(alpha = 0.08f))
            .padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            painterResource(MR.images.ic_shield),
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = MaterialTheme.colors.primary
        )
        Spacer(Modifier.height(12.dp))
        Text(
            generalGetString(MR.strings.inq_setup_safety),
            style = MaterialTheme.typography.h6.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colors.onBackground
        )
        Spacer(Modifier.height(8.dp))
        Text(
            generalGetString(MR.strings.inq_setup_safety_desc),
            style = MaterialTheme.typography.body2,
            color = MaterialTheme.colors.secondary,
            fontSize = 13.sp,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center
        )
    }
}

@Composable
private fun SecurityStatusDashboard(enabledCount: Int, totalCount: Int, appLockEnabled: Boolean) {
    SectionView(generalGetString(MR.strings.inq_security_status)) {
        SectionItemView {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                StatusIndicator(
                    icon = painterResource(MR.images.ic_lock),
                    label = generalGetString(MR.strings.inq_encryption),
                    active = true
                )
                StatusIndicator(
                    icon = painterResource(MR.images.ic_wifi_tethering),
                    label = generalGetString(MR.strings.inq_relay),
                    active = true
                )
                StatusIndicator(
                    icon = painterResource(MR.images.ic_bluetooth),
                    label = generalGetString(MR.strings.inq_nearby_label),
                    active = false
                )
                StatusIndicator(
                    icon = painterResource(MR.images.ic_security),
                    label = generalGetString(MR.strings.inq_device_lock),
                    active = appLockEnabled
                )
            }
        }
        SectionItemView {
            Text(
                String.format(generalGetString(MR.strings.inq_protections_active), enabledCount, totalCount),
                style = MaterialTheme.typography.body2,
                color = if (enabledCount == totalCount) SimplexGreen else MaterialTheme.colors.secondary
            )
        }
    }
}

@Composable
private fun StatusIndicator(icon: Painter, label: String, active: Boolean) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(
            icon,
            contentDescription = label,
            modifier = Modifier.size(24.dp),
            tint = if (active) SimplexGreen else MaterialTheme.colors.secondary.copy(alpha = 0.4f)
        )
        Spacer(Modifier.height(4.dp))
        Text(
            label,
            style = MaterialTheme.typography.caption,
            color = if (active) MaterialTheme.colors.onBackground else MaterialTheme.colors.secondary.copy(alpha = 0.4f),
            fontSize = 11.sp
        )
    }
}

@Composable
private fun TrustedContactsSection() {
    val trustedRaw = remember { appPrefs.inqTrustedContacts.state }.value
    val count = TrustedContacts.trustedChats(trustedRaw).size
    SectionView(generalGetString(MR.strings.inq_trusted_contacts)) {
        SectionItemView(click = { ModalManager.start.showModal(true) { EmergencyContactsView() } }) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    painterResource(MR.images.ic_verified_user),
                    contentDescription = null,
                    tint = SimplexGreen,
                    modifier = Modifier.size(24.dp)
                )
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        generalGetString(MR.strings.inq_emergency_contacts),
                        style = MaterialTheme.typography.body1,
                        color = MaterialTheme.colors.onBackground,
                        fontWeight = FontWeight.Medium
                    )
                    Text(
                        if (count == 0) generalGetString(MR.strings.inq_emergency_contacts_desc)
                        else String.format(generalGetString(MR.strings.inq_emergency_contacts_count), count),
                        style = MaterialTheme.typography.body2,
                        color = MaterialTheme.colors.secondary,
                        fontSize = 13.sp
                    )
                }
                Icon(
                    painterResource(MR.images.ic_chevron_right),
                    contentDescription = null,
                    tint = MaterialTheme.colors.secondary
                )
            }
        }
    }
}

@Composable
private fun SecurityScoreHeader(enabledCount: Int, totalCount: Int) {
    val progress = if (totalCount > 0) enabledCount.toFloat() / totalCount else 0f
    val scoreColor = when {
        progress >= 1f -> SimplexGreen
        progress >= 0.5f -> WarningOrange
        else -> Color.Red
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DEFAULT_PADDING, vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // Shield icon
        Icon(
            painterResource(MR.images.ic_shield),
            contentDescription = "Security Status",
            modifier = Modifier.size(64.dp),
            tint = scoreColor
        )
        Spacer(Modifier.height(12.dp))

        // Score text
        Text(
            String.format(generalGetString(MR.strings.inq_security_features_count), enabledCount, totalCount),
            style = MaterialTheme.typography.h6.copy(fontWeight = FontWeight.Medium),
            color = MaterialTheme.colors.onBackground
        )
        Spacer(Modifier.height(12.dp))

        // Progress bar
        LinearProgressIndicator(
            progress = progress,
            modifier = Modifier
                .fillMaxWidth()
                .height(8.dp)
                .clip(RoundedCornerShape(4.dp)),
            color = scoreColor,
            backgroundColor = MaterialTheme.colors.onBackground.copy(alpha = 0.12f)
        )

        if (enabledCount == totalCount) {
            Spacer(Modifier.height(8.dp))
            Text(
                generalGetString(MR.strings.inq_all_features_active),
                style = MaterialTheme.typography.body2,
                color = SimplexGreen
            )
        } else {
            Spacer(Modifier.height(8.dp))
            Text(
                generalGetString(MR.strings.inq_tap_to_improve),
                style = MaterialTheme.typography.body2,
                color = MaterialTheme.colors.secondary
            )
        }
    }
}

@Composable
private fun SecurityChecklistSection(checks: List<SecurityCheck>) {
    SectionView(generalGetString(MR.strings.inq_security_checklist)) {
        checks.forEach { check ->
            SecurityChecklistRow(check)
        }
    }
}

@Composable
private fun SecurityChecklistRow(check: SecurityCheck) {
    SectionItemView(check.onClick) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Row(
                Modifier.weight(1f),
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Status icon
                Icon(
                    painterResource(
                        if (check.isEnabled) MR.images.ic_check_circle_filled
                        else MR.images.ic_radio_button_unchecked
                    ),
                    contentDescription = if (check.isEnabled) "Enabled" else "Disabled",
                    tint = if (check.isEnabled) SimplexGreen else MaterialTheme.colors.secondary,
                    modifier = Modifier.size(24.dp)
                )
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(
                        check.title,
                        style = MaterialTheme.typography.body1,
                        color = MaterialTheme.colors.onBackground
                    )
                    Text(
                        check.description,
                        style = MaterialTheme.typography.body2,
                        color = MaterialTheme.colors.secondary,
                        fontSize = 13.sp
                    )
                }
            }
            // Chevron
            Icon(
                painterResource(MR.images.ic_arrow_forward_ios),
                contentDescription = "Open",
                tint = MaterialTheme.colors.secondary,
                modifier = Modifier.size(16.dp)
            )
        }
    }
}

@Composable
private fun EmergencyActionsSection() {
    SectionView(generalGetString(MR.strings.inq_emergency_actions)) {
        // Emergency Wipe button
        SectionItemView({
            AlertManager.shared.showAlertDialog(
                title = generalGetString(MR.strings.app_name) + " — " + generalGetString(MR.strings.inq_emergency_wipe),
                text = generalGetString(MR.strings.inq_emergency_wipe_text),
                confirmText = generalGetString(MR.strings.inq_wipe_everything),
                destructive = true,
                onConfirm = {
                    withLongRunningApi {
                        performEmergencyWipe()
                    }
                }
            )
        }) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    painterResource(MR.images.ic_delete_forever),
                    contentDescription = "Emergency Wipe",
                    tint = Color.Red,
                    modifier = Modifier.size(24.dp)
                )
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(
                        generalGetString(MR.strings.inq_emergency_wipe),
                        style = MaterialTheme.typography.body1,
                        color = Color.Red,
                        fontWeight = FontWeight.Medium
                    )
                    Text(
                        generalGetString(MR.strings.inq_emergency_wipe_desc),
                        style = MaterialTheme.typography.body2,
                        color = MaterialTheme.colors.secondary,
                        fontSize = 13.sp
                    )
                }
            }
        }
    }
    SectionTextFooter(generalGetString(MR.strings.inq_emergency_wipe_tip))
}

@Composable
private fun SafetyResourcesSection() {
    val uriHandler = LocalUriHandler.current

    SectionView(generalGetString(MR.strings.inq_safety_resources)) {
        SettingsActionItem(
            painterResource(MR.images.ic_shield),
            generalGetString(MR.strings.inq_digital_security_guide),
            click = { uriHandler.openUriCatching("https://ssd.eff.org/") },
            textColor = MaterialTheme.colors.primary
        )
        SettingsActionItem(
            painterResource(MR.images.ic_security),
            generalGetString(MR.strings.inq_secure_comm_tips),
            click = { uriHandler.openUriCatching("https://www.frontlinedefenders.org/en/digital-security") },
            textColor = MaterialTheme.colors.primary
        )
        SettingsActionItem(
            painterResource(MR.images.ic_warning),
            generalGetString(MR.strings.inq_report_surveillance),
            click = { uriHandler.openUriCatching("https://privacyinternational.org/") },
            textColor = MaterialTheme.colors.primary
        )
    }
}
