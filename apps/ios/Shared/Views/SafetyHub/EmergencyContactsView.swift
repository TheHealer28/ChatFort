//
//  EmergencyContactsView.swift
//  Inqalaab (iOS)
//
//  Emergency contacts with one-tap check-in — unique feature not in SimpleX Chat.
//  Mark trusted contacts and send a pre-written safety message to all of them at once.
//

import SwiftUI
import SimpleXChat

let INQALAAB_EMERGENCY_CONTACT_IDS = "inqalaab_emergency_contact_ids"
let INQALAAB_CHECKIN_MESSAGE = "inqalaab_checkin_message"

struct EmergencyContactsView: View {
    @EnvironmentObject var chatModel: ChatModel
    @EnvironmentObject var theme: AppTheme
    @AppStorage(INQALAAB_CHECKIN_MESSAGE) private var checkInMessage: String = "I'm safe. Just checking in. 🛡️"
    @State private var emergencyContactIds: Set<Int64> = []
    @State private var showCheckInConfirm = false
    @State private var sendingCheckIn = false
    @State private var checkInSent = false

    /// All direct contacts that are ready and active
    private var directContacts: [(Chat, Contact)] {
        chatModel.chats.compactMap { chat in
            if case let .direct(contact) = chat.chatInfo, contact.ready, contact.active {
                return (chat, contact)
            }
            return nil
        }
    }

    /// Emergency contacts (subset of direct contacts)
    private var selectedContacts: [(Chat, Contact)] {
        directContacts.filter { emergencyContactIds.contains($0.1.contactId) }
    }

    var body: some View {
        List {
            // HEADER
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 36))
                            .foregroundColor(InqalaabGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Emergency Contacts")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text("\(emergencyContactIds.count) trusted contacts selected")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    Text("Select trusted people from your contacts. In an emergency, send a check-in message to all of them with one tap.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            // CHECK-IN MESSAGE
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Message to send:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if #available(iOS 16.0, *) {
                        TextField("Check-in message", text: $checkInMessage, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField("Check-in message", text: $checkInMessage)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } header: {
                Label("Check-in Message", systemImage: "text.bubble.fill")
            } footer: {
                Text("This message will be sent to all emergency contacts when you tap the button below")
            }

            // SEND CHECK-IN BUTTON
            Section {
                Button {
                    showCheckInConfirm = true
                } label: {
                    HStack(spacing: 12) {
                        if sendingCheckIn {
                            ProgressView()
                                .frame(width: 24)
                        } else {
                            Image(systemName: "paperplane.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sendingCheckIn ? "Sending..." : "Send Check-In Now")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("To \(emergencyContactIds.count) emergency contact\(emergencyContactIds.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(emergencyContactIds.isEmpty || sendingCheckIn
                                  ? Color.gray.opacity(0.4)
                                  : InqalaabGreen)
                    )
                }
                .disabled(emergencyContactIds.isEmpty || sendingCheckIn || checkInMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .alert("Send Check-In?", isPresented: $showCheckInConfirm) {
                    Button("Cancel", role: .cancel) { }
                    Button("Send to All") {
                        Task { await sendCheckIn() }
                    }
                } message: {
                    Text("Send \"\(checkInMessage)\" to \(emergencyContactIds.count) emergency contact\(emergencyContactIds.count == 1 ? "" : "s")?")
                }

                if checkInSent {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(InqalaabGreen)
                        Text("Check-in sent successfully!")
                            .font(.callout)
                            .foregroundColor(InqalaabGreen)
                    }
                    .listRowBackground(Color.clear)
                    .transition(.opacity)
                }
            }

            // CONTACT SELECTION LIST
            Section {
                if directContacts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.slash")
                            .font(.title)
                            .foregroundColor(.secondary)
                        Text("No contacts yet")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Add contacts in the Chats tab, then return here to mark emergency contacts.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(directContacts, id: \.1.contactId) { (chat, contact) in
                        let isSelected = emergencyContactIds.contains(contact.contactId)
                        Button {
                            toggleContact(contact.contactId)
                        } label: {
                            HStack(spacing: 12) {
                                ProfileImage(imageStr: contact.image, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.displayName)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    if contact.fullName != "" && contact.fullName != contact.displayName {
                                        Text(contact.fullName)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundColor(isSelected ? InqalaabGreen : .gray.opacity(0.4))
                            }
                        }
                    }
                }
            } header: {
                Label("Select Trusted Contacts", systemImage: "person.2.fill")
            } footer: {
                if !directContacts.isEmpty {
                    Text("Tap a contact to add or remove them from your emergency list")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Emergency Contacts")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadEmergencyContacts() }
        .animation(.easeInOut, value: checkInSent)
    }

    // MARK: - Actions

    private func toggleContact(_ contactId: Int64) {
        if emergencyContactIds.contains(contactId) {
            emergencyContactIds.remove(contactId)
        } else {
            emergencyContactIds.insert(contactId)
        }
        saveEmergencyContacts()
    }

    private func sendCheckIn() async {
        await MainActor.run { sendingCheckIn = true; checkInSent = false }

        let message = checkInMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        for contactId in emergencyContactIds {
            let _ = await apiSendMessages(
                type: .direct,
                id: contactId,
                scope: nil,
                composedMessages: [ComposedMessage(msgContent: .text(message))]
            )
        }

        await MainActor.run {
            sendingCheckIn = false
            checkInSent = true
        }

        // Auto-hide success message after 5 seconds
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        await MainActor.run { checkInSent = false }
    }

    // MARK: - Persistence

    private func loadEmergencyContacts() {
        if let data = UserDefaults.standard.data(forKey: INQALAAB_EMERGENCY_CONTACT_IDS),
           let ids = try? JSONDecoder().decode([Int64].self, from: data) {
            emergencyContactIds = Set(ids)
        }
    }

    private func saveEmergencyContacts() {
        if let data = try? JSONEncoder().encode(Array(emergencyContactIds)) {
            UserDefaults.standard.set(data, forKey: INQALAAB_EMERGENCY_CONTACT_IDS)
        }
    }
}
