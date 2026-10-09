//
//  CrowdMeshChatViews.swift
//  ChatFort — Crowd mesh
//
//  The chat pieces shared by Everyone, team and private chats (message list, bubbles, compose bar,
//  status notice), and the Everyone section.
//

import SwiftUI
import Combine
#if canImport(InqalaabChat)
import InqalaabChat
#endif

// MARK: - Everyone

/// Public chat: anyone nearby can read it.
struct CrowdMeshEveryoneView: View {
    @ObservedObject private var mesh = CrowdMesh.shared
    @Binding var draft: String
    /// False while a team or private chat is pushed on top of the root.
    let isFrontmost: Bool

    var body: some View {
        VStack(spacing: 0) {
            CrowdMeshBanner(
                icon: "exclamationmark.triangle.fill",
                text: Text("Everyone nearby can read this. Don't share names, locations or plans."),
                tint: .red,
                tintedText: true
            )
            CrowdMeshMessageList(messages: mesh.publicFeed)
            CrowdMeshComposeBar(text: $draft, placeholder: "Message everyone nearby") { mesh.sendPublic($0) }
        }
        .modifier(CrowdMeshMarkRead(newestId: mesh.publicFeed.last?.id, isFrontmost: isFrontmost) {
            mesh.markPublicRead()
        })
    }
}

// MARK: - Status notice

/// Shown on team and private chats when the mesh isn't running (they stay open if Bluetooth goes off).
struct CrowdMeshStatusNotice: View {
    @ObservedObject private var mesh = CrowdMesh.shared

    var body: some View {
        if let notice = notice {
            CrowdMeshBanner(icon: "exclamationmark.triangle.fill", text: notice, tint: .orange)
        }
    }

    private var notice: Text? {
        switch mesh.status {
        case .running: return nil
        case .starting: return Text("Starting…")
        case .stopped: return Text("The crowd mesh is stopped.")
        case .bluetoothOff: return Text("Turn on Bluetooth in Control Centre.")
        case .unauthorized: return Text("Allow Bluetooth for ChatFort in Settings.")
        case .unsupported: return Text("This device has no Bluetooth LE, which the crowd mesh needs.")
        }
    }
}

// MARK: - Messages

struct CrowdMeshMessageList: View {
    /// Oldest first.
    let messages: [MeshChatMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if messages.isEmpty {
                        Text("No messages yet.")
                            .font(.subheadline)
                            .italic()
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                    }
                    ForEach(messages) { message in
                        CrowdMeshMessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .onAppear { scrollToEnd(proxy, animated: false) }
            // Keyed on the newest message, not the count: the feed stops growing at its cap.
            .onChange(of: messages.last?.id) { _ in scrollToEnd(proxy, animated: true) }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                scrollToEnd(proxy, animated: true)
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last?.id else { return }
        // Next turn: on appear the lazy stack hasn't laid out yet.
        Task { @MainActor in
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            } else {
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }
}

/// Mine on the trailing side; theirs with the sender's nickname and how far away they are.
struct CrowdMeshMessageRow: View {
    let message: MeshChatMessage

    var body: some View {
        HStack(spacing: 0) {
            if message.isMine { Spacer(minLength: 48) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 3) {
                if !message.isMine {
                    Text(verbatim: message.senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(InqalaabGreen)
                        .padding(.horizontal, 8)
                }
                if let media = message.media {
                    CrowdMeshMediaBubble(message: message, media: media)
                }
                if message.media == nil || !message.text.isEmpty {
                    Text(verbatim: message.text)
                        .font(.body)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(message.isMine ? InqalaabGreen.opacity(0.18) : Color(.systemGray5))
                        )
                        .textSelection(.enabled)
                }
                footer(separator: Text(verbatim: " · "))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
            }
            if !message.isMine { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func footer(separator: Text) -> Text {
        let time = Text(message.date, style: .time)
        if message.isMine {
            switch message.status {
            case .delivered: return Text("Delivered").foregroundColor(InqalaabGreen) + separator + time
            case .onItsWay: return Text("On its way") + separator + time
            case .sent, .received: return time
            }
        }
        guard let hops = message.hops else { return time }
        return CrowdMeshUI.distance(hops) + separator + time
    }

    private var accessibilityText: Text {
        let comma = Text(verbatim: ", ")
        let sender = message.isMine ? Text("You") : Text(verbatim: message.senderName)
        let kind: Text = message.media.map { $0.kind == .photo ? Text("Photo") : Text("Voice note") } ?? Text(verbatim: "")
        return sender + comma + kind + Text(verbatim: message.media == nil ? "" : " ") + Text(verbatim: message.text)
            + comma + footer(separator: comma)
    }
}

// MARK: - Compose

/// Text field and send button, with the 1000-byte limit shown as it gets close.
struct CrowdMeshComposeBar: View {
    @Binding var text: String
    let placeholder: LocalizedStringKey
    /// Photo / voice buttons before the text field (contact and team chats).
    var attachments: (() -> CrowdMeshMediaButtons)? = nil
    let onSend: @MainActor (String) -> Result<Void, CrowdMeshError>
    @State private var error: CrowdMeshError?

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var bytes: Int { trimmed.utf8.count }
    private var tooLong: Bool { bytes > CrowdMeshUI.maxMessageBytes }
    private var canSend: Bool { !trimmed.isEmpty && !tooLong }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = error {
                errorLine(CrowdMeshUI.errorText(error))
            } else if tooLong {
                errorLine(CrowdMeshUI.errorText(.tooLong))
            }
            HStack(alignment: .bottom, spacing: 8) {
                if let attachments { attachments() }
                field
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.systemGray6)))
                if bytes >= CrowdMeshUI.messageCounterFromBytes {
                    counter
                }
                sendButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // A binding that also clears the last send error when the user edits the text.
    private var editableText: Binding<String> {
        Binding(get: { text }, set: { text = $0; error = nil })
    }

    @ViewBuilder private var field: some View {
        if #available(iOS 16.0, *) {
            TextField(placeholder, text: editableText, axis: .vertical)
                .lineLimit(1...5)
        } else {
            TextField(placeholder, text: editableText)
                .submitLabel(.send)
                .onSubmit { send() }
        }
    }

    private var counter: some View {
        Text(verbatim: "\(bytes)/\(CrowdMeshUI.maxMessageBytes)")
            .font(.caption2.monospacedDigit())
            .foregroundColor(tooLong ? .red : .secondary)
            .padding(.bottom, 10)
            .accessibilityLabel(Text("Length: \(bytes) of \(CrowdMeshUI.maxMessageBytes)"))
    }

    private var sendButton: some View {
        Button { send() } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title)
                .foregroundColor(canSend ? InqalaabGreen : Color(.systemGray3))
        }
        .disabled(!canSend)
        .accessibilityLabel(Text("Send"))
    }

    private func errorLine(_ text: Text) -> some View {
        text
            .font(.caption)
            .foregroundColor(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private func send() {
        guard canSend else { return }
        switch onSend(trimmed) {
        case .success:
            text = ""
            error = nil
        case .failure(let e):
            error = e
        }
    }
}
