//
//  InqalaabInfo.swift → Inqalaab Welcome Screen
//  Inqalaab (iOS)
//
//  Completely redesigned from SimpleX Chat.
//  Mission-focused welcome screen for activists and journalists.
//

import SwiftUI
import InqalaabChat

struct InqalaabInfo: View {
    @EnvironmentObject var m: ChatModel
    @Environment(\.colorScheme) var colorScheme: ColorScheme
    @State private var createProfileNavLinkActive = false
    @State private var missionNavLinkActive = false
    var onboarding: Bool

    var body: some View {
        GeometryReader { g in
            let v = ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 60)

                    // Inqalaab Logo
                    Image(colorScheme == .light ? "logo" : "logo-light")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .shadow(color: InqalaabGreen.opacity(0.4), radius: 30, x: 0, y: 15)

                    Spacer().frame(height: 24)

                    // App Name
                    Text("Inqalaab")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    // Urdu subtitle
                    Text("انقلاب")
                        .font(.system(size: 28, weight: .medium, design: .serif))
                        .foregroundColor(InqalaabGreen)

                    Spacer().frame(height: 8)

                    Text("Secure Communication for All")
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)

                    Spacer().frame(height: 48)

                    // Feature highlights — different from SimpleX's
                    VStack(alignment: .leading, spacing: 20) {
                        inqalaabFeatureRow(
                            icon: "hand.raised.fill",
                            color: .green,
                            title: "Built for security",
                            detail: "Designed for those who value privacy and freedom"
                        )
                        inqalaabFeatureRow(
                            icon: "eye.slash.fill",
                            color: .orange,
                            title: "No surveillance possible",
                            detail: "No phone number, no tracking, no metadata collected"
                        )
                        inqalaabFeatureRow(
                            icon: "server.rack",
                            color: .cyan,
                            title: "Independent infrastructure",
                            detail: "Routed through community-run servers outside your country"
                        )
                    }
                    .padding(.horizontal, 30)

                    Spacer().frame(height: 48)

                    if onboarding {
                        VStack(spacing: 12) {
                            // Primary action: Continue to mission
                            ZStack {
                                Button {
                                    missionNavLinkActive = true
                                } label: {
                                    Text("Get Started")
                                }
                                .buttonStyle(OnboardingButtonStyle(isDisabled: false))

                                NavigationLink(isActive: $missionNavLinkActive) {
                                    InqalaabMissionView()
                                        .modifier(ThemedBackground())
                                } label: {
                                    EmptyView()
                                }
                                .frame(width: 1, height: 1)
                                .hidden()
                            }

                            // Migrate option
                            Button {
                                m.migrationState = .pasteOrScanLink
                            } label: {
                                Label("Migrate from another device", systemImage: "tray.and.arrow.down")
                                    .font(.system(size: 15))
                                    .foregroundColor(.white.opacity(0.7))
                                    .frame(minHeight: 36)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 25)
                    }

                    Spacer().frame(height: 30)
                }
                .frame(minHeight: g.size.height)
            }
            .sheet(isPresented: Binding(
                get: { m.migrationState != nil },
                set: { _ in
                    m.migrationState = nil
                    MigrationToDeviceState.save(nil) }
            )) {
                NavigationView {
                    VStack(alignment: .leading) {
                        MigrateToDevice(migrationState: $m.migrationState)
                    }
                    .navigationTitle("Migrate here")
                    .modifier(ThemedBackground(grouped: true))
                }
            }
            if #available(iOS 16.4, *) {
                v.scrollBounceBehavior(.basedOnSize)
            } else {
                v
            }
        }
        .onAppear() {
            setLastVersionDefault()
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
                    colors: [InqalaabGreen.opacity(0.08), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 400
                )
            }
            .ignoresSafeArea()
        )
        .navigationBarHidden(onboarding)
    }

    private func inqalaabFeatureRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
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

let textSpace = Text(verbatim: " ")

let textNewLine = Text(verbatim: "\n")

struct InqalaabInfo_Previews: PreviewProvider {
    static var previews: some View {
        InqalaabInfo(onboarding: true)
    }
}
