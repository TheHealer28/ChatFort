//
//  CrowdMeshTeamsView.swift
//  ChatFort — Crowd mesh
//
//  Teams: group chats only team members can read. Everyone joins with the same team code, shared as
//  a QR code or text. List, create, join (scan or paste), the team code, and the team chat.
//

import SwiftUI
#if canImport(InqalaabChat)
import InqalaabChat
#endif

// MARK: - List

struct CrowdMeshTeamsView: View {
    @ObservedObject private var mesh = CrowdMesh.shared
    let onOpen: @MainActor (CrowdMeshRoute) -> Void
    @State private var sheet: TeamsSheet?
    /// Set by the create or join sheet; opened once the sheet has gone.
    @State private var pending: CrowdMeshRoute?

    private enum TeamsSheet: String, Identifiable {
        case create, join
        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                Text("A team is a group chat for people you trust: friends, medics, marshals. Only team members can read its messages. Everyone joins with the same team code.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { sheet = .create } label: {
                    Label("Create team", systemImage: "plus.circle.fill")
                        .foregroundColor(InqalaabGreen)
                }
                Button { sheet = .join } label: {
                    Label("Join with code", systemImage: "qrcode.viewfinder")
                        .foregroundColor(InqalaabGreen)
                }
            }
            Section {
                if mesh.teams.isEmpty {
                    Text("You're not in a team yet.")
                        .font(.subheadline)
                        .italic()
                        .foregroundColor(.secondary)
                }
                ForEach(mesh.teams) { team in
                    Button { onOpen(.team(id: team.id, name: team.name)) } label: {
                        CrowdMeshTeamRow(team: team)
                    }
                }
            } header: {
                Text("Your teams")
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $sheet, onDismiss: { openPending() }) { which in
            switch which {
            case .create:
                CrowdMeshCreateTeamSheet { pending = .team(id: $0.id, name: $0.name) }
            case .join:
                CrowdMeshJoinTeamSheet { pending = .team(id: $0.id, name: $0.name) }
            }
        }
    }

    private func openPending() {
        guard let destination = pending else { return }
        pending = nil
        onOpen(destination)
    }
}

struct CrowdMeshTeamRow: View {
    let team: MeshTeamInfo

    var body: some View {
        HStack(spacing: 12) {
            CrowdMeshAvatar(systemImage: "person.3.fill")
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: team.name)
                        .font(.body.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let date = team.lastMessage?.date {
                        CrowdMeshUI.shortDate(date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    CrowdMeshUI.preview(team.lastMessage, showSender: true)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if team.unread > 0 {
                        CrowdMeshUnreadBadge(count: team.unread)
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

// MARK: - Create

/// Name the team, then show its code straight away (Android does the same).
struct CrowdMeshCreateTeamSheet: View {
    @ObservedObject private var mesh = CrowdMesh.shared
    @Environment(\.dismiss) private var dismiss
    let onCreated: @MainActor (MeshTeamInfo) -> Void
    @State private var name = ""
    @State private var created: MeshTeamInfo?
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationView {
            content
                .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    @ViewBuilder private var content: some View {
        if let team = created {
            CrowdMeshTeamCodeView(teamId: team.id, teamName: team.name)
                .navigationTitle(Text("Team code"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        } else {
            form
                .navigationTitle(Text("Create a team"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { create() }
                            .disabled(trimmedName.isEmpty)
                    }
                }
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("e.g. Medics north", text: $name)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { create() }
                    .onChange(of: name) { value in
                        let limited = CrowdMeshUI.limited(value, characters: CrowdMeshUI.maxTeamNameCharacters)
                        if limited != value { name = limited }
                    }
            } header: {
                Text("Team name")
            } footer: {
                Text("Pick a name your team will recognise. Don't include real names.")
            }
        }
        .task {
            // Focusing while the sheet is still animating in is ignored on iOS 15.
            try? await Task.sleep(nanoseconds: 600_000_000)
            nameFocused = true
        }
    }

    private func create() {
        guard !trimmedName.isEmpty, created == nil else { return }
        let team = mesh.createTeam(name: trimmedName)
        created = team
        onCreated(team)
    }
}

// MARK: - Join

/// Scan a teammate's team code with the camera, or paste one.
struct CrowdMeshJoinTeamSheet: View {
    @ObservedObject private var mesh = CrowdMesh.shared
    @Environment(\.dismiss) private var dismiss
    let onJoined: @MainActor (MeshTeamInfo) -> Void
    @State private var code = ""
    @State private var error: CrowdMeshError?
    @State private var scanning = false
    /// The scanner may report the same code many times; only the first counts.
    @State private var scanHandled = false
    @State private var joinedByScan = false

    private static let codePlaceholder = "CFTEAM2.…"
    private var trimmedCode: String { CrowdMeshUI.cleanedTeamCode(code) }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("Scan the team code on a teammate's phone, or paste a code they gave you.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        scanHandled = false
                        scanning = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                            .foregroundColor(InqalaabGreen)
                    }
                }
                Section {
                    TextField(Self.codePlaceholder, text: editableCode)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.join)
                        .onSubmit { joinPasted() }
                    Button("Join team") { joinPasted() }
                        .disabled(trimmedCode.isEmpty)
                        .foregroundColor(trimmedCode.isEmpty ? .secondary : InqalaabGreen)
                } header: {
                    Text("Or paste a code")
                } footer: {
                    if let error = error {
                        CrowdMeshUI.errorText(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(Text("Join a team"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        // Closing both sheets at once isn't reliable, so this one closes after the scanner has gone.
        .sheet(isPresented: $scanning, onDismiss: { if joinedByScan { dismiss() } }) {
            MeshCodeScanner { handleScan($0) }
        }
    }

    /// Editing the code clears the last error; a scanned code sets `code` directly and keeps its error.
    private var editableCode: Binding<String> {
        Binding(get: { code }, set: { code = $0; error = nil })
    }

    private func handleScan(_ scanned: String) {
        guard !scanHandled else { return }
        scanHandled = true
        code = CrowdMeshUI.cleanedTeamCode(scanned)
        joinedByScan = join(code)
        scanning = false
    }

    private func joinPasted() {
        if join(trimmedCode) { dismiss() }
    }

    private func join(_ teamCode: String) -> Bool {
        guard !teamCode.isEmpty else { return false }
        switch mesh.joinTeam(code: teamCode) {
        case .success(let team):
            error = nil
            onJoined(team)
            return true
        case .failure(let e):
            error = e
            return false
        }
    }
}

// MARK: - Team code

/// The team's code as a QR code and text, to show face to face or share.
struct CrowdMeshTeamCodeView: View {
    @ObservedObject private var mesh = CrowdMesh.shared
    let teamId: String
    let teamName: String
    @State private var qr: UIImage?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text(verbatim: teamName)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let code = mesh.teamCode(for: teamId) {
                    codeContent(code)
                } else {
                    Text("This team's code isn't available.")
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder private func codeContent(_ code: String) -> some View {
        qrImage
            .task(id: code) { qr = CrowdMeshUI.qrImage(code) }
        // Not selectable: the display copy has invisible break points; "Copy code" copies the real code.
        Text(verbatim: CrowdMeshUI.wrappableCode(code))
            .font(.system(.footnote, design: .monospaced))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Text(verbatim: code))
        CrowdMeshBanner(
            icon: "exclamationmark.shield.fill",
            text: Text("Anyone with this code can read the team's messages from today on."),
            tint: .red,
            tintedText: true
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        Text("Let people you trust scan it in ChatFort: Crowd mesh › Teams › Join with code. Show it face to face.")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        CrowdMeshButtonPair {
            Button {
                CrowdMeshUI.copySecret(code)
                copied = true
            } label: {
                Group {
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                    } else {
                        Label("Copy code", systemImage: "doc.on.doc")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } second: {
            Button { showShareSheet(items: [code]) } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .tint(InqalaabGreen)
        .controlSize(.large)
    }

    private var qrImage: some View {
        ZStack {
            Color.white
            if let image = qr {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 300)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(Text("Team code QR"))
        .accessibilityAddTraits(.isImage)
    }
}

// MARK: - Team chat

struct CrowdMeshTeamChatView: View {
    @ObservedObject private var mesh = CrowdMesh.shared
    @Environment(\.dismiss) private var dismiss
    let teamId: String
    /// From the route; the live name wins while the team exists.
    let teamName: String
    @State private var draft = ""
    @State private var showCode = false
    @State private var confirmLeave = false
    @State private var wasListed = false
    @State private var closing = false

    private var name: String { mesh.teams.first { $0.id == teamId }?.name ?? teamName }

    var body: some View {
        let messages = mesh.teamMessages(teamId)
        VStack(spacing: 0) {
            CrowdMeshStatusNotice()
            CrowdMeshBanner(icon: "lock.fill", text: Text("Team: only team members can read this."), tint: InqalaabGreen)
            CrowdMeshMessageList(messages: messages)
            CrowdMeshComposeBar(text: $draft, placeholder: "Message \(name)", attachments: {
                CrowdMeshMediaButtons { type, data, durationMs, width, height in
                    mesh.sendTeamMedia(teamId, type, data: data, durationMs: durationMs, width: width, height: height)
                }
            }) { mesh.sendTeam(teamId, text: $0) }
        }
        .navigationTitle(Text(verbatim: name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showCode) { codeSheet }
        .confirmationDialog(Text("Leave \(name)?"), isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave team", role: .destructive) {
                mesh.leaveTeam(teamId)
                close()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its messages and code are removed from this phone. To come back, you need the code again.")
        }
        .modifier(CrowdMeshMarkRead(newestId: messages.last?.id) { mesh.markRead(team: teamId) })
        .onAppear { if mesh.teams.contains(where: { $0.id == teamId }) { wasListed = true } }
        // A team that is left (or wiped) elsewhere closes.
        .onChange(of: mesh.teams.map(\.id)) { ids in
            if ids.contains(teamId) { wasListed = true } else if wasListed { close() }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button { showCode = true } label: {
                Image(systemName: "qrcode")
            }
            .accessibilityLabel(Text("Share team code"))
            Menu {
                Button { showCode = true } label: {
                    Label("Share team code", systemImage: "qrcode")
                }
                Button(role: .destructive) { confirmLeave = true } label: {
                    Label("Leave team", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(Text("More"))
        }
    }

    private var codeSheet: some View {
        NavigationView {
            CrowdMeshTeamCodeView(teamId: teamId, teamName: name)
                .navigationTitle(Text("Team code"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showCode = false }
                    }
                }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    /// Once only: a second dismiss while popping could close the Crowd mesh screen too.
    private func close() {
        guard !closing else { return }
        closing = true
        dismiss()
    }
}
