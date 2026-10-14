package chat.simplex.common.views.usersettings

import androidx.compose.foundation.layout.*
import androidx.compose.material.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.simplex.common.platform.ColumnWithScrollBar
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.helpers.AppBarTitle
import dev.icerock.moko.resources.compose.stringResource
import chat.simplex.res.MR

@Composable
fun PrivacyPolicyView() {
  ColumnWithScrollBar(Modifier.padding(horizontal = DEFAULT_PADDING)) {
    AppBarTitle(stringResource(MR.strings.privacy_policy), withPadding = false)

    PolicySection("What data we collect")
    PolicyText("None. ChatFort does not collect any personal data. There are no user accounts, no registration, no phone number or email requirements, and no user identifiers of any kind.")

    PolicySection("Messages and files")
    PolicyText("All messages and files are end-to-end encrypted. Messages are stored only on your device. The server relays encrypted messages and cannot read their content. Message metadata (who talks to whom) is not accessible to the server due to the protocol design.")

    PolicySection("Contacts and profiles")
    PolicyText("Your profile (display name) is stored only on your device and shared only with contacts you choose to connect with. There is no central directory of users.")

    PolicySection("Server infrastructure")
    PolicyText("ChatFort uses its own messaging relay server. The server does not store messages after delivery, does not log IP addresses or connection metadata. Server code is open source and auditable.")

    PolicySection("Device permissions")
    PolicyText("Camera: Scanning QR codes, taking photos, and video calls. Microphone: Voice messages and calls. Notifications: Alerting you to new messages and incoming calls. Storage: Sending, receiving, and saving files. Bluetooth & Wi-Fi: Nearby peer-to-peer communication (optional). Location: Required by Android for Bluetooth/Wi-Fi Direct scanning \u2014 no location data is collected, stored, or transmitted. Battery optimization: Background messaging service for reliable delivery. Full-screen intent: Incoming call notifications. Biometrics: Optional app lock. All permissions are optional and used only for their stated purpose.")

    PolicySection("Nearby peer-to-peer communication")
    PolicyText("Communication happens directly between devices over Bluetooth LE and Wi-Fi Direct. No data passes through any external server. All nearby messages are encrypted (AES-256-GCM). No location data is collected \u2014 the Location permission is only required by Android for Bluetooth and Wi-Fi Direct scanning.")

    PolicySection("Analytics and tracking")
    PolicyText("ChatFort contains no analytics, no tracking, no advertising, and no third-party SDKs that collect data.")

    PolicySection("Security features")
    PolicyText("App lock: Optionally lock the app with a passcode or biometrics. Emergency code: A self-destruct code that wipes all data when entered. Quick Settings tile: A \"Reset App\" tile that can wipe all data from the notification shade. Screen protection: Prevents app content from appearing in screenshots and recent apps.")

    PolicySection("Data deletion")
    PolicyText("You can delete all your data at any time using the emergency code, the Quick Settings tile, deleting the database from Settings, or uninstalling the app.")

    Spacer(Modifier.height(DEFAULT_PADDING))
  }
}

@Composable
private fun PolicySection(title: String) {
  Text(
    title,
    Modifier.padding(top = 16.dp, bottom = 4.dp),
    fontWeight = FontWeight.Bold,
    style = MaterialTheme.typography.h3,
    lineHeight = 24.sp
  )
}

@Composable
private fun PolicyText(text: String) {
  Text(
    text,
    Modifier.padding(bottom = 8.dp),
    style = MaterialTheme.typography.body1,
    color = MaterialTheme.colors.secondary,
    lineHeight = 22.sp
  )
}
