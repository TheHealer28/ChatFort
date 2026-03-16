import SwiftUI
import InqalaabChat

/// Segmented control to toggle between WiFi (server) and Nearby (P2P) modes.
/// Placed at the top of the Chats tab.
struct NearbyModeToggle: View {
    @EnvironmentObject var nearbyModel: NearbyModel
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        Picker("Mode", selection: $nearbyModel.nearbyMode) {
            Label("WiFi", systemImage: "wifi")
                .tag(false)
            Label("Nearby", systemImage: "antenna.radiowaves.left.and.right")
                .tag(true)
        }
        .pickerStyle(.segmented)
        .tint(InqalaabGreen)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
