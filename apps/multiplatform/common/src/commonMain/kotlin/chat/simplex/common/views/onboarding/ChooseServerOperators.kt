package chat.simplex.common.views.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import chat.simplex.common.model.*
import chat.simplex.common.model.ChatController.appPrefs
import chat.simplex.common.platform.*
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.helpers.*

@Composable
fun ModalData.OnboardingConditionsView() {
    LaunchedEffect(Unit) {
        prepareChatBeforeFinishingOnboarding()
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colors.background),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(32.dp)
        ) {
            CircularProgressIndicator(
                color = MaterialTheme.colors.primary,
                strokeWidth = 3.dp
            )
            Spacer(modifier = Modifier.height(24.dp))
            Text(
                "ChatFort",
                style = MaterialTheme.typography.h4,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colors.primary
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                "Setting up secure messaging...",
                style = MaterialTheme.typography.body1,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colors.onBackground.copy(alpha = 0.7f)
            )
        }
    }

    val conditions by remember { chatModel.conditions }
    LaunchedEffect(conditions.serverOperators) {
        val operators = conditions.serverOperators
        if (operators.isEmpty()) return@LaunchedEffect

        println("ChatFort: ${operators.size} operators loaded")

        withBGApi {
            try {
                val rh = chatModel.remoteHostId()
                val allOperatorIds = operators.map { it.operatorId }
                val conditionsId = conditions.currentConditions.conditionsId

                // Accept conditions
                val acceptResult = chatController.acceptConditions(rh, conditionsId = conditionsId, operatorIds = allOperatorIds)
                if (acceptResult != null) {
                    chatModel.conditions.value = acceptResult
                    println("ChatFort: Conditions accepted")

                    // Enable operators so preset servers get created in DB
                    val enabledOps = prepareEnabledOperators(acceptResult.serverOperators, allOperatorIds.toSet())
                    if (enabledOps != null) {
                        val setOpsResult = chatController.setServerOperators(rh = rh, operators = enabledOps)
                        if (setOpsResult != null) {
                            chatModel.conditions.value = setOpsResult
                            println("ChatFort: Operators enabled")
                        }
                    }
                }
            } catch (e: Exception) {
                println("ChatFort: Onboarding error: ${e.message}")
            }

            // Advance to next screen
            println("ChatFort: Advancing to notifications")
            appPrefs.onboardingStage.set(OnboardingStage.Step4_SetNotificationsMode)
        }
    }
}

private fun prepareEnabledOperators(operators: List<ServerOperator>, selectedIds: Set<Long>): List<ServerOperator>? {
    val ops = ArrayList(operators)
    if (ops.isEmpty()) return null
    for (i in ops.indices) {
        ops[i] = ops[i].copy(enabled = selectedIds.contains(ops[i].operatorId))
    }
    val haveSMPStorage = ops.any { it.enabled && it.smpRoles.storage }
    val haveSMPProxy = ops.any { it.enabled && it.smpRoles.proxy }
    val haveXFTPStorage = ops.any { it.enabled && it.xftpRoles.storage }
    val haveXFTPProxy = ops.any { it.enabled && it.xftpRoles.proxy }
    val firstEnabledIndex = ops.indexOfFirst { it.enabled }
    if (haveSMPStorage && haveSMPProxy && haveXFTPStorage && haveXFTPProxy) return ops
    if (firstEnabledIndex != -1) {
        var op = ops[firstEnabledIndex]
        if (!haveSMPStorage) op = op.copy(smpRoles = op.smpRoles.copy(storage = true))
        if (!haveSMPProxy) op = op.copy(smpRoles = op.smpRoles.copy(proxy = true))
        if (!haveXFTPStorage) op = op.copy(xftpRoles = op.xftpRoles.copy(storage = true))
        if (!haveXFTPProxy) op = op.copy(xftpRoles = op.xftpRoles.copy(proxy = true))
        ops[firstEnabledIndex] = op
        return ops
    }
    return null
}