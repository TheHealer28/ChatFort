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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.simplex.common.model.*
import chat.simplex.common.model.ChatController.appPrefs
import chat.simplex.common.platform.*
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.helpers.*
import chat.simplex.res.MR
import dev.icerock.moko.resources.compose.painterResource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** ChatFort: pick emergency (trusted) contacts and send them a check-in message with one tap. */
@Composable
fun EmergencyContactsView() {
  val trustedRaw = remember { appPrefs.inqTrustedContacts.state }.value
  val trusted = TrustedContacts.trustedChats(trustedRaw)
  val selectable = TrustedContacts.selectableChats()
  val savedMessage = remember { appPrefs.inqCheckInMessage.state }.value
  val message = remember { mutableStateOf(TrustedContacts.checkInMessage(savedMessage)) }
  val sending = remember { mutableStateOf(false) }
  val canSend = trusted.isNotEmpty() && message.value.isNotBlank() && !sending.value

  ColumnWithScrollBar {
    AppBarTitle(generalGetString(MR.strings.inq_emergency_contacts))
    Row(Modifier.padding(horizontal = DEFAULT_PADDING), verticalAlignment = Alignment.CenterVertically) {
      Icon(painterResource(MR.images.ic_verified_user), null, tint = SimplexGreen, modifier = Modifier.size(28.dp))
      Spacer(Modifier.width(10.dp))
      Text(
        String.format(generalGetString(MR.strings.inq_emergency_contacts_count), trusted.size),
        color = MaterialTheme.colors.secondary
      )
    }
    Text(
      generalGetString(MR.strings.inq_emergency_contacts_intro),
      Modifier.padding(horizontal = DEFAULT_PADDING, vertical = 12.dp),
      color = MaterialTheme.colors.secondary,
      lineHeight = 20.sp
    )
    Spacer(Modifier.height(8.dp))

    SectionView(generalGetString(MR.strings.inq_checkin_message_title).uppercase()) {
      TextEditor(message, Modifier.height(110.dp), placeholder = generalGetString(MR.strings.inq_checkin_default))
    }
    SectionTextFooter(generalGetString(MR.strings.inq_checkin_message_footer))
    // Save edits (blank or the default text = follow the app language)
    LaunchedEffect(message.value) {
      val v = message.value.trim()
      appPrefs.inqCheckInMessage.set(if (v.isEmpty() || v == generalGetString(MR.strings.inq_checkin_default)) null else v)
    }

    Spacer(Modifier.height(16.dp))
    Box(
      Modifier
        .padding(horizontal = DEFAULT_PADDING)
        .fillMaxWidth()
        .clip(RoundedCornerShape(14.dp))
        .background(if (canSend) SimplexGreen else MaterialTheme.colors.secondary.copy(alpha = 0.25f))
        .clickable(enabled = canSend) {
          val text = message.value.trim()
          AlertManager.shared.showAlertDialog(
            title = generalGetString(MR.strings.inq_send_checkin_now),
            text = String.format(generalGetString(MR.strings.inq_send_checkin_confirm), trusted.size),
            confirmText = generalGetString(MR.strings.inq_send_to_all),
            onConfirm = {
              sending.value = true
              withBGApi {
                val (sent, notSent) = try {
                  TrustedContacts.sendCheckIn(text)
                } catch (e: Exception) {
                  Log.e(TAG, "Check-in send failed: ${e.message}")
                  0 to trusted.size
                }
                withContext(Dispatchers.Main) {
                  sending.value = false
                  showToast(
                    if (notSent == 0) String.format(generalGetString(MR.strings.inq_safe_sent_toast), sent)
                    else String.format(generalGetString(MR.strings.inq_safe_partial_toast), sent, notSent)
                  )
                }
              }
            }
          )
        }
        .padding(vertical = 14.dp, horizontal = 18.dp)
    ) {
      Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(painterResource(MR.images.ic_arrow_upward), null, tint = Color.White, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(14.dp))
        Column {
          Text(generalGetString(MR.strings.inq_send_checkin_now), color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
          Text(
            String.format(generalGetString(MR.strings.inq_send_checkin_to), trusted.size),
            color = Color.White.copy(alpha = 0.85f),
            fontSize = 13.sp
          )
        }
      }
    }

    SectionDividerSpaced(maxTopPadding = true)
    SectionView(generalGetString(MR.strings.inq_select_trusted_contacts).uppercase()) {
      if (selectable.isEmpty()) {
        SectionItemView {
          Text(generalGetString(MR.strings.inq_no_contacts_yet), color = MaterialTheme.colors.secondary)
        }
      }
      selectable.forEach { chat ->
        val contact = (chat.chatInfo as ChatInfo.Direct).contact
        val isTrusted = TrustedContacts.isTrusted(contact, trustedRaw)
        SectionItemView(click = { TrustedContacts.setTrusted(contact, !isTrusted) }) {
          Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            ChatInfoImage(chat.chatInfo, size = 40.dp)
            Spacer(Modifier.width(12.dp))
            Text(
              chat.chatInfo.displayName,
              Modifier.weight(1f),
              color = MaterialTheme.colors.onBackground,
              maxLines = 1
            )
            Checkbox(
              checked = isTrusted,
              onCheckedChange = { TrustedContacts.setTrusted(contact, it) },
              colors = CheckboxDefaults.colors(checkedColor = SimplexGreen)
            )
          }
        }
      }
    }
    SectionBottomSpacer()
  }
}
