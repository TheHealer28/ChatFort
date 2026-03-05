package chat.simplex.common.views.safetyhub

import SectionBottomSpacer
import SectionDividerSpaced
import SectionItemView
import SectionTextFooter
import SectionView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
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
import chat.simplex.common.views.helpers.*
import chat.simplex.common.views.newchat.SimpleXCreatedLinkQRCode
import chat.simplex.common.views.usersettings.*
import chat.simplex.res.MR
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import dev.icerock.moko.resources.compose.painterResource

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
            title = "App Lock",
            description = "Require authentication to open app",
            isEnabled = appLockEnabled,
            onClick = showSettingsModal { SimplexLockView(ChatModel, currentLAMode, setPerformLA) }
        ),
        SecurityCheck(
            title = "Self-Destruct Code",
            description = "Duress PIN triggers emergency wipe",
            isEnabled = selfDestructEnabled,
            onClick = showSettingsModal { SimplexLockView(ChatModel, currentLAMode, setPerformLA) }
        ),
        SecurityCheck(
            title = "Screen Protection",
            description = "Block screenshots and screen recording",
            isEnabled = screenProtectionEnabled,
            onClick = showSettingsModal { PrivacySettingsView(it, showSettingsModal, setPerformLA) }
        ),
        SecurityCheck(
            title = "Database Encrypted",
            description = "Chat database is encrypted at rest",
            isEnabled = dbEncrypted,
            onClick = { ModalManager.start.showModal(true) { DatabaseView() } }
        ),
        SecurityCheck(
            title = "Local Files Encrypted",
            description = "Downloaded files are encrypted on device",
            isEnabled = localFilesEncrypted,
            onClick = showSettingsModal { PrivacySettingsView(it, showSettingsModal, setPerformLA) }
        ),
        SecurityCheck(
            title = "IP Address Protection",
            description = "Ask before using unknown relay servers",
            isEnabled = ipProtectionEnabled,
            onClick = showSettingsModal { PrivacySettingsView(it, showSettingsModal, setPerformLA) }
        ),
        SecurityCheck(
            title = "Link Sanitization",
            description = "Remove tracking parameters from links",
            isEnabled = linkSanitizationEnabled,
            onClick = showSettingsModal { PrivacySettingsView(it, showSettingsModal, setPerformLA) }
        )
    )

    val tabBarHeight = LocalTabBarHeight.current

    ColumnWithScrollBar(
        Modifier
            .fillMaxSize()
            .padding(bottom = tabBarHeight)
    ) {
        AppBarTitle("Safety Hub")

        // Your QR Code — share your address
        YourAddressCard()
        SectionDividerSpaced()

        // Get Started card when no features are enabled
        if (enabledCount == 0) {
            GetStartedCard()
            SectionDividerSpaced()
        }

        // Security Status Dashboard
        SecurityStatusDashboard(enabledCount, totalCount, appLockEnabled)
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
}

@Composable
private fun YourAddressCard() {
    val userAddress = remember { chatModel.userAddress }.value
    if (userAddress != null) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DEFAULT_PADDING),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                "Your Inqalaab QR Code",
                style = MaterialTheme.typography.subtitle1.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colors.primary
            )
            Spacer(Modifier.height(4.dp))
            Text(
                "Show or share to connect",
                style = MaterialTheme.typography.body2,
                color = MaterialTheme.colors.secondary
            )
            SimpleXCreatedLinkQRCode(
                connLink = userAddress.connLinkContact,
                short = true,
                modifier = Modifier.fillMaxWidth(0.6f),
                padding = PaddingValues(vertical = 8.dp)
            )
            val clipboard = LocalClipboardManager.current
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(
                    onClick = { clipboard.shareText(userAddress.connLinkContact.simplexChatUri(short = true)) },
                    shape = RoundedCornerShape(20.dp)
                ) {
                    Icon(
                        painterResource(MR.images.ic_share),
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Share")
                }
                OutlinedButton(
                    onClick = { clipboard.setText(AnnotatedString(userAddress.connLinkContact.simplexChatUri(short = true))) },
                    shape = RoundedCornerShape(20.dp)
                ) {
                    Icon(
                        painterResource(MR.images.ic_content_copy),
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("Copy Link")
                }
            }
        }
    } else {
        // No address created yet
        SectionView("YOUR ADDRESS") {
            SectionItemView(click = {
                withBGApi {
                    val connLink = chatModel.controller.apiCreateUserAddress(chatModel.currentUser.value?.remoteHostId)
                    if (connLink != null) {
                        val slDataSet = connLink.connShortLink != null
                        chatModel.userAddress.value = UserContactLinkRec(
                            connLink,
                            shortLinkDataSet = slDataSet,
                            shortLinkLargeDataSet = slDataSet,
                            addressSettings = AddressSettings(businessAddress = false, autoAccept = null, autoReply = null)
                        )
                    }
                }
            }) {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        painterResource(MR.images.ic_qr_code),
                        contentDescription = null,
                        tint = MaterialTheme.colors.primary,
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(Modifier.width(12.dp))
                    Column {
                        Text(
                            "Create Your Address",
                            style = MaterialTheme.typography.body1,
                            color = MaterialTheme.colors.primary,
                            fontWeight = FontWeight.Medium
                        )
                        Text(
                            "Generate a QR code so others can connect with you",
                            style = MaterialTheme.typography.body2,
                            color = MaterialTheme.colors.secondary,
                            fontSize = 13.sp
                        )
                    }
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
            "Set Up Your Safety",
            style = MaterialTheme.typography.h6.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colors.onBackground
        )
        Spacer(Modifier.height(8.dp))
        Text(
            "None of your security features are enabled yet. Scroll down to the Security Checklist and enable protections like App Lock, Screen Protection, and Database Encryption.",
            style = MaterialTheme.typography.body2,
            color = MaterialTheme.colors.secondary,
            fontSize = 13.sp,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center
        )
    }
}

@Composable
private fun SecurityStatusDashboard(enabledCount: Int, totalCount: Int, appLockEnabled: Boolean) {
    SectionView("SECURITY STATUS") {
        SectionItemView {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                StatusIndicator(
                    icon = painterResource(MR.images.ic_lock),
                    label = "Encryption",
                    active = true
                )
                StatusIndicator(
                    icon = painterResource(MR.images.ic_wifi_tethering),
                    label = "Relay",
                    active = true
                )
                StatusIndicator(
                    icon = painterResource(MR.images.ic_bluetooth),
                    label = "Nearby",
                    active = false
                )
                StatusIndicator(
                    icon = painterResource(MR.images.ic_security),
                    label = "Device Lock",
                    active = appLockEnabled
                )
            }
        }
        SectionItemView {
            Text(
                "$enabledCount of $totalCount protections active",
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
    SectionView("TRUSTED CONTACTS") {
        SectionItemView {
            Column {
                Text(
                    "Mark contacts as Trusted",
                    style = MaterialTheme.typography.body1,
                    color = MaterialTheme.colors.onBackground
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    "Long-press any contact in your Chats tab and select \"Mark as Trusted\" to add them here. Trusted contacts receive your emergency broadcasts.",
                    style = MaterialTheme.typography.body2,
                    color = MaterialTheme.colors.secondary,
                    fontSize = 13.sp
                )
            }
        }
        // "I'm Safe" broadcast
        SectionItemView(click = {
            AlertManager.shared.showAlertDialog(
                title = "Send \"I'm Safe\" Message",
                text = "This will send \"I'm safe\" to all your trusted contacts. Continue?",
                confirmText = "Send to All",
                onConfirm = {
                    // TODO: implement broadcast to trusted contacts
                }
            )
        }) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    painterResource(MR.images.ic_check_circle_filled),
                    contentDescription = "I'm Safe",
                    tint = SimplexGreen,
                    modifier = Modifier.size(24.dp)
                )
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(
                        "Send \"I'm Safe\" Broadcast",
                        style = MaterialTheme.typography.body1,
                        color = SimplexGreen,
                        fontWeight = FontWeight.Medium
                    )
                    Text(
                        "Notify all trusted contacts that you are safe",
                        style = MaterialTheme.typography.body2,
                        color = MaterialTheme.colors.secondary,
                        fontSize = 13.sp
                    )
                }
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
            "$enabledCount of $totalCount security features enabled",
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
                "All security features are active",
                style = MaterialTheme.typography.body2,
                color = SimplexGreen
            )
        } else {
            Spacer(Modifier.height(8.dp))
            Text(
                "Tap items below to improve your security",
                style = MaterialTheme.typography.body2,
                color = MaterialTheme.colors.secondary
            )
        }
    }
}

@Composable
private fun SecurityChecklistSection(checks: List<SecurityCheck>) {
    SectionView("SECURITY CHECKLIST") {
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
    SectionView("EMERGENCY ACTIONS") {
        // Emergency Wipe button
        SectionItemView({
            AlertManager.shared.showAlertDialog(
                title = generalGetString(MR.strings.app_name) + " — Emergency Wipe",
                text = "This will permanently delete ALL messages, contacts, files and encryption keys. A new empty profile will be created.\n\nThis action CANNOT be undone.",
                confirmText = "Wipe Everything",
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
                        "Emergency Wipe",
                        style = MaterialTheme.typography.body1,
                        color = Color.Red,
                        fontWeight = FontWeight.Medium
                    )
                    Text(
                        "Delete all data and create empty profile",
                        style = MaterialTheme.typography.body2,
                        color = MaterialTheme.colors.secondary,
                        fontSize = 13.sp
                    )
                }
            }
        }
    }
    SectionTextFooter("Add the Emergency Wipe tile to Quick Settings for one-tap access from any screen. Swipe down from the top of your screen and tap Edit to add it.")
}

@Composable
private fun SafetyResourcesSection() {
    val uriHandler = LocalUriHandler.current

    SectionView("SAFETY RESOURCES") {
        SettingsActionItem(
            painterResource(MR.images.ic_shield),
            "Digital Security Guide",
            click = { uriHandler.openUriCatching("https://ssd.eff.org/") },
            textColor = MaterialTheme.colors.primary
        )
        SettingsActionItem(
            painterResource(MR.images.ic_security),
            "Secure Communication Tips",
            click = { uriHandler.openUriCatching("https://www.frontlinedefenders.org/en/digital-security") },
            textColor = MaterialTheme.colors.primary
        )
        SettingsActionItem(
            painterResource(MR.images.ic_warning),
            "Report Surveillance",
            click = { uriHandler.openUriCatching("https://privacyinternational.org/") },
            textColor = MaterialTheme.colors.primary
        )
    }
}
