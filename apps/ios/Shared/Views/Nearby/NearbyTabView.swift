//
//  NearbyTabView.swift
//  Inqalaab (iOS)
//
//  The Nearby tab: the Crowd mesh (multi-hop, iPhone and Android), with the older iPhone-only
//  direct Nearby chat one tap away.
//

import SwiftUI
import InqalaabChat

/// The Nearby tab is the Crowd mesh itself: Start on the tab, then Everyone / Teams / People. The
/// older iPhone-only Nearby chat (Multipeer, one hop) is one tap away in the top-left corner.
struct NearbyTabView: View {
    var body: some View {
        NavigationView {
            CrowdMeshView()
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        NavigationLink {
                            NearbyDirectView()
                        } label: {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                        }
                        .accessibilityLabel(Text("Nearby iPhones"))
                    }
                }
        }
    }
}

/// The older Nearby: direct chat with iPhones right next to you (MultipeerConnectivity, one hop,
/// iPhone only, not private).
struct NearbyDirectView: View {
    @EnvironmentObject var nearbyModel: NearbyModel
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        VStack(spacing: 0) {
            Text("Chat directly with iPhones right next to you, without the crowd mesh.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            privacyWarning
            if nearbyModel.nearbyMode {
                nearbyStatusBanner
                NearbyPeerListView()
            } else {
                nearbyOffState
            }
        }
        .navigationTitle(Text("Nearby iPhones"))
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

    /// Status banner shown above the peer list while Nearby is active.
    /// Surfaces a hard start failure (e.g. Local Network permission denied) or,
    /// while nothing has connected yet, the checklist that resolves most
    /// "searching forever" cases — so the feature never fails silently.
    @ViewBuilder private var nearbyStatusBanner: some View {
        if let err = nearbyModel.lastError {
            banner(
                icon: "exclamationmark.triangle.fill",
                color: .orange,
                text: err
            )
        } else if !nearbyModel.hasConnectedPeer {
            banner(
                icon: "antenna.radiowaves.left.and.right",
                color: InqalaabGreen,
                text: NSLocalizedString("Searching for nearby devices… If none appear: turn on Local Network (Settings → Privacy & Security → Local Network), put both devices on the same Wi-Fi with Bluetooth on, and keep the app open on both.", comment: "nearby searching hint")
            )
        }
    }

    /// Same warning as Android's Nearby screen, worded for iOS (no rooms here):
    /// Multipeer links are encrypted but not authenticated, so a nearby attacker
    /// can impersonate a peer.
    private var privacyWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundColor(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nearby chats are NOT private: anyone close by with the right tools can pretend to be someone else and read what you send. Don't share names, locations or plans here.")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.red)
                Text(String.localizedStringWithFormat(NSLocalizedString("Others nearby see you as %@.", comment: "nearby alias hint"), nearbyModel.myNearbyName))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
    }

    private func banner(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
    }

    /// View shown when Nearby mode is not active
    private var nearbyOffState: some View {
        // Scrolls: with the privacy warning above it, this doesn't fit on smaller iPhones, and an
        // overflowing VStack pushes its top up under the navigation bar.
        ScrollView {
        VStack(spacing: 24) {

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

                Text("Connect directly with nearby ChatFort users via Bluetooth and WiFi — no internet needed.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            // Feature cards
            VStack(spacing: 12) {
                featureCard(icon: "wifi.slash", title: "No Internet Required", detail: "Works during shutdowns & blackouts")
                featureCard(icon: "lock.shield.fill", title: "Encrypted link", detail: "Traffic is encrypted — you approve who can message you")
                featureCard(icon: "person.2.fill", title: "Auto-Discovery", detail: "Finds nearby users automatically")
                featureCard(icon: "bolt.fill", title: "Instant Setup", detail: "Enable the toggle above to start")
            }
            .padding(.horizontal, 24)

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
        .padding(.top, 24)
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
