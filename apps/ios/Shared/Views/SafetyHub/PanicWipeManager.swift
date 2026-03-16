//
//  PanicWipeManager.swift
//  Inqalaab (iOS)
//
//  Shared singleton for emergency data wipe — used by both the Safety Hub
//  "Emergency Wipe Now" button and the shake-trigger detector.
//

import Foundation
import SwiftUI
import InqalaabChat

class PanicWipeManager: ObservableObject {
    static let shared = PanicWipeManager()

    @Published var wipeInProgress = false
    @Published var panicTriggered = false

    private init() {}

    /// Full 12-step emergency wipe following the pattern from LocalAuthView.deleteStorageAndRestart().
    /// Safe to call from any thread — dispatches internally.
    func performPanicWipe() {
        DispatchQueue.main.async { [weak self] in
            self?._performPanicWipe()
        }
    }

    private func _performPanicWipe() {
        guard !wipeInProgress else {
            logger.debug("Inqalaab: Wipe already in progress, ignoring duplicate call")
            return
        }

        panicTriggered = true
        wipeInProgress = true

        // Step 1: Immediately wipe Nearby P2P data (sync, fast)
        NearbyModel.shared.clearAllData()

        Task {
            do {
                let m = ChatModel.shared

                // Step 2: Wait for chat initialization to finish
                while m.ctrlInitInProgress {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }

                // Step 3: Stop chat if running
                if m.chatRunning == true {
                    try await stopChatAsync()
                }

                // Step 4: Close the database store
                if m.chatInitialized {
                    chatCloseStore()
                }

                // Step 5: Delete all database files and app files from disk
                deleteAppDatabaseAndFiles()

                // Step 6: Clear sensitive in-memory UI state
                await MainActor.run {
                    m.chatId = nil
                    ItemsModel.shared.reversedChatItems = []
                    ItemsModel.shared.chatState.clear()
                    ChatModel.shared.secondaryIM?.reversedChatItems = []
                    ChatModel.shared.secondaryIM?.chatState.clear()
                    m.updateChats([])
                    m.users = []
                }

                // Step 7: Remove all pending notifications
                await NtfManager.shared.removeAllNotifications()

                // Step 8: Clear keychain credentials
                _ = kcDatabasePassword.remove()
                _ = kcAppPassword.remove()
                _ = kcSelfDestructPassword.remove()

                // Step 9: Reset and reinitialize chat controller
                await MainActor.run {
                    m.chatDbChanged = true
                    m.chatInitialized = false
                }
                resetChatCtrl()
                try initializeChat(start: true)

                await MainActor.run {
                    m.chatDbChanged = false
                }

                AppChatState.shared.set(.active)

                // Step 10: Create a fresh empty user profile
                if m.currentUser == nil && m.chatInitialized {
                    m.currentUser = try apiCreateActiveUser(nil, pastTimestamp: true)
                    onboardingStageDefault.set(.onboardingComplete)
                    m.onboardingStage = .onboardingComplete
                    try startChat()
                }

                // Step 11: Reset InqalaabServers flags so it fully reconfigures
                UserDefaults.standard.removeObject(forKey: "inqalaab_servers_configured")
                UserDefaults.standard.removeObject(forKey: "inqalaab_contacts_cleaned")
                UserDefaults.standard.removeObject(forKey: "inqalaab_address_created")

                // Step 12: Configure Inqalaab servers for the fresh profile
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    InqalaabServers.shared.configureIfNeeded()
                }

                await MainActor.run {
                    self.wipeInProgress = false
                }

                logger.info("Inqalaab: Panic wipe completed successfully")
            } catch {
                logger.error("Inqalaab: Panic wipe error: \(error)")
                await MainActor.run {
                    self.wipeInProgress = false
                    // Fallback: reset to onboarding so app can restart fresh
                    onboardingStageDefault.set(.step1_InqalaabInfo)
                    ChatModel.shared.chatDbChanged = true
                }
            }
        }
    }
}
