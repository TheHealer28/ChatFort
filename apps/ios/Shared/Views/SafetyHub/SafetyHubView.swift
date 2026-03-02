//
//  SafetyHubView.swift
//  Inqalaab (iOS)
//
//  A security-focused dashboard unique to Inqalaab.
//  Does not exist in SimpleX Chat.
//

import SwiftUI
import SimpleXChat

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

    var body: some View {
        NavigationView {
            List {
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
                    // App Lock — NavigationLink to full SimplexLockView
                    NavigationLink {
                        SimplexLockView(prefPerformLA: $appLockEnabled, currentLAMode: $currentLAMode)
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
                    let enabledCount = [appLockEnabled, screenProtection, !showChatPreviews, !linkPreviews].filter { $0 }.count
                    Text("\(enabledCount)/4 protections active")
                        .foregroundColor(enabledCount >= 3 ? .green : (enabledCount >= 2 ? .orange : .red))
                }

                // SECTION 3: Emergency Actions
                Section {
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
