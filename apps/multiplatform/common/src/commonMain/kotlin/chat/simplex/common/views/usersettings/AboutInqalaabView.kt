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
        AppBarTitle(generalGetString(MR.strings.inq_about_title))

        SectionView(generalGetString(MR.strings.inq_server_infrastructure)) {
            InfoCard(
                generalGetString(MR.strings.inq_community_relay),
                generalGetString(MR.strings.inq_community_relay_desc)
            )
            InfoCard(
                generalGetString(MR.strings.inq_server_locations),
                generalGetString(MR.strings.inq_server_locations_desc)
            )
        }
        SectionDividerSpaced()

        SectionView(generalGetString(MR.strings.inq_data_stored)) {
            InfoCard(
                generalGetString(MR.strings.inq_what_we_store),
                generalGetString(MR.strings.inq_what_we_store_desc)
            )
            InfoCard(
                generalGetString(MR.strings.inq_what_never_store),
                generalGetString(MR.strings.inq_what_never_store_desc)
            )
        }
        SectionDividerSpaced()

        SectionView(generalGetString(MR.strings.inq_panic_wipe_section)) {
            InfoCard(
                generalGetString(MR.strings.inq_how_wipe_works),
                generalGetString(MR.strings.inq_how_wipe_works_desc)
            )
            InfoCard(
                generalGetString(MR.strings.inq_self_destruct_about),
                generalGetString(MR.strings.inq_self_destruct_about_desc)
            )
        }
        SectionDividerSpaced()

        SectionView(generalGetString(MR.strings.inq_encryption_section)) {
            InfoCard(
                generalGetString(MR.strings.inq_e2e_encryption),
                generalGetString(MR.strings.inq_e2e_encryption_desc)
            )
            InfoCard(
                generalGetString(MR.strings.inq_db_encryption),
                generalGetString(MR.strings.inq_db_encryption_desc)
            )
            InfoCard(
                generalGetString(MR.strings.inq_file_encryption),
                generalGetString(MR.strings.inq_file_encryption_desc)
            )
        }
        SectionDividerSpaced()

        SectionView(generalGetString(MR.strings.inq_open_source_section)) {
            InfoCard(
                generalGetString(MR.strings.inq_full_transparency),
                generalGetString(MR.strings.inq_full_transparency_desc)
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
