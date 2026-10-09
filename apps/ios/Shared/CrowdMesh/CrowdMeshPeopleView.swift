//
//  CrowdMeshPeopleView.swift
//  ChatFort — Crowd mesh
//
//  People: your ChatFort contacts (linked automatically while online), your nickname, who is
//  nearby now, your private chats (only the other person can read them), the connection log for
//  testing, and the private chat screen.
//

import SwiftUI
import UIKit
#if canImport(InqalaabChat)
import InqalaabChat
#endif

// MARK: - List

struct CrowdMeshPeopleView: View {
    @ObservedObject private var mesh = CrowdMesh.shared
    let onOpen: @MainActor (CrowdMeshRoute) -> Void
    @State private var editingNickname = false
    @State private var showLog = false
    @State private var chatToDelete: MeshPrivateChat?

    var body: some View {
        List {
            contactsSection
            nicknameSection
            nearbySection
            if !mesh.privateChats.isEmpty {
                chatsSection
            }
            logSection
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $editingNickname) { CrowdMeshNicknameSheet() }
        .confirmationDialog(
            Text("Delete this conversation?"),
            isPresented: Binding(get: { chatToDelete != nil }, set: { if !$0 { chatToDelete = nil } }),
            titleVisibility: .visible,
            presenting: chatToDelete
        ) { chat in
            Button("Delete conversation", role: .destructive) { mesh.deletePrivateChat(chat.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its messages are removed from this phone.")
        }
    }

    private var contactsSection: some View {
        Section {
            if mesh.linkedContacts.isEmpty {
                Text("None yet. Your ChatFort contacts appear here once both phones have been online with an updated ChatFort.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(mesh.linkedContacts) { contact in
                Button { onOpen(.contactChat(id: contact.id, name: contact.name)) } label: {
                    CrowdMeshContactRow(contact: contact)
                }
            }
        } header: {
            Text("Your ChatFort contacts")
        } footer: {
            Text("Chat with them here without internet, with photos and voice notes. Only they can read it.")
        }
    }

    private var nicknameSection: some View {
        Section {
            Button { editingNickname = true } label: {
                HStack {
                    Text("Your nickname: \(Text(verbatim: mesh.nickname).bold())")
                        .foregroundColor(.primary)
                    Spacer(minLength: 8)
                    Text("Change")
                        .foregroundColor(InqalaabGreen)
                }
            }
        } footer: {
            Text("Don't use your real name. Anyone nearby can see your nickname.")
        }
    }

    private var nearbySection: some View {
        Section {
            if mesh.people.isEmpty {
                Text("Nobody in reach yet. People appear here when they run ChatFort's crowd mesh nearby.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(mesh.people) { person in
                Button {
                    let chatId = mesh.openPrivateChat(with: person.id)
                    onOpen(.privateChat(id: chatId, name: person.nickname))
                } label: {
                    CrowdMeshPersonRow(person: person)
                }
            }
        } header: {
            Text("Nearby now")
        } footer: {
            if !mesh.people.isEmpty {
                Text("Tap someone to send a private message only they can read.")
            }
        }
    }

    private var chatsSection: some View {
        Section {
            ForEach(mesh.privateChats) { chat in
                Button { onOpen(.privateChat(id: chat.id, name: chat.nickname)) } label: {
                    CrowdMeshPrivateChatRow(chat: chat)
                }
                .swipeActions(edge: .trailing) {
                    // No destructive role: that removes the row before the confirmation is answered.
                    Button { chatToDelete = chat } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
        } header: {
            Text("Private chats")
        }
    }

    private var logSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showLog) {
                if mesh.log.isEmpty {
                    Text("Nothing logged yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    // Newest first.
                    Text(verbatim: mesh.log.suffix(300).reversed().joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Button("Copy log") {
                        UIPasteboard.general.string = mesh.log.joined(separator: "\n")
                    }
                    .foregroundColor(InqalaabGreen)
                }
            } label: {
                Text("Connection log (for testing)")
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct CrowdMeshPersonRow: View {
    let person: MeshPerson

    var body: some View {
        HStack(spacing: 12) {
            CrowdMeshAvatar(systemImage: "person.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: person.nickname)
                    .font(.body.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                CrowdMeshUI.distance(person.hops)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            CrowdMeshChevron()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens a private chat"))
    }
}

struct CrowdMeshPrivateChatRow: View {
    let chat: MeshPrivateChat

    var body: some View {
        HStack(spacing: 12) {
            CrowdMeshAvatar(systemImage: "person.fill")
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: chat.nickname)
                        .font(.body.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if chat.isNearby {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(InqalaabGreen)
                            .accessibilityLabel(Text("Nearby now"))
                    }
                    Spacer(minLength: 8)
                    if let date = chat.lastMessage?.date {
                        CrowdMeshUI.shortDate(date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    CrowdMeshUI.preview(chat.lastMessage, showSender: false)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if chat.unread > 0 {
                        CrowdMeshUnreadBadge(count: chat.unread)
                    }
                }
            }
            CrowdMeshChevron()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Nickname

struct CrowdMeshNicknameSheet: View {
    @ObservedObject private var mesh = CrowdMesh.shared
    @Environment(\.dismiss) private var dismiss
    /// Blank means a random nickname (see `CrowdMeshUI.editableNickname`).
    @State private var value = CrowdMeshUI.editableNickname(CrowdMesh.shared.nickname)

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Random nickname", text: $value)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                        .onSubmit { save() }
                        .onChange(of: value) { newValue in
                            let limited = CrowdMeshUI.limitedNickname(newValue)
                            if limited != newValue { value = limited }
                        }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Don't use your real name. Anyone nearby can see your nickname.")
                            .foregroundColor(.red)
                        Text("Leave it blank to get a random nickname.")
                    }
                }
            }
            .navigationTitle(Text("Crowd nickname"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func save() {
        mesh.setNickname(value)
        dismiss()
    }
}

// MARK: - Private chat

struct CrowdMeshPrivateChatView: View {
    @ObservedObject private var mesh = CrowdMesh.shared
    @Environment(\.dismiss) private var dismiss
    let chatId: String
    /// From the route; the chat's current nickname wins while the chat exists.
    let name: String
    @State private var draft = ""
    @State private var confirmDelete = false
    @State private var wasListed = false
    @State private var closing = false

    private var chat: MeshPrivateChat? { mesh.privateChats.first { $0.id == chatId } }
    private var displayName: String { chat?.nickname ?? name }

    var body: some View {
        let messages = mesh.privateMessages(chatId)
        VStack(spacing: 0) {
            CrowdMeshStatusNotice()
            CrowdMeshBanner(icon: "lock.fill", text: Text("Private: only they can read it."), detail: reach, tint: InqalaabGreen)
            CrowdMeshMessageList(messages: messages)
            CrowdMeshComposeBar(text: $draft, placeholder: "Private message") { mesh.sendPrivate(chatId, text: $0) }
        }
        .navigationTitle(Text(verbatim: displayName))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete conversation", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text("More"))
            }
        }
        .confirmationDialog(Text("Delete this conversation?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete conversation", role: .destructive) {
                mesh.deletePrivateChat(chatId)
                close()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its messages are removed from this phone.")
        }
        .modifier(CrowdMeshMarkRead(newestId: messages.last?.id) { mesh.markRead(privateChat: chatId) })
        .onAppear { if chat != nil { wasListed = true } }
        // A chat deleted (or wiped) elsewhere closes. Not before it has been listed once, in case
        // `openPrivateChat` only lists it after the first message.
        .onChange(of: mesh.privateChats.map(\.id)) { ids in
            if ids.contains(chatId) { wasListed = true } else if wasListed { close() }
        }
    }

    /// How far away they are now.
    private var reach: Text {
        if let chat = chat, let person = mesh.people.first(where: { $0.id == chat.peerId }) {
            return CrowdMeshUI.distance(person.hops)
        }
        return chat?.isNearby == true ? Text("Nearby now") : Text("Not nearby right now")
    }

    /// Once only: a second dismiss while popping could close the Crowd mesh screen too.
    private func close() {
        guard !closing else { return }
        closing = true
        dismiss()
    }
}
