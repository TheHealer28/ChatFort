//
//  LockdownModeView.swift
//  Inqalaab (iOS)
//
//  One-tap maximum privacy — unique feature not in SimpleX Chat.
//  Applies 5 privacy settings at once and can restore them.
//

import SwiftUI
import InqalaabChat

let INQALAAB_LOCKDOWN_ENABLED = "inqalaab_lockdown_enabled"
// Keys for saving pre-lockdown values
private let SAVED_NTF_PREVIEW = "inqalaab_lockdown_saved_ntfPreview"
private let SAVED_LINK_PREVIEWS = "inqalaab_lockdown_saved_linkPreviews"
private let SAVED_CHAT_PREVIEWS = "inqalaab_lockdown_saved_chatPreviews"
private let SAVED_INCOGNITO = "inqalaab_lockdown_saved_incognito"
private let SAVED_SCREEN_PROTECT = "inqalaab_lockdown_saved_screenProtect"

struct LockdownModeView: View {
    @EnvironmentObject var chatModel: ChatModel
    @EnvironmentObject var theme: AppTheme
    @AppStorage(INQALAAB_LOCKDOWN_ENABLED) private var lockdownEnabled = false
    @AppStorage(DEFAULT_PRIVACY_SHOW_CHAT_PREVIEWS) private var showChatPreviews = true
    @AppStorage(DEFAULT_PRIVACY_PROTECT_SCREEN) private var screenProtection = false
    @State private var showEnableConfirm = false
    @State private var showDisableConfirm = false

    var body: some View {
        List {
            // HEADER
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 36))
                            .foregroundColor(lockdownEnabled ? InqalaabGreen : .gray)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Lockdown Mode")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text(lockdownEnabled ? "Active — maximum privacy" : "Disabled")
                                .font(.subheadline)
                                .foregroundColor(lockdownEnabled ? InqalaabGreen : .secondary)
                        }
                    }
                    Text("Applies maximum privacy settings with one tap. Disables all previews, enables incognito for new connections, and activates screen protection.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            // MASTER TOGGLE
            Section {
                Toggle(isOn: Binding(
                    get: { lockdownEnabled },
                    set: { newValue in
                        if newValue {
                            showEnableConfirm = true
                        } else {
                            showDisableConfirm = true
                        }
                    }
                )) {
                    HStack(spacing: 12) {
                        Image(systemName: lockdownEnabled ? "lock.fill" : "lock.open")
                            .foregroundColor(lockdownEnabled ? InqalaabGreen : .gray)
                        Text("Enable Lockdown")
                            .fontWeight(.medium)
                    }
                }
                .tint(InqalaabGreen)
            } footer: {
                if lockdownEnabled {
                    Text("All privacy settings are enforced. Disable lockdown to restore your previous settings.")
                        .foregroundColor(InqalaabGreen)
                }
            }
            .alert("Enable Lockdown Mode?", isPresented: $showEnableConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Enable Lockdown") { enableLockdown() }
            } message: {
                Text("This will immediately:\n• Hide notification previews\n• Disable link previews\n• Hide chat list previews\n• Enable incognito mode\n• Enable screen protection\n\nYour current settings will be saved and can be restored.")
            }
            .alert("Disable Lockdown Mode?", isPresented: $showDisableConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Disable & Restore") { disableLockdown() }
            } message: {
                Text("Your previous privacy settings will be restored.")
            }

            // PROTECTED SETTINGS STATUS
            Section {
                lockdownRow(
                    title: "Notification Previews",
                    detail: lockdownEnabled ? "Hidden" : "Visible",
                    isProtected: lockdownEnabled,
                    icon: "bell.slash.fill"
                )
                lockdownRow(
                    title: "Link Previews",
                    detail: lockdownEnabled ? "Disabled" : (privacyLinkPreviewsGroupDefault.get() ? "Enabled" : "Disabled"),
                    isProtected: lockdownEnabled || !privacyLinkPreviewsGroupDefault.get(),
                    icon: "link.badge.plus"
                )
                lockdownRow(
                    title: "Chat List Previews",
                    detail: lockdownEnabled ? "Hidden" : (showChatPreviews ? "Visible" : "Hidden"),
                    isProtected: lockdownEnabled || !showChatPreviews,
                    icon: "eye.slash.fill"
                )
                lockdownRow(
                    title: "Incognito Connections",
                    detail: lockdownEnabled ? "Enabled" : (incognitoGroupDefault.get() ? "Enabled" : "Disabled"),
                    isProtected: lockdownEnabled || incognitoGroupDefault.get(),
                    icon: "theatermasks.fill"
                )
                lockdownRow(
                    title: "Screen Protection",
                    detail: lockdownEnabled ? "Enabled" : (screenProtection ? "Enabled" : "Disabled"),
                    isProtected: lockdownEnabled || screenProtection,
                    icon: "rectangle.on.rectangle.slash"
                )
            } header: {
                Label("Protected Settings", systemImage: "shield.fill")
            } footer: {
                let count = [
                    lockdownEnabled || ntfPreviewModeGroupDefault.get() == .hidden,
                    lockdownEnabled || !privacyLinkPreviewsGroupDefault.get(),
                    lockdownEnabled || !showChatPreviews,
                    lockdownEnabled || incognitoGroupDefault.get(),
                    lockdownEnabled || screenProtection
                ].filter { $0 }.count
                Text("\(count)/5 protections active")
                    .foregroundColor(count >= 4 ? InqalaabGreen : (count >= 2 ? .orange : .red))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Lockdown Mode")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func lockdownRow(title: String, detail: String, isProtected: Bool, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(isProtected ? InqalaabGreen : .gray)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: isProtected ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(isProtected ? InqalaabGreen : .gray.opacity(0.5))
        }
    }

    private func enableLockdown() {
        // Save current values before overwriting
        UserDefaults.standard.set(ntfPreviewModeGroupDefault.get().rawValue, forKey: SAVED_NTF_PREVIEW)
        UserDefaults.standard.set(privacyLinkPreviewsGroupDefault.get(), forKey: SAVED_LINK_PREVIEWS)
        UserDefaults.standard.set(showChatPreviews, forKey: SAVED_CHAT_PREVIEWS)
        UserDefaults.standard.set(incognitoGroupDefault.get(), forKey: SAVED_INCOGNITO)
        UserDefaults.standard.set(screenProtection, forKey: SAVED_SCREEN_PROTECT)

        // Apply lockdown settings
        ntfPreviewModeGroupDefault.set(.hidden)
        chatModel.notificationPreview = .hidden
        privacyLinkPreviewsGroupDefault.set(false)
        showChatPreviews = false
        incognitoGroupDefault.set(true)
        screenProtection = true

        lockdownEnabled = true
    }

    private func disableLockdown() {
        // Restore saved values
        if let savedNtf = UserDefaults.standard.string(forKey: SAVED_NTF_PREVIEW),
           let mode = NotificationPreviewMode(rawValue: savedNtf) {
            ntfPreviewModeGroupDefault.set(mode)
            chatModel.notificationPreview = mode
        } else {
            ntfPreviewModeGroupDefault.set(.message)
            chatModel.notificationPreview = .message
        }
        privacyLinkPreviewsGroupDefault.set(UserDefaults.standard.bool(forKey: SAVED_LINK_PREVIEWS))
        showChatPreviews = UserDefaults.standard.bool(forKey: SAVED_CHAT_PREVIEWS)
        incognitoGroupDefault.set(UserDefaults.standard.bool(forKey: SAVED_INCOGNITO))
        screenProtection = UserDefaults.standard.bool(forKey: SAVED_SCREEN_PROTECT)

        lockdownEnabled = false
    }
}
