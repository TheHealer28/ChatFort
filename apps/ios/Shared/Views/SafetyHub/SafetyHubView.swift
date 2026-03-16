//
//  SafetyHubView.swift
//  Inqalaab (iOS)
//
//  A security-focused dashboard unique to Inqalaab.
//  Does not exist in SimpleX Chat.
//

import SwiftUI
import InqalaabChat

struct SafetyHubView: View {
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var chatModel: ChatModel
    @ObservedObject private var panicManager = PanicWipeManager.shared
    @AppStorage(DEFAULT_PERFORM_LA) private var appLockEnabled = false
    @AppStorage(DEFAULT_PRIVACY_PROTECT_SCREEN) private var screenProtection = false
    @AppStorage(DEFAULT_PRIVACY_ACCEPT_IMAGES) private var autoAcceptImages = true
    @AppStorage(DEFAULT_PRIVACY_SHOW_CHAT_PREVIEWS) private var showChatPreviews = true
    @AppStorage(DEFAULT_PRIVACY_LINK_PREVIEWS) private var linkPreviews = true
    @State private var currentLAMode = privacyLocalAuthModeDefault.get()
    @State private var showPanicConfirm = false
    @AppStorage(INQALAAB_LOCKDOWN_ENABLED) private var lockdownEnabled = false
    @State private var emergencyContactIds: Set<Int64> = []
    // Inqalaab: In-app language toggle
    @State private var selectedLanguage: String = UserDefaults.standard.string(forKey: "inqalaab_selected_language")
        ?? Bundle.main.preferredLocalizations.first ?? "en"

    private var hasEmergencyContacts: Bool {
        !emergencyContactIds.isEmpty
    }

    private var securityScore: Int {
        [appLockEnabled, screenProtection, !showChatPreviews, !linkPreviews, lockdownEnabled, hasEmergencyContacts].filter { $0 }.count
    }

    var body: some View {
        NavigationView {
            List {
                // BRANDED HEADER CARD
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "shield.checkered")
                                .font(.system(size: 36))
                                .foregroundColor(.white)
                            Text("Safety Hub")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)
                            Text("Your security dashboard")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        Spacer()
                        // Security Score Ring
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 4)
                            Circle()
                                .trim(from: 0, to: CGFloat(securityScore) / 6.0)
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 2) {
                                Text("\(securityScore)/6")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                Text("secure")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                        .frame(width: 64, height: 64)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [InqalaabGreen, InqalaabTeal],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                // LANGUAGE TOGGLE
                Section {
                    Picker("", selection: $selectedLanguage) {
                        Text("English").tag("en")
                        Text("اردو").tag("ur")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedLanguage) { newLang in
                        UserDefaults.standard.set([newLang], forKey: "AppleLanguages")
                        UserDefaults.standard.set(newLang, forKey: "inqalaab_selected_language")
                        UserDefaults.standard.synchronize()
                    }
                } header: {
                    Label("Language / زبان", systemImage: "globe")
                } footer: {
                    Text("Restart the app after changing language")
                        .font(.caption2)
                }

                // NETWORK STATUS WIDGET
                Section {
                    VStack(spacing: 12) {
                        HStack(spacing: 0) {
                            networkStatusItem(
                                title: "Internet",
                                value: chatModel.chatRunning == true ? "Connected" : "Checking",
                                icon: "globe",
                                isActive: chatModel.chatRunning == true
                            )
                            Divider().frame(height: 36)
                            networkStatusItem(
                                title: "Nearby",
                                value: NearbyModel.shared.nearbyMode ? "Active" : "Off",
                                icon: "antenna.radiowaves.left.and.right",
                                isActive: NearbyModel.shared.nearbyMode
                            )
                            Divider().frame(height: 36)
                            networkStatusItem(
                                title: "Relay",
                                value: chatModel.chatRunning == true ? "Connected" : "Offline",
                                icon: "server.rack",
                                isActive: chatModel.chatRunning == true
                            )
                            Divider().frame(height: 36)
                            networkStatusItem(
                                title: "Encryption",
                                value: "E2E",
                                icon: "lock.shield.fill",
                                isActive: true
                            )
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Label("Network Status", systemImage: "network")
                }

                // EMERGENCY READINESS CARD
                Section {
                    readinessRow(
                        title: "Panic Mode",
                        value: UserDefaults.standard.bool(forKey: INQALAAB_PANIC_ENABLED) ? "Configured" : "Not set up",
                        icon: "exclamationmark.triangle.fill",
                        isReady: UserDefaults.standard.bool(forKey: INQALAAB_PANIC_ENABLED)
                    )
                    readinessRow(
                        title: "Trusted Contacts",
                        value: "\(emergencyContactIds.count) selected",
                        icon: "person.crop.circle.badge.checkmark",
                        isReady: hasEmergencyContacts
                    )
                    readinessRow(
                        title: "Lockdown Mode",
                        value: lockdownEnabled ? "Active" : "Available",
                        icon: "lock.shield.fill",
                        isReady: lockdownEnabled
                    )
                    readinessRow(
                        title: "Emergency Wipe",
                        value: UserDefaults.standard.bool(forKey: INQALAAB_PANIC_ENABLED) ? "Ready" : "Not configured",
                        icon: "trash.fill",
                        isReady: UserDefaults.standard.bool(forKey: INQALAAB_PANIC_ENABLED)
                    )
                } header: {
                    Label("Emergency Readiness", systemImage: "bolt.shield.fill")
                }

                // QUICK ACTIONS
                Section {
                    NavigationLink {
                        NewChatView(selection: .invite)
                            .navigationTitle("New chat")
                            .modifier(ThemedBackground(grouped: true))
                    } label: {
                        Label("Create 1-time link", systemImage: "link.badge.plus")
                    }
                    NavigationLink {
                        NewChatView(selection: .connect, showQRCodeScanner: true)
                            .navigationTitle("New chat")
                            .modifier(ThemedBackground(grouped: true))
                    } label: {
                        Label("Scan / Paste link", systemImage: "qrcode.viewfinder")
                    }
                    NavigationLink {
                        AddGroupView()
                            .navigationTitle("Create group")
                            .modifier(ThemedBackground(grouped: true))
                    } label: {
                        Label("Create group", systemImage: "person.2.circle.fill")
                    }
                } header: {
                    Label("Quick Actions", systemImage: "bolt.fill")
                }

                // SECTION 1: Connection Status
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: chatModel.chatRunning == true ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .font(.title2)
                            .foregroundColor(chatModel.chatRunning == true ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chatModel.chatRunning == true ? "Connected & Secure" : "Connecting...")
                                .font(.headline)
                            Text("Routed through independent servers")
                                .font(.caption)
                                .foregroundColor(theme.colors.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Label("Connection Status", systemImage: "antenna.radiowaves.left.and.right")
                }

                // SECTION 2: Security Checklist (Interactive)
                Section {
                    // App Lock — NavigationLink to full InqalaabLockView
                    NavigationLink {
                        InqalaabLockView(prefPerformLA: $appLockEnabled, currentLAMode: $currentLAMode)
                            .navigationTitle("Inqalaab Lock")
                            .modifier(ThemedBackground(grouped: true))
                    } label: {
                        SecurityCheckRow(
                            title: "App Lock",
                            detail: appLockEnabled ? "Enabled (\(currentLAMode == .system ? "Biometric" : "Passcode"))" : "Tap to configure",
                            isEnabled: appLockEnabled,
                            icon: "lock.fill"
                        )
                    }

                    // Screen Protection — Toggle
                    HStack(spacing: 12) {
                        Image(systemName: "eye.slash.fill")
                            .foregroundColor(screenProtection ? .green : .gray)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Screen Protection", isOn: $screenProtection)
                                .font(.body)
                            Text("Hide content in app switcher")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Private Notifications — Toggle (inverted: ON = showChatPreviews OFF)
                    HStack(spacing: 12) {
                        Image(systemName: "bell.slash.fill")
                            .foregroundColor(!showChatPreviews ? .green : .gray)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Private Notifications", isOn: Binding(
                                get: { !showChatPreviews },
                                set: { showChatPreviews = !$0 }
                            ))
                                .font(.body)
                            Text("Hide message previews")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Link Preview Disabled — Toggle (inverted: ON = linkPreviews OFF)
                    HStack(spacing: 12) {
                        Image(systemName: "link.badge.plus")
                            .foregroundColor(!linkPreviews ? .green : .gray)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Link Preview Disabled", isOn: Binding(
                                get: { !linkPreviews },
                                set: { newValue in
                                    linkPreviews = !newValue
                                    privacyLinkPreviewsGroupDefault.set(!newValue)
                                }
                            ))
                                .font(.body)
                            Text("Prevent metadata leaks via links")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Label("Security Checklist", systemImage: "checkmark.circle")
                } footer: {
                    let enabledCount = [appLockEnabled, screenProtection, !showChatPreviews, !linkPreviews, lockdownEnabled, hasEmergencyContacts].filter { $0 }.count
                    Text("\(enabledCount)/6 protections active")
                        .foregroundColor(enabledCount >= 4 ? .green : (enabledCount >= 2 ? .orange : .red))
                }

                // SECTION 3: Emergency & Safety Tools
                Section {
                    NavigationLink {
                        EmergencyContactsView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .foregroundColor(InqalaabGreen)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Emergency Contacts")
                                    .font(.body)
                                Text("One-tap check-in with trusted people")
                                    .font(.caption)
                                    .foregroundColor(theme.colors.secondary)
                            }
                        }
                    }

                    NavigationLink {
                        LockdownModeView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundColor(lockdownEnabled ? InqalaabGreen : .gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Lockdown Mode")
                                    .font(.body)
                                Text(lockdownEnabled ? "Active — maximum privacy" : "One-tap maximum privacy")
                                    .font(.caption)
                                    .foregroundColor(lockdownEnabled ? InqalaabGreen : theme.colors.secondary)
                            }
                        }
                    }

                    NavigationLink {
                        PanicModeView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Panic Mode")
                                    .font(.body)
                                Text("Configure emergency data wipe")
                                    .font(.caption)
                                    .foregroundColor(theme.colors.secondary)
                            }
                        }
                    }

                    if panicManager.wipeInProgress {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Wiping all data...")
                                .foregroundColor(.red)
                                .font(.body)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button(role: .destructive) {
                            showPanicConfirm = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "trash.fill")
                                    .foregroundColor(.red)
                                Text("Emergency Wipe Now")
                                    .foregroundColor(.red)
                            }
                        }
                        .disabled(panicManager.panicTriggered)
                        .alert("Emergency Wipe", isPresented: $showPanicConfirm) {
                            Button("Cancel", role: .cancel) { }
                            Button("Wipe All Data", role: .destructive) {
                                PanicWipeManager.shared.performPanicWipe()
                            }
                        } message: {
                            Text("This will permanently delete ALL messages, contacts, and your profile. This cannot be undone.")
                        }
                    }
                } header: {
                    Label("Emergency", systemImage: "exclamationmark.triangle")
                }

                // SECTION 4: Safety Resources (UNIQUE content)
                Section {
                    SafetyResourceLink(
                        title: "Digital Security Guide",
                        detail: "Protect yourself online",
                        icon: "book.fill",
                        url: "https://ssd.eff.org/"
                    )
                    SafetyResourceLink(
                        title: "Secure Communication Tips",
                        detail: "Best practices for activists",
                        icon: "person.2.fill",
                        url: "https://securityinabox.org/"
                    )
                    SafetyResourceLink(
                        title: "Report Censorship",
                        detail: "Document internet shutdowns",
                        icon: "flag.fill",
                        url: "https://ooni.org/"
                    )
                    SafetyResourceLink(
                        title: "Emergency: Digital Rights",
                        detail: "Legal help for digital rights",
                        icon: "phone.fill",
                        url: "https://digitalrightsfoundation.pk/"
                    )
                } header: {
                    Label("Safety Resources", systemImage: "books.vertical")
                } footer: {
                    Text("Links open in your browser")
                        .font(.caption2)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Safety Hub")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { loadEmergencyContacts() }
        }
    }

    private func loadEmergencyContacts() {
        if let data = UserDefaults.standard.data(forKey: INQALAAB_EMERGENCY_CONTACT_IDS),
           let ids = try? JSONDecoder().decode([Int64].self, from: data) {
            emergencyContactIds = Set(ids)
        }
    }

    private func networkStatusItem(title: String, value: String, icon: String, isActive: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(isActive ? InqalaabGreen : .orange)
            Text(value)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(isActive ? InqalaabGreen : .orange)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func readinessRow(title: String, value: String, icon: String, isReady: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(isReady ? InqalaabGreen : .gray)
                .frame(width: 24)
            Text(title)
                .font(.callout)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundColor(isReady ? InqalaabGreen : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(isReady ? InqalaabGreen.opacity(0.12) : Color.secondary.opacity(0.1)))
        }
    }

}

// MARK: - Security Check Row
struct SecurityCheckRow: View {
    let title: String
    let detail: String
    let isEnabled: Bool
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(isEnabled ? .green : .gray)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(isEnabled ? .green : .gray.opacity(0.5))
        }
    }
}

// MARK: - Safety Resource Link
struct SafetyResourceLink: View {
    let title: String
    let detail: String
    let icon: String
    let url: String

    var body: some View {
        if let linkURL = URL(string: url) {
            Link(destination: linkURL) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .foregroundColor(.green)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body)
                            .foregroundColor(.primary)
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
        }
    }
}
