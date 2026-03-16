//
//  InqalaabSecurityPledgeView.swift
//  Inqalaab (iOS)
//
//  Security pledge screen — unique to Inqalaab.
//  Does not exist in SimpleX Chat.
//

import SwiftUI
import InqalaabChat

struct InqalaabSecurityPledgeView: View {
    @State private var createProfileActive = false

    var body: some View {
        GeometryReader { g in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 50)

                    // Shield icon
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 56))
                        .foregroundColor(.green)
                        .padding(.bottom, 16)

                    Text("Your Security Pledge")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.bottom, 8)

                    Text("We make these promises to you:")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.6))

                    Spacer().frame(height: 36)

                    // Pledge items
                    VStack(alignment: .leading, spacing: 20) {
                        pledgeRow(
                            number: "1",
                            title: "Zero data collection",
                            detail: "We collect nothing. No analytics, no telemetry, no usage data. Ever."
                        )
                        pledgeRow(
                            number: "2",
                            title: "No phone number required",
                            detail: "Your identity stays hidden. Connect via QR codes and links only."
                        )
                        pledgeRow(
                            number: "3",
                            title: "Panic mode for emergencies",
                            detail: "Wipe all data instantly if you're ever in danger. One shake is all it takes."
                        )
                        pledgeRow(
                            number: "4",
                            title: "Community-run servers",
                            detail: "Your messages route through independent servers that no government controls."
                        )
                        pledgeRow(
                            number: "5",
                            title: "Open source & auditable",
                            detail: "Our code is public. Anyone can verify we keep these promises."
                        )
                    }
                    .padding(.horizontal, 30)

                    Spacer().frame(height: 48)

                    // Create profile button
                    ZStack {
                        Button {
                            createProfileActive = true
                        } label: {
                            Text("I understand — Create my profile")
                        }
                        .buttonStyle(OnboardingButtonStyle(isDisabled: false))

                        NavigationLink(isActive: $createProfileActive) {
                            CreateFirstProfile()
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
                    colors: [InqalaabAmber.opacity(0.05), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 350
                )
            }
            .ignoresSafeArea()
        )
        .navigationBarHidden(true)
    }

    private func pledgeRow(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(InqalaabGreen)
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
