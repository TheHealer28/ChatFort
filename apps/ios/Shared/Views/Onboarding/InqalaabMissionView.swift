//
//  InqalaabMissionView.swift
//  Inqalaab (iOS)
//
//  Mission statement screen — unique to Inqalaab.
//  Does not exist in SimpleX Chat.
//

import SwiftUI
import SimpleXChat

struct InqalaabMissionView: View {
    @State private var securityPledgeActive = false

    var body: some View {
        GeometryReader { g in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 50)

                    // Mission header
                    Image(systemName: "megaphone.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                        .padding(.bottom, 16)

                    Text("Our Mission")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.bottom, 8)

                    Text("Inqalaab exists because secure communication is a fundamental right — especially for those who risk everything to speak truth to power.")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)

                    Spacer().frame(height: 40)

                    // Values
                    VStack(alignment: .leading, spacing: 24) {
                        missionValueRow(
                            icon: "person.3.fill",
                            color: .green,
                            title: "For the people",
                            detail: "Built by activists, for activists. No corporation, no profit motive — just the mission."
                        )
                        missionValueRow(
                            icon: "lock.shield.fill",
                            color: .orange,
                            title: "Unbreakable privacy",
                            detail: "End-to-end encryption with no central server that can be compromised or ordered to hand over data."
                        )
                        missionValueRow(
                            icon: "globe.asia.australia.fill",
                            color: .cyan,
                            title: "Beyond borders",
                            detail: "Servers hosted independently, outside the reach of any single government or surveillance apparatus."
                        )
                        missionValueRow(
                            icon: "heart.fill",
                            color: .red,
                            title: "Solidarity",
                            detail: "When they shut down the internet, when they monitor the networks — we find another way."
                        )
                    }
                    .padding(.horizontal, 30)

                    Spacer().frame(height: 48)

                    // Continue button
                    ZStack {
                        Button {
                            securityPledgeActive = true
                        } label: {
                            Text("Continue")
                        }
                        .buttonStyle(OnboardingButtonStyle(isDisabled: false))

                        NavigationLink(isActive: $securityPledgeActive) {
                            InqalaabSecurityPledgeView()
                                .modifier(ThemedBackground())
                        } label: {
                            EmptyView()
                        }
                        .frame(width: 1, height: 1)
                        .hidden()
                    }
                    .padding(.horizontal, 25)

                    Spacer().frame(height: 30)
                }
                .frame(minHeight: g.size.height)
            }
        }
        .frame(maxHeight: .infinity)
        .background(
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.043, green: 0.102, blue: 0.071), Color(red: 0.02, green: 0.02, blue: 0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [InqalaabTeal.opacity(0.06), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 350
                )
            }
            .ignoresSafeArea()
        )
        .navigationBarHidden(true)
    }

    private func missionValueRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(detail)
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
