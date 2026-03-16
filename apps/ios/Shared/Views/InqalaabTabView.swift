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

struct InqalaabTabView: View {
    @Binding var activeUserPickerSheet: UserPickerSheet?
    @EnvironmentObject var theme: AppTheme
    @StateObject private var nearbyModel = NearbyModel.shared
    @State private var selectedTab = 0
    // Inqalaab: Observe language preference for immediate locale switching
    @AppStorage("inqalaab_selected_language") private var selectedLanguage: String = "en"

    var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 0: Protection (DEFAULT — landing screen)
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

            // Tab 3: Chats (messaging — secondary, not primary)
            ChatListView(activeUserPickerSheet: $activeUserPickerSheet)
                .tabItem {
                    Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
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
}
