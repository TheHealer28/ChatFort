import SwiftUI

/// Empty state view shown when Nearby mode is active but no peers are found.
struct NearbyEmptyState: View {
    @EnvironmentObject var nearbyModel: NearbyModel
    @EnvironmentObject var theme: AppTheme
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Animated radio wave icon
            ZStack {
                Circle()
                    .stroke(theme.colors.primary.opacity(0.2), lineWidth: 2)
                    .frame(width: 120, height: 120)
                    .scaleEffect(isAnimating ? 1.3 : 1.0)
                    .opacity(isAnimating ? 0 : 0.5)

                Circle()
                    .stroke(theme.colors.primary.opacity(0.3), lineWidth: 2)
                    .frame(width: 80, height: 80)
                    .scaleEffect(isAnimating ? 1.4 : 1.0)
                    .opacity(isAnimating ? 0 : 0.7)

                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 40))
                    .foregroundColor(theme.colors.primary)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }

            VStack(spacing: 8) {
                if nearbyModel.isSearching {
                    Text("Searching for nearby peers...")
                        .font(.headline)
                        .foregroundColor(theme.colors.onBackground)
                } else {
                    Text("Nearby Mode")
                        .font(.headline)
                        .foregroundColor(theme.colors.onBackground)
                }

                Text("Other Inqalaab users nearby will appear here. Both devices must have Nearby mode enabled.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .foregroundColor(theme.colors.primary)
                        .frame(width: 24)
                    Text("Works without internet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .foregroundColor(theme.colors.primary)
                        .frame(width: 24)
                    Text("Encrypted peer-to-peer")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 12) {
                    Image(systemName: "person.2")
                        .foregroundColor(theme.colors.primary)
                        .frame(width: 24)
                    Text("Connects via Bluetooth & WiFi")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 8)

            Spacer()
            Spacer()
        }
    }
}
