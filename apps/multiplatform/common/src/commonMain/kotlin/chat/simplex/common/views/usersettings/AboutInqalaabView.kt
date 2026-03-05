package chat.simplex.common.views.usersettings

import SectionBottomSpacer
import SectionDividerSpaced
import SectionItemView
import SectionView
import androidx.compose.foundation.layout.*
import androidx.compose.material.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.simplex.common.platform.ColumnWithScrollBar
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.helpers.*
import chat.simplex.res.MR
import dev.icerock.moko.resources.compose.painterResource

@Composable
fun AboutInqalaabView() {
    ColumnWithScrollBar {
        AppBarTitle("About Inqalaab")

        SectionView("SERVER INFRASTRUCTURE") {
            InfoCard(
                "Community-Run Relay Servers",
                "Your messages are routed through independent relay servers operated by the Inqalaab community. No single entity controls all servers. Servers never see message content — they only relay encrypted data between devices."
            )
            InfoCard(
                "Server Locations",
                "Relay servers are distributed across multiple jurisdictions to prevent any single government from intercepting or shutting down the network."
            )
        }
        SectionDividerSpaced()

        SectionView("DATA STORED ON YOUR DEVICE") {
            InfoCard(
                "What We Store Locally",
                "Your chat messages, contacts, and downloaded files are stored only on your device. The database is encrypted at rest when you enable database encryption."
            )
            InfoCard(
                "What We Never Store",
                "No message content, metadata, contact lists, or usage data is ever stored on our servers or sent to any third party. We have no analytics, no telemetry, and no crash reporting."
            )
        }
        SectionDividerSpaced()

        SectionView("PANIC WIPE") {
            InfoCard(
                "How Emergency Wipe Works",
                "When triggered, emergency wipe permanently deletes all messages, contacts, encryption keys, downloaded files, and your profile. A new empty profile is created so the app appears freshly installed."
            )
            InfoCard(
                "Self-Destruct Code",
                "When enabled, entering the self-destruct code instead of your regular passcode triggers an immediate emergency wipe. This protects you if you are forced to unlock the app."
            )
        }
        SectionDividerSpaced()

        SectionView("ENCRYPTION") {
            InfoCard(
                "End-to-End Encryption",
                "All messages use double-ratchet end-to-end encryption. Even relay servers cannot read your messages. Each conversation uses unique encryption keys."
            )
            InfoCard(
                "Database Encryption",
                "When enabled, your entire local database is encrypted with a passphrase you choose. Without the passphrase, the data is unreadable — even if your device is seized."
            )
            InfoCard(
                "File Encryption",
                "Downloaded files and media can be encrypted on-device. Encrypted files cannot be accessed by other apps or file managers."
            )
        }
        SectionDividerSpaced()

        SectionView("OPEN SOURCE") {
            InfoCard(
                "Full Transparency",
                "Inqalaab is fully open source. Every line of code — client, server, and cryptographic protocols — is publicly auditable. We believe security through obscurity is no security at all."
            )
        }
        SectionBottomSpacer()
    }
}

@Composable
private fun InfoCard(title: String, description: String) {
    SectionItemView {
        Column {
            Text(
                title,
                style = MaterialTheme.typography.body1,
                fontWeight = FontWeight.Medium,
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
