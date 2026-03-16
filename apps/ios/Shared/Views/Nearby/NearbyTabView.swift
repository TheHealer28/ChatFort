//
//  NearbyTabView.swift
//  Inqalaab (iOS)
//
//  Dedicated Nearby P2P tab — gives local network communication
//  its own top-level navigation position, reinforcing Inqalaab's
//  identity as a resilience communication tool.
//

import SwiftUI
import InqalaabChat

struct NearbyTabView: View {
    @EnvironmentObject var nearbyModel: NearbyModel
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if nearbyModel.nearbyMode {
                    NearbyPeerListView()
                } else {
                    nearbyOffState
                }
            }
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Toggle(isOn: $nearbyModel.nearbyMode) {
                        Text(nearbyModel.nearbyMode ? "Active" : "Off")
                    }
                    .toggleStyle(.switch)
                    .tint(InqalaabGreen)
                }
            }
        }
    }

    /// View shown when Nearby mode is not active
    private var nearbyOffState: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(InqalaabGreen.opacity(0.1))
                    .frame(width: 120, height: 120)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 44))
                    .foregroundColor(InqalaabGreen)
            }

            VStack(spacing: 8) {
                Text("Offline Communication")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Connect directly with nearby Inqalaab users via Bluetooth and WiFi — no internet needed.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            // Feature cards
            VStack(spacing: 12) {
                featureCard(icon: "wifi.slash", title: "No Internet Required", detail: "Works during shutdowns & blackouts")
                featureCard(icon: "lock.shield.fill", title: "Encrypted P2P", detail: "All messages are encrypted end-to-end")
                featureCard(icon: "person.2.fill", title: "Auto-Discovery", detail: "Finds nearby users automatically")
                featureCard(icon: "bolt.fill", title: "Instant Setup", detail: "Enable the toggle above to start")
            }
            .padding(.horizontal, 24)

            Spacer()

            // Enable button
            Button {
                nearbyModel.nearbyMode = true
            } label: {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("Enable Nearby Mode")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(InqalaabGreen)
                .foregroundColor(.white)
                .cornerRadius(14)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func featureCard(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(InqalaabGreen)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.appColors.receivedMessage))
    }
}
