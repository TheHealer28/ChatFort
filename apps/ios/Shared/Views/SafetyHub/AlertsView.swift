//
//  AlertsView.swift
//  Inqalaab (iOS)
//
//  Emergency alerts & status check-ins — unique feature not in SimpleX Chat.
//  Quick-access to broadcast safety signals to trusted contacts.
//

import SwiftUI
import SimpleXChat

struct AlertsView: View {
    @EnvironmentObject var chatModel: ChatModel
    @EnvironmentObject var theme: AppTheme
    @AppStorage(INQALAAB_CHECKIN_MESSAGE) private var checkInMessage: String = "I'm safe. Just checking in. 🛡️"
    @State private var emergencyContactIds: Set<Int64> = []
    @State private var showBroadcastConfirm = false
    @State private var showCustomMessageSheet = false
    @State private var sending = false
    @State private var sentMessage: String? = nil
    @State private var customMessage = ""

    private var emergencyContactCount: Int { emergencyContactIds.count }

    private var directContacts: [(Chat, Contact)] {
        chatModel.chats.compactMap { chat in
            if case let .direct(contact) = chat.chatInfo, contact.ready, contact.active {
                return (chat, contact)
            }
            return nil
        }
    }

    var body: some View {
        NavigationView {
            List {
                // STATUS HEADER
                Section {
                    VStack(spacing: 16) {
                        // Status indicator
                        HStack(spacing: 12) {
                            Circle()
                                .fill(chatModel.chatRunning == true ? InqalaabGreen : Color.orange)
                                .frame(width: 12, height: 12)
                            Text(chatModel.chatRunning == true ? "Network Active" : "Connecting...")
                                .font(.headline)
                            Spacer()
                            Text(emergencyContactCount > 0 ? "\(emergencyContactCount) trusted" : "No contacts")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }

                        // Quick status panel
                        HStack(spacing: 0) {
                            statusItem(title: "Internet", value: chatModel.chatRunning == true ? "Available" : "Checking", icon: "globe", isActive: chatModel.chatRunning == true)
                            Divider().frame(height: 40)
                            statusItem(title: "Relay", value: chatModel.chatRunning == true ? "Connected" : "Offline", icon: "server.rack", isActive: chatModel.chatRunning == true)
                            Divider().frame(height: 40)
                            statusItem(title: "Security", value: "E2E", icon: "lock.shield", isActive: true)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(theme.appColors.receivedMessage))
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                // QUICK ALERTS
                Section {
                    // I'm Safe button
                    alertButton(
                        title: "I'm Safe",
                        subtitle: "Let everyone know you're OK",
                        icon: "checkmark.shield.fill",
                        color: InqalaabGreen
                    ) {
                        customMessage = checkInMessage
                        showBroadcastConfirm = true
                    }

                    // Need Help button
                    alertButton(
                        title: "Need Assistance",
                        subtitle: "Request help from trusted contacts",
                        icon: "exclamationmark.bubble.fill",
                        color: .orange
                    ) {
                        customMessage = "I need assistance. Please check on me."
                        showBroadcastConfirm = true
                    }

                    // Emergency button
                    alertButton(
                        title: "Emergency Alert",
                        subtitle: "Urgent broadcast to all contacts",
                        icon: "light.beacon.max.fill",
                        color: .red
                    ) {
                        customMessage = "⚠️ EMERGENCY: I need immediate help. This is urgent."
                        showBroadcastConfirm = true
                    }
                } header: {
                    Label("Quick Alerts", systemImage: "bolt.shield.fill")
                } footer: {
                    if emergencyContactCount == 0 {
                        Text("Set up emergency contacts in Safety Hub first")
                            .foregroundColor(.orange)
                    } else {
                        Text("Sends to \(emergencyContactCount) trusted contact\(emergencyContactCount == 1 ? "" : "s")")
                    }
                }

                // CUSTOM MESSAGE
                Section {
                    Button {
                        customMessage = ""
                        showCustomMessageSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.pencil")
                                .font(.title3)
                                .foregroundColor(InqalaabGreen)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Custom Broadcast")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text("Write and send a custom alert message")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Label("Custom Message", systemImage: "text.bubble")
                }

                // RECENT ALERTS LOG
                if let sent = sentMessage {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(InqalaabGreen)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Last alert sent")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(sent)
                                    .font(.callout)
                                    .lineLimit(2)
                            }
                        }
                    } header: {
                        Label("Recent Activity", systemImage: "clock")
                    }
                }

                // SETUP PROMPT
                if emergencyContactCount == 0 {
                    Section {
                        NavigationLink {
                            EmergencyContactsView()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.title2)
                                    .foregroundColor(InqalaabGreen)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Set Up Emergency Contacts")
                                        .font(.headline)
                                    Text("Select trusted people to receive your alerts")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } header: {
                        Label("Getting Started", systemImage: "star")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { loadEmergencyContacts() }
            .alert("Send Alert?", isPresented: $showBroadcastConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Send to All") {
                    Task { await broadcastMessage(customMessage) }
                }
            } message: {
                Text("\"\(customMessage)\"\n\nThis will be sent to \(emergencyContactCount) emergency contact\(emergencyContactCount == 1 ? "" : "s").")
            }
            .sheet(isPresented: $showCustomMessageSheet) {
                customMessageSheet
            }
        }
    }

    // MARK: - Components

    private func statusItem(title: String, value: String, icon: String, isActive: Bool) -> some View {
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

    private func alertButton(title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if sending {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .disabled(emergencyContactCount == 0 || sending)
    }

    private var customMessageSheet: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("Write your alert message")
                    .font(.headline)
                    .padding(.top, 20)

                if #available(iOS 16.0, *) {
                    TextField("Type your message...", text: $customMessage, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                } else {
                    TextField("Type your message...", text: $customMessage)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                }

                Button {
                    showCustomMessageSheet = false
                    if !customMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        showBroadcastConfirm = true
                    }
                } label: {
                    Text("Send to \(emergencyContactCount) Contacts")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(customMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.3) : InqalaabGreen)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(customMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Custom Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCustomMessageSheet = false }
                }
            }
        }
    }

    // MARK: - Actions

    private func broadcastMessage(_ message: String) async {
        await MainActor.run { sending = true }

        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        for contactId in emergencyContactIds {
            let _ = await apiSendMessages(
                type: .direct,
                id: contactId,
                scope: nil,
                composedMessages: [ComposedMessage(msgContent: .text(text))]
            )
        }

        await MainActor.run {
            sending = false
            sentMessage = text
        }
    }

    // MARK: - Persistence

    private func loadEmergencyContacts() {
        if let data = UserDefaults.standard.data(forKey: INQALAAB_EMERGENCY_CONTACT_IDS),
           let ids = try? JSONDecoder().decode([Int64].self, from: data) {
            emergencyContactIds = Set(ids)
        }
    }
}
