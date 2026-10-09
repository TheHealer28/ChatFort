//
//  InqalaabTabView.swift
//  Inqalaab (iOS)
//
//  Main tab bar navigation — 5-tab structure unique to Inqalaab.
//  Safety | Nearby | Alerts | Chats | Settings
//
//  This structure positions Inqalaab as a safety/resilience tool,
//  not a messenger clone. Messaging is one tab among several
//  operational security features.
//

import SwiftUI
import InqalaabChat

extension Notification.Name {
    static let inqalaabOpenChatsTab = Notification.Name("inqalaabOpenChatsTab")
}

struct InqalaabTabView: View {
    @Binding var activeUserPickerSheet: UserPickerSheet?
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var chatModel: ChatModel
    @StateObject private var nearbyModel = NearbyModel.shared
    @ObservedObject private var groupCallCoordinator = GroupCallCoordinator.shared
    @State private var selectedTab = 3
    // Inqalaab: Observe language preference for immediate locale switching
    @AppStorage("inqalaab_selected_language") private var selectedLanguage: String = "en"

    var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 0: Protection
            SafetyHubView()
                .tabItem {
                    Label("Protection", systemImage: "shield.checkered")
                }
                .tag(0)

            // Tab 1: Nearby P2P (offline communication)
            NearbyTabView()
                .tabItem {
                    Label("Nearby", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(1)

            // Tab 2: Alerts (emergency broadcasts & check-ins)
            AlertsView()
                .tabItem {
                    Label("Alerts", systemImage: "light.beacon.max.fill")
                }
                .tag(2)

            // Tab 3: Chats (DEFAULT — landing screen)
            ChatListView(activeUserPickerSheet: $activeUserPickerSheet)
                .tabItem {
                    Label("Chats", systemImage: "ellipsis.message.fill")
                }
                .tag(3)

            // Tab 4: Settings
            NavigationView {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(4)
        }
        .environmentObject(nearbyModel)
        .tint(InqalaabGreen)
        // Inqalaab: group calls (flag-gated; renders nothing unless one is
        // pending/active). One cover serves both the in-app ring (non-CallKit
        // consent) and the full call screen; the compact panel shows when the
        // call screen is collapsed.
        .overlay(alignment: .bottom) {
            GroupCallPanel()
                .padding(.bottom, 56)
        }
        .fullScreenCover(isPresented: groupCallCoverBinding) {
            if groupCallCoordinator.pendingIncomingCall != nil {
                IncomingGroupCallView()
            } else {
                GroupCallScreen()
            }
        }
        // Snap to Chats tab whenever a chat is opened — notification taps,
        // call invitations, contact requests all set chatModel.chatId, and
        // navigation only renders if the Chats tab is the active one.
        .onChange(of: chatModel.chatId) { newId in
            if newId != nil && selectedTab != 3 {
                selectedTab = 3
            }
        }
        // Contact-request notification taps don't set chatId (the request UI
        // is local in the chat list, not pushed onto NavigationStack), so
        // NtfManager posts this instead — just bring the user to Chats.
        .onReceive(NotificationCenter.default.publisher(for: .inqalaabOpenChatsTab)) { _ in
            if selectedTab != 3 {
                selectedTab = 3
            }
        }
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            appearance.shadowColor = UIColor(InqalaabGreen)
            UITabBar.appearance().scrollEdgeAppearance = appearance
            UITabBar.appearance().standardAppearance = appearance
        }
        // Inqalaab: Apply locale override so all SwiftUI Text() views
        // with LocalizedStringKey immediately reflect the selected language
        .environment(\.locale, Locale(identifier: selectedLanguage))
    }

    /// Present the cover while ringing (in-app consent path — CallKit rings via
    /// the system UI instead) or while an uncollapsed call is active.
    private var groupCallCoverBinding: Binding<Bool> {
        Binding(
            get: {
                // Group calls don't use CallKit, so the in-app ring always shows.
                (groupCallCoordinator.pendingIncomingCall != nil && !GroupCallCoordinator.usesCallKit)
                    || (groupCallCoordinator.activeGroupCall != nil && !groupCallCoordinator.callViewCollapsed)
            },
            set: { shown in
                if !shown && groupCallCoordinator.activeGroupCall != nil {
                    groupCallCoordinator.callViewCollapsed = true
                }
            }
        )
    }
}
