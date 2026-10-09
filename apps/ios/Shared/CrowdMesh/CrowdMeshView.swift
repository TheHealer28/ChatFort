//
//  CrowdMeshView.swift
//  ChatFort — Crowd mesh
//
//  Chat that hops from phone to phone over Bluetooth, up to 7 hops, with no internet. Same screens,
//  flows and wording as Android's CrowdMeshView.kt, in iOS form. The root of the Nearby tab, inside
//  its NavigationView (iOS 15: NavigationView/NavigationLink, not NavigationStack):
//
//      NavigationView { CrowdMeshView() }
//
//  Not running (stopped, starting, Bluetooth off / not allowed / unsupported): CrowdMeshIntroView.
//  Running: status line, Everyone / Teams / People, with team and private chats pushed on top.
//

import SwiftUI
#if canImport(InqalaabChat)
import InqalaabChat
#endif

enum CrowdMeshSection: Hashable, CaseIterable {
    case everyone, teams, people
}

struct CrowdMeshView: View {
    @ObservedObject private var mesh = CrowdMesh.shared
    @State private var section: CrowdMeshSection = .everyone
    /// Kept here so switching sections doesn't lose a half-written public message.
    @State private var everyoneDraft = ""
    /// Drives the one hidden NavigationLink (see `CrowdMeshRoute`).
    @State private var route: CrowdMeshRoute?
    /// What the pushed screen shows. Not cleared on the way back, so it doesn't go blank while popping.
    @State private var shownRoute: CrowdMeshRoute?
    @State private var confirmStop = false
    @State private var showBackgroundNote = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ZStack {
            if mesh.status == .running {
                running
            } else {
                CrowdMeshIntroView()
            }
        }
        // On the ZStack, not on its content: the link must outlive a status change, or an open
        // chat would pop when Bluetooth goes off.
        .background(routeLink)
        .navigationTitle(Text("Crowd mesh"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if mesh.status == .running {
                    Button { confirmStop = true } label: {
                        Text("Stop").fontWeight(.semibold).foregroundColor(.red)
                    }
                    .tint(.red)
                }
            }
        }
        .confirmationDialog(Text("Stop the crowd mesh?"), isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { mesh.stop() }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("Your phone stops passing on messages for the people around you, and you stop receiving them.")
        }
    }

    // MARK: - Running

    private var running: some View {
        VStack(spacing: 0) {
            statusHeader
            CrowdMeshSectionPicker(selection: $section, unread: [
                .everyone: mesh.unreadPublic,
                .teams: mesh.teams.reduce(0) { $0 + $1.unread },
                .people: mesh.privateChats.reduce(0) { $0 + $1.unread } + mesh.linkedContacts.reduce(0) { $0 + $1.unread }
            ])
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            sectionContent
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .everyone: CrowdMeshEveryoneView(draft: $everyoneDraft, isFrontmost: route == nil)
        case .teams: CrowdMeshTeamsView { open($0) }
        case .people: CrowdMeshPeopleView { open($0) }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundColor(mesh.linkedPhones > 0 ? InqalaabGreen : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                linkedText
                    .font(.subheadline.weight(.semibold))
                // At accessibility sizes the chat needs the room; the info button still says it.
                if !typeSize.isAccessibilitySize {
                    Text("Keep ChatFort open for the best reach.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button { showBackgroundNote = true } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundColor(InqalaabGreen)
            }
            .accessibilityLabel(Text("Why keep ChatFort open"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // A shape, not a bare colour: a colour background runs up under the navigation bar.
        .background(Rectangle().fill(InqalaabGreen.opacity(0.08)))
        .alert(Text("Keep ChatFort open for the best reach."), isPresented: $showBackgroundNote) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("In the background, this iPhone can still reach phones nearby, but most phones can't find it until ChatFort is open again.")
        }
    }

    private var linkedText: Text {
        switch mesh.linkedPhones {
        case ..<1: return Text("Looking for phones nearby…")
        case 1: return Text("Linked to 1 phone")
        default: return Text("Linked to \(mesh.linkedPhones) phones")
        }
    }

    // MARK: - Navigation

    private var routeLink: some View {
        NavigationLink(
            destination: routeDestination,
            isActive: Binding(get: { route != nil }, set: { if !$0 { route = nil } })
        ) {
            EmptyView()
        }
        .hidden()
        .accessibilityHidden(true)
    }

    @ViewBuilder private var routeDestination: some View {
        switch shownRoute {
        case let .team(id, name): CrowdMeshTeamChatView(teamId: id, teamName: name)
        case let .privateChat(id, name): CrowdMeshPrivateChatView(chatId: id, name: name)
        case let .contactChat(id, name): CrowdMeshContactChatView(binding: id, name: name)
        case nil: EmptyView()
        }
    }

    private func open(_ destination: CrowdMeshRoute) {
        shownRoute = destination
        route = destination
    }
}

// MARK: - Section picker

/// Segmented control with unread badges (UISegmentedControl can't show badges).
struct CrowdMeshSectionPicker: View {
    @Binding var selection: CrowdMeshSection
    let unread: [CrowdMeshSection: Int]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CrowdMeshSection.allCases, id: \.self) { segment($0) }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(.tertiarySystemFill)))
        // Capped like a native segmented control; long-press shows the Large Content Viewer.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func title(_ section: CrowdMeshSection) -> Text {
        switch section {
        case .everyone: return Text("Everyone")
        case .teams: return Text("Teams")
        case .people: return Text("People")
        }
    }

    private func segment(_ section: CrowdMeshSection) -> some View {
        let selected = selection == section
        let count = unread[section] ?? 0
        return Button { selection = section } label: {
            HStack(spacing: 5) {
                title(section)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if count > 0 {
                    CrowdMeshUnreadBadge(count: count)
                }
            }
            .foregroundColor(selected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Self.selectedFill : Color.clear)
                    .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 2, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer()
    }

    private static let selectedFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGray3 : .systemBackground
    })
}
