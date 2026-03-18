//
//  WhatsNewView.swift
//  SimpleX (iOS)
//
//  Created by Evgeny on 24/12/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import InqalaabChat

private struct VersionDescription {
    var version: String
    var post: URL?
    var features: [Feature]
}

private enum Feature: Identifiable {
    case feature(Description)
    case view(FeatureView)
    
    var id: LocalizedStringKey {
        switch self {
        case let .feature(d): d.title
        case let .view(v): v.title
        }
    }
}

private struct Description {
    let icon: String?
    let title: LocalizedStringKey
    let description: LocalizedStringKey?
    var subfeatures: [(icon: String, description: LocalizedStringKey)] = []
}

private struct FeatureView {
    let icon: String?
    let title: LocalizedStringKey
    let view: () -> any View
}

private let versionDescriptions: [VersionDescription] = [
    VersionDescription(
        version: "v1.0.0",
        post: nil,
        features: [
            .feature(Description(
                icon: "shield.checkered",
                title: "Built for activists",
                description: "Inqalaab is purpose-built for activists, journalists, and organizers in South Asia."
            )),
            .feature(Description(
                icon: "eye.slash.fill",
                title: "No surveillance possible",
                description: "No phone number, no tracking, no metadata collected."
            )),
            .feature(Description(
                icon: "server.rack",
                title: "Independent servers",
                description: "Messages routed through community-run servers outside your country."
            )),
            .feature(Description(
                icon: "key",
                title: "Quantum resistant encryption",
                description: "End-to-end encrypted with post-quantum security."
            )),
        ]
    ),
    VersionDescription(
        version: "v1.1.0",
        post: nil,
        features: [
            .feature(Description(
                icon: "bolt.shield.fill",
                title: "Safety Hub",
                description: "Your security command center with real-time security score and one-tap protections."
            )),
            .feature(Description(
                icon: "exclamationmark.triangle.fill",
                title: "Panic Mode",
                description: "Shake to wipe all data instantly. Configurable with deadman's switch timer."
            )),
            .feature(Description(
                icon: "lock.shield.fill",
                title: "Lockdown Mode",
                description: "One toggle to enable maximum privacy — hides previews, enables incognito, and more."
            )),
            .feature(Description(
                icon: "person.crop.circle.badge.checkmark",
                title: "Emergency Contacts",
                description: "Mark trusted contacts and send a check-in message to all of them with one tap."
            )),
            .view(FeatureView(
                icon: nil,
                title: "Short Inqalaab address",
                view: { CreateUpdateAddressShortLink() }
            )),
        ]
    ),
]

private let lastVersion = versionDescriptions.last!.version

func setLastVersionDefault() {
    UserDefaults.standard.set(lastVersion, forKey: DEFAULT_WHATS_NEW_VERSION)
}

func shouldShowWhatsNew() -> Bool {
    let v = UserDefaults.standard.string(forKey: DEFAULT_WHATS_NEW_VERSION)
    setLastVersionDefault()
    return v != lastVersion
}

fileprivate struct CreateUpdateAddressShortLink: View {
    @EnvironmentObject private var chatModel: ChatModel
    @EnvironmentObject var theme: AppTheme
    @State private var showAddressSheet = false
    @State private var progressIndicator = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: "link")
                    .symbolRenderingMode(.monochrome)
                    .foregroundColor(theme.colors.secondary)
                    .frame(minWidth: 30, alignment: .center)
                Text("Short Inqalaab address").font(.title3).bold()
            }
            Group {
                if let addr = chatModel.userAddress {
                    if addr.shouldBeUpgraded {
                        HStack(spacing: 8) {
                            Button("Upgrade your address") { upgradeAndShareAddressAlert(progressIndicator: $progressIndicator) }
                            if progressIndicator {
                                ProgressView()
                            }
                        }
                    } else {
                        Button("Share your Inqalaab address") { addr.shareAddress(short: true) }
                    }
                } else {
                    Button("Create your address") { showAddressSheet = true }
                }
            }
            .multilineTextAlignment(.leading)
            .lineLimit(10)
        }
        .sheet(isPresented: $showAddressSheet) {
            NavigationView {
                UserAddressView(autoCreate: true)
                    .navigationTitle("Inqalaab address")
                    .navigationBarTitleDisplayMode(.large)
                    .modifier(ThemedBackground(grouped: true))
            }
        }
    }
}

private enum WhatsNewViewSheet: Identifiable {
    case showConditions

    var id: String {
        switch self {
        case .showConditions: return "showConditions"
        }
    }
}

struct WhatsNewView: View {
    @Environment(\.dismiss) var dismiss: DismissAction
    @EnvironmentObject var theme: AppTheme
    @State var currentVersion = versionDescriptions.count - 1
    @State var currentVersionNav = versionDescriptions.count - 1
    var viaSettings = false
    var updatedConditions: Bool
    @State private var sheetItem: WhatsNewViewSheet? = nil

    var body: some View {
        whatsNewView()
            .sheet(item: $sheetItem) { item in
                switch item {
                case .showConditions:
                    UsageConditionsView(
                        currUserServers: Binding.constant([]),
                        userServers: Binding.constant([])
                    )
                    .modifier(ThemedBackground(grouped: true))
                }
            }
    }

    private func whatsNewView() -> some View {
        VStack {
            TabView(selection: $currentVersion) {
                ForEach(Array(versionDescriptions.enumerated()), id: \.0) { (i, v) in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("New in \(v.version)")
                                .font(.title)
                                .foregroundColor(theme.colors.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical)
                            ForEach(v.features) { f in
                                switch f {
                                case let .feature(d): featureDescription(d).padding(.bottom, 8)
                                case let .view(v): AnyView(v.view()).padding(.bottom, 8)
                                }
                            }
                            if let post = v.post {
                                Link(destination: post) {
                                    HStack {
                                        Text("Read more")
                                        Image(systemName: "arrow.up.right.circle")
                                    }
                                }
                            }
                            if updatedConditions {
                                Button("View updated conditions") {
                                    sheetItem = .showConditions
                                }
                            }
                            if !viaSettings {
                                Spacer()

                                Button("Ok") {
                                    dismiss()
                                }
                                .font(.title3)
                                .frame(maxWidth: .infinity, alignment: .center)

                                Spacer()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            Spacer()
            pagination()
        }
        .padding()
        .onChange(of: currentVersion) { _ in
            currentVersionNav = currentVersion
        }
    }
    
    @ViewBuilder private func featureHeader(_ icon: String?, _ title: LocalizedStringKey) -> some View {
        if let icon {
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: icon)
                    .symbolRenderingMode(.monochrome)
                    .foregroundColor(theme.colors.secondary)
                    .frame(minWidth: 30, alignment: .center)
                Text(title).font(.title3).bold()
            }
        } else {
            Text(title).font(.title3).bold()
        }
    }

    private func featureDescription(_ f: Description) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            featureHeader(f.icon, f.title)
            if let d = f.description {
                Text(d)
                    .multilineTextAlignment(.leading)
                    .lineLimit(10)
            }
            if f.subfeatures.count > 0 {
                ForEach(f.subfeatures, id: \.icon) { s in
                    HStack(alignment: .center, spacing: 4) {
                        Image(systemName: s.icon)
                            .symbolRenderingMode(.monochrome)
                            .foregroundColor(theme.colors.secondary)
                            .frame(minWidth: 30, alignment: .center)
                        Text(s.description)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                }
            }
        }
    }

    private func pagination() -> some View {
        HStack {
            if currentVersionNav > 0 {
                let prev = currentVersionNav - 1
                Button {
                    currentVersionNav = prev
                    withAnimation { currentVersion = prev }
                } label: {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text(versionDescriptions[prev].version)
                    }
                }
            }
            Spacer()
            if currentVersionNav < versionDescriptions.count - 1 {
                let next = currentVersionNav + 1
                Button {
                    currentVersionNav = next
                    withAnimation { currentVersion = next }
                } label: {
                    HStack {
                        Text(versionDescriptions[next].version)
                        Image(systemName: "chevron.right")
                    }
                }
            }
        }
    }
}

struct NewFeaturesView_Previews: PreviewProvider {
    static var previews: some View {
        WhatsNewView(updatedConditions: false)
    }
}
