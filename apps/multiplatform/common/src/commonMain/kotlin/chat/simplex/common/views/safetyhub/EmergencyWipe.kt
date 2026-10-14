package chat.simplex.common.views.safetyhub

import chat.simplex.common.model.ChatModel
import chat.simplex.common.model.Profile
import chat.simplex.common.platform.Log
import chat.simplex.common.platform.chatCloseStore
import chat.simplex.common.platform.ntfManager
import chat.simplex.common.views.database.deleteChatDatabaseFilesAndState
import chat.simplex.common.views.database.stopChatAsync
import chat.simplex.common.views.helpers.DatabaseUtils.ksAppPassword
import chat.simplex.common.views.helpers.DatabaseUtils.ksSelfDestructPassword
import chat.simplex.common.views.localauth.reinitChatController
import chat.simplex.common.views.onboarding.OnboardingStage
import kotlinx.coroutines.delay

/**
 * Platform-specific callback to reset server config prefs before reinit.
 */
var onEmergencyWipeResetConfig: (() -> Unit)? = null

/**
 * Platform-specific callback to reconfigure servers after wipe and chat restart.
 */
var onEmergencyWipeReconfigure: (() -> Unit)? = null

/**
 * Performs a complete emergency wipe of all app data.
 * This is shared between SafetyHubView and EmergencyWipeConfirmActivity
 * to avoid code duplication.
 *
 * Steps:
 * 1. Wait for any initialization in progress
 * 2. Stop the chat service
 * 3. Close the database store
 * 4. Delete all database files and state
 * 5. Clear self-destruct and passcode credentials
 * 6. Cancel all notifications
 * 7. Reinitialize with empty database
 * 8. Create decoy empty profile
 */
/** Set by the Android app to also erase the crowd mesh (identity keys, messages, nickname). */
var platformEmergencyWipe: (() -> Unit)? = null

suspend fun performEmergencyWipe() {
    val m = ChatModel
    try {
        platformEmergencyWipe?.invoke()
    } catch (e: Exception) {
        Log.e("EmergencyWipe", "Crowd mesh wipe failed: ${e.message}")
    }
    try {
        // Wait for any init in progress
        while (m.ctrlInitInProgress.value) {
            delay(50)
        }
        if (m.chatRunning.value == true) {
            stopChatAsync(m)
        }
        val ctrl: Long? = m.controller.getChatCtrl()
        if (ctrl != null && ctrl != -1L) {
            chatCloseStore(ctrl)
        }
        deleteChatDatabaseFilesAndState()

        // Clear self-destruct and passcode state
        ksAppPassword.remove()
        ksSelfDestructPassword.remove()
        m.controller.appPrefs.selfDestruct.set(false)
        m.controller.appPrefs.selfDestructDisplayName.set(null)

        // Reset Inqalaab server config prefs so reconfiguration happens after reinit
        onEmergencyWipeResetConfig?.invoke()

        // Cancel all notifications
        ntfManager.cancelAllNotifications()

        // Reinitialize with empty database
        reinitChatController()

        // Create empty decoy profile
        if (m.currentUser.value == null) {
            val createdUser = m.controller.apiCreateActiveUser(
                null,
                Profile(displayName = "User", fullName = "", shortDescr = null),
                pastTimestamp = true
            )
            m.currentUser.value = createdUser
            m.controller.appPrefs.onboardingStage.set(OnboardingStage.OnboardingComplete)
            if (createdUser != null) {
                m.controller.startChat(createdUser)
            }
        }

        // Trigger Inqalaab server reconfiguration now that chat is running again
        onEmergencyWipeReconfigure?.invoke()

        Log.d("EmergencyWipe", "Wipe completed successfully")
    } catch (e: Exception) {
        Log.e("EmergencyWipe", "Wipe failed: ${e.stackTraceToString()}")
    }
}
