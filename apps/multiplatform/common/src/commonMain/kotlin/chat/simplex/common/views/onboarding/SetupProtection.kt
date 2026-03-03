package chat.simplex.common.views.onboarding

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import chat.simplex.common.model.ChatModel
import chat.simplex.common.model.ChatController.appPrefs
import chat.simplex.common.platform.*
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.helpers.*
import chat.simplex.common.views.helpers.DatabaseUtils.ksAppPassword
import chat.simplex.common.views.helpers.DatabaseUtils.ksSelfDestructPassword
import chat.simplex.common.views.localauth.SetAppPasscodeView
import chat.simplex.common.views.usersettings.LAMode
import chat.simplex.res.MR

@Composable
fun SetupProtection(chatModel: ChatModel) {
  val appPasscodeSet = remember { mutableStateOf(ksAppPassword.get() != null) }
  val selfDestructSet = remember { mutableStateOf(appPrefs.selfDestruct.get()) }

  CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler()) {
    ModalView({}, showClose = false) {
      ColumnWithScrollBar(
        Modifier.themedBackground(
          bgLayerSize = LocalAppBarHandler.current?.backgroundGraphicsLayerSize,
          bgLayer = LocalAppBarHandler.current?.backgroundGraphicsLayer
        ),
        horizontalAlignment = Alignment.CenterHorizontally
      ) {
        Box(Modifier.align(Alignment.CenterHorizontally)) {
          AppBarTitle(stringResource(MR.strings.setup_protection_title), bottomPadding = DEFAULT_PADDING)
        }

        Text(
          stringResource(MR.strings.setup_protection_description),
          Modifier.padding(horizontal = DEFAULT_ONBOARDING_HORIZONTAL_PADDING),
          style = MaterialTheme.typography.body1,
          color = MaterialTheme.colors.secondary,
          textAlign = TextAlign.Center,
          lineHeight = 22.sp
        )

        Spacer(Modifier.weight(1f))

        Column(Modifier.padding(horizontal = DEFAULT_ONBOARDING_HORIZONTAL_PADDING)) {
          // Set app passcode button
          ProtectionOptionCard(
            title = stringResource(MR.strings.setup_app_passcode),
            description = stringResource(MR.strings.setup_app_passcode_desc),
            done = appPasscodeSet.value,
            enabled = true,
            onClick = {
              ModalManager.fullscreen.showCustomModal { close ->
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colors.background, contentColor = LocalContentColor.current) {
                  SetAppPasscodeView(
                    passcodeKeychain = ksAppPassword,
                    prohibitedPasscodeKeychain = ksSelfDestructPassword,
                    title = generalGetString(MR.strings.set_passcode),
                    submit = {
                      appPrefs.performLA.set(true)
                      appPrefs.laMode.set(LAMode.PASSCODE)
                      appPasscodeSet.value = true
                    },
                    cancel = {},
                    close = close
                  )
                }
              }
            }
          )

          Spacer(Modifier.height(14.dp))

          // Set emergency (self-destruct) code button
          ProtectionOptionCard(
            title = stringResource(MR.strings.setup_emergency_code),
            description = if (appPasscodeSet.value) {
              stringResource(MR.strings.setup_emergency_code_desc)
            } else {
              stringResource(MR.strings.setup_emergency_code_requires_passcode)
            },
            done = selfDestructSet.value,
            enabled = appPasscodeSet.value,
            onClick = {
              ModalManager.fullscreen.showCustomModal { close ->
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colors.background, contentColor = LocalContentColor.current) {
                  SetAppPasscodeView(
                    passcodeKeychain = ksSelfDestructPassword,
                    prohibitedPasscodeKeychain = ksAppPassword,
                    title = generalGetString(MR.strings.set_passcode),
                    reason = generalGetString(MR.strings.enabled_self_destruct_passcode),
                    submit = {
                      appPrefs.selfDestruct.set(true)
                      selfDestructSet.value = true
                      AlertManager.shared.showAlertMsg(
                        generalGetString(MR.strings.self_destruct_passcode_enabled),
                        generalGetString(MR.strings.if_you_enter_passcode_data_removed)
                      )
                    },
                    cancel = {},
                    close = close
                  )
                }
              }
            }
          )
        }

        Spacer(Modifier.weight(1f))

        Column(
          Modifier.widthIn(max = if (appPlatform.isAndroid) 450.dp else 1000.dp).align(Alignment.CenterHorizontally),
          horizontalAlignment = Alignment.CenterHorizontally
        ) {
          OnboardingActionButton(
            modifier = if (appPlatform.isAndroid) Modifier.padding(horizontal = DEFAULT_ONBOARDING_HORIZONTAL_PADDING).fillMaxWidth() else Modifier,
            labelId = MR.strings.setup_protection_continue,
            onboarding = OnboardingStage.OnboardingComplete,
            onclick = {
              ModalManager.fullscreen.closeModals()
            }
          )
          TextButtonBelowOnboardingButton("", null)
        }
      }
    }
  }
}

@Composable
private fun ProtectionOptionCard(
  title: String,
  description: String,
  done: Boolean,
  enabled: Boolean,
  onClick: () -> Unit
) {
  val borderColor = when {
    done -> MaterialTheme.colors.primary
    !enabled -> MaterialTheme.colors.secondary.copy(alpha = 0.3f)
    else -> MaterialTheme.colors.secondary.copy(alpha = 0.5f)
  }
  val titleColor = when {
    done -> MaterialTheme.colors.primary
    !enabled -> MaterialTheme.colors.secondary.copy(alpha = 0.5f)
    else -> MaterialTheme.colors.onBackground
  }

  TextButton(
    onClick = onClick,
    enabled = enabled && !done,
    border = androidx.compose.foundation.BorderStroke(1.dp, borderColor),
    shape = RoundedCornerShape(35.dp),
  ) {
    Column(Modifier.padding(horizontal = 10.dp).padding(top = 4.dp, bottom = 8.dp).fillMaxWidth()) {
      Row(Modifier.align(Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
        if (done) {
          Icon(
            painterResource(MR.images.ic_check),
            contentDescription = null,
            Modifier.size(20.dp).padding(end = 4.dp),
            tint = MaterialTheme.colors.primary
          )
        }
        Text(
          title,
          style = MaterialTheme.typography.h3,
          fontWeight = FontWeight.Medium,
          color = titleColor,
          textAlign = TextAlign.Center
        )
      }
      Text(
        description,
        Modifier.align(Alignment.CenterHorizontally).padding(top = 8.dp),
        fontSize = 15.sp,
        color = if (enabled) MaterialTheme.colors.onBackground else MaterialTheme.colors.secondary.copy(alpha = 0.5f),
        lineHeight = 22.sp,
        textAlign = TextAlign.Center
      )
    }
  }
}
