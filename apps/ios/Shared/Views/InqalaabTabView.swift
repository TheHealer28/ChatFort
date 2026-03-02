//
//  InqalaabTabView.swift
//  Inqalaab (iOS)
//
//  Main tab bar navigation — structurally different from SimpleX Chat.
//  Three tabs: Chats, Safety Hub, Settings
//

import SwiftUI
import SimpleXChat

struct InqalaabTabView: View {
    @Binding var activeUserPickerSheet: UserPickerSheet?
    @EnvironmentObject var theme: AppTheme
    @StateObject private var nearbyModel = NearbyModel.shared
    @State private var selectedTab = 0
    // Inqalaab: Observe language preference for immediate locale switching
    @AppStorage("inqalaab_selected_language") private var selectedLanguage: String = "en"

    var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 1: Chats (with WiFi/Nearby toggle)
            ChatListView(activeUserPickerSheet: $activeUserPickerSheet)
                .tabItem {
                    Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(0)

            // Tab 2: Safety Hub (UNIQUE to Inqalaab — does not exist in SimpleX)
            SafetyHubView()
                .tabItem {
                    Label("Safety Hub", systemImage: "shield.checkered")
                }
                .tag(1)

            // Tab 3: Settings
            NavigationView {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(2)
        }
        .environmentObject(nearbyModel)
        .accentColor(theme.colors.primary)
        // Inqalaab: Apply locale override so all SwiftUI Text() views
        // with LocalizedStringKey immediately reflect the selected language
        .environment(\.locale, Locale(identifier: selectedLanguage))
    }
}
