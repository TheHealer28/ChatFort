import SwiftUI

/// Segmented control to toggle between WiFi (server) and Nearby (P2P) modes.
/// Placed at the top of the Chats tab.
struct NearbyModeToggle: View {
    @EnvironmentObject var nearbyModel: NearbyModel
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        Picker("Mode", selection: $nearbyModel.nearbyMode) {
            Text("WiFi")
                .tag(false)
            Text("Nearby")
                .tag(true)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
