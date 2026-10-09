//
//  InqalaabApp.swift
//  Shared
//
//  Created by Evgeny Poberezkin on 17/01/2022.
//

import SwiftUI
import OSLog
import InqalaabChat

let logger = Logger()

@main
struct InqalaabApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var chatModel = ChatModel.shared
    @ObservedObject var alertManager = AlertManager.shared

    @Environment(\.scenePhase) var scenePhase
    @State private var enteredBackgroundAuthenticated: TimeInterval? = nil

    init() {
        DispatchQueue.global(qos: .background).sync {
            haskell_init()
//            hs_init(0, nil)
        }
        UserDefaults.standard.register(defaults: appDefaults)
        setGroupDefaults()
        registerGroupDefaults()
        setDbContainer()
        cleanStaleDatabase()
        BGManager.shared.register()
        NtfManager.shared.registerCategories()
        // Inqalaab: Start shake detector for panic mode
        InqalaabShakeDetector.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            // contentAccessAuthenticationExtended has to be passed to ContentView on view initialization,
            // so that it's computed by the time view renders, and not on event after rendering
            ContentView(contentAccessAuthenticationExtended: !authenticationExpired())
                // Inqalaab: on wide screens (iPhone Duo unfolded) NavigationView defaults to two
                // columns, which put every screen in a narrow left column with an empty right side.
                // One full-width column, as on every iPhone. Applies to all NavigationViews below.
                .navigationViewStyle(.stack)
                .environmentObject(chatModel)
                .environmentObject(AppTheme.shared)
                .onOpenURL { url in
                    logger.debug("ContentView.onOpenURL: \(url)")
                    if AppChatState.shared.value == .active {
                        chatModel.appOpenUrl = url
                    } else {
                        chatModel.appOpenUrlLater = url
                    }
                }
                .onAppear() {
                    // Inqalaab: seed screen-protection redaction state from the CURRENT scene phase.
                    // `.onChange(of: scenePhase)` only fires on a *transition*; when the app launches
                    // straight into .active, onChange never fires and AppSheetState.scenePhaseActive
                    // stays at its default `false` — which, with "Protect app screen" enabled, leaves
                    // the whole UI stuck as a redacted placeholder skeleton. Seeding it here clears
                    // that launch race. The existing onChange still handles foreground↔background.
                    AppSheetState.shared.scenePhaseActive = scenePhase == .active
                    // Present screen for continue migration if it wasn't finished yet
                    if chatModel.migrationState != nil {
                        // It's important, otherwise, user may be locked in undefined state
                        onboardingStageDefault.set(.step1_InqalaabInfo)
                        chatModel.onboardingStage = onboardingStageDefault.get()
                    } else if kcAppPassword.get() == nil || kcSelfDestructPassword.get() == nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            initChatAndMigrate()
                        }
                    }
                }
                .onChange(of: scenePhase) { phase in
                    logger.debug("scenePhase was \(String(describing: scenePhase)), now \(String(describing: phase))")
                    AppSheetState.shared.scenePhaseActive = phase == .active
                    switch (phase) {
                    case .background:
                        // --- authentication
                        // see ContentView .onChange(of: scenePhase) for remaining authentication logic
                        if chatModel.contentViewAccessAuthenticated {
                            enteredBackgroundAuthenticated = ProcessInfo.processInfo.systemUptime
                        }
                        chatModel.contentViewAccessAuthenticated = false
                        // authentication ---

                        if CallController.useCallKit() && chatModel.activeCall != nil {
                            CallController.shared.shouldSuspendChat = true
                        } else {
                            suspendChat()
                            BGManager.shared.schedule()
                        }
                        NtfManager.shared.setNtfBadgeCount(chatModel.totalUnreadCountForAllUsers())
                    case .active:
                        CallController.shared.shouldSuspendChat = false
                        let appState = AppChatState.shared.value

                        if appState != .stopped {
                            startChatAndActivate {
                                if chatModel.chatRunning == true {
                                    // Defer and debounce server setup so first launch can render quickly.
                                    InqalaabServers.shared.scheduleConfigureIfNeeded(reason: "app became active")
                                    NtfManager.shared.processPendingNtfResponseIfReady()
                                    // Ring a group call whose start arrived while the app was
                                    // killed (persisted by the NSE handoff).
                                    GroupCallCoordinator.shared.checkPersistedGroupCallStart()
                                    if appState.inactive {
                                        Task {
                                            await updateChats()
                                            if !chatModel.showCallView && !CallController.shared.hasActiveCalls() {
                                                await updateCallInvitations()
                                            }
                                            if let url = chatModel.appOpenUrlLater {
                                                await MainActor.run {
                                                    chatModel.appOpenUrlLater = nil
                                                    chatModel.appOpenUrl = url
                                                }
                                            }
                                        }
                                    } else if let url = chatModel.appOpenUrlLater {
                                        chatModel.appOpenUrlLater = nil
                                        chatModel.appOpenUrl = url
                                    }
                                }
                            }
                        }
                    default:
                        break
                    }
                }
        }
    }

    /// Delete stale database files left in the app group container from a previous install.
    /// iOS does not always clean app group containers when the app is deleted and reinstalled.
    private func cleanStaleDatabase() {
        let key = "inqalaab_db_initialized_build"
        let lastBuild = UserDefaults.standard.string(forKey: key)
        let fm = FileManager.default
        if lastBuild == nil {
            // First launch after install — clean any stale files from app group container
            // including SQLite WAL/SHM files that deleteAppDatabaseAndFiles() misses
            let dbPath = getAppDatabasePath().path
            for suffix in ["_chat.db", "_agent.db", "_chat.db.bak", "_agent.db.bak",
                           "_chat.db-wal", "_agent.db-wal", "_chat.db-shm", "_agent.db-shm"] {
                try? fm.removeItem(atPath: dbPath + suffix)
            }
            logger.debug("Inqalaab: cleaned stale database files from app group container")
        }
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        UserDefaults.standard.set(currentBuild, forKey: key)
    }

    private func setDbContainer() {
// Uncomment and run once to open DB in app documents folder:
//         dbContainerGroupDefault.set(.documents)
//         v3DBMigrationDefault.set(.offer)
// to create database in app documents folder also uncomment:
//         let legacyDatabase = true
        let legacyDatabase = hasLegacyDatabase()
        if legacyDatabase, case .documents = dbContainerGroupDefault.get() {
            dbContainerGroupDefault.set(.documents)
            setMigrationState(.offer)
            logger.debug("InqalaabApp init: using legacy DB in documents folder: \(getAppDatabasePath())*.db")
        } else {
            dbContainerGroupDefault.set(.group)
            setMigrationState(.ready)
            logger.debug("InqalaabApp init: using DB in app group container: \(getAppDatabasePath())*.db")
            logger.debug("InqalaabApp init: legacy DB\(legacyDatabase ? "" : " not") present")
        }
    }

    private func setMigrationState(_ state: V3DBMigrationState) {
        if case .migrated = v3DBMigrationDefault.get() { return }
        v3DBMigrationDefault.set(state)
    }

    private func authenticationExpired() -> Bool {
        if let enteredBackgroundAuthenticated = enteredBackgroundAuthenticated {
            let delay = Double(UserDefaults.standard.integer(forKey: DEFAULT_LA_LOCK_DELAY))
            return ProcessInfo.processInfo.systemUptime - enteredBackgroundAuthenticated >= delay
        } else {
            return true
        }
    }

    private func updateChats() async {
        do {
            let chats = try await apiGetChatsAsync()
            await MainActor.run {
                chatModel.updateChats(chats)
                MeshLinkBridge.refresh()
            }
            if let id = chatModel.chatId,
               let chat = chatModel.getChat(id),
               !NtfManager.shared.navigatingToChat {
                Task { await loadChat(chat: chat, im: ItemsModel.shared, clearItems: false) }
            }
            if let ncr = chatModel.ntfContactRequest {
                await MainActor.run { chatModel.ntfContactRequest = nil }
                if case let .contactRequest(contactRequest) = chatModel.getChat(ncr.chatId)?.chatInfo {
                    Task { await acceptContactRequest(incognito: false, contactRequestId: contactRequest.apiId) }
                }
            }
        } catch let error {
            logger.error("apiGetChats: cannot update chats \(responseError(error))")
        }
    }

    private func updateCallInvitations() async {
        do {
            try await refreshCallInvitations()
        } catch let error {
            logger.error("apiGetCallInvitations: cannot update call invitations \(responseError(error))")
        }
    }
}
