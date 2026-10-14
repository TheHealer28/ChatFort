import SwiftUI

/// Chat view for a single Nearby peer conversation.
struct NearbyConversationView: View {
    let peerId: String
    @EnvironmentObject var nearbyModel: NearbyModel
    @EnvironmentObject var theme: AppTheme
    @State private var messageText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if let conversation = nearbyModel.conversations[peerId] {
                            ForEach(conversation.messages) { message in
                                NearbyMessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: nearbyModel.conversations[peerId]?.messages.count) { _ in
                    if let lastMsg = nearbyModel.conversations[peerId]?.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastMsg.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    // Scroll to bottom on appear
                    if let lastMsg = nearbyModel.conversations[peerId]?.messages.last {
                        proxy.scrollTo(lastMsg.id, anchor: .bottom)
                    }
                    // Mark as read
                    nearbyModel.markConversationRead(peerId)
                    nearbyModel.activePeerId = peerId
                }
                .onDisappear {
                    nearbyModel.activePeerId = nil
                }
            }

            Divider()

            // Compose bar
            NearbyComposeBar(
                text: $messageText,
                onSend: sendMessage,
                isConnected: peerIsConnected
            )
        }
        .navigationTitle(peerDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                connectionStatusBadge
            }
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        nearbyModel.sendMessage(text: text, toPeerId: peerId)
        messageText = ""
    }

    // MARK: - Computed Properties

    private var peerDisplayName: String {
        nearbyModel.conversations[peerId]?.peerDisplayName
            ?? nearbyModel.peers.first(where: { $0.id == peerId })?.displayName
            ?? "Peer"
    }

    private var peerIsConnected: Bool {
        nearbyModel.peers.first(where: { $0.id == peerId })?.connectionState == .connected
    }

    @ViewBuilder
    private var connectionStatusBadge: some View {
        let peer = nearbyModel.peers.first(where: { $0.id == peerId })
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(for: peer?.connectionState))
                .frame(width: 8, height: 8)
            Text(statusText(for: peer?.connectionState))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func statusColor(for state: NearbyConnectionState?) -> Color {
        switch state {
        case .connected: return .green
        case .connecting, .discovered: return .orange
        case .disconnected, .none: return .gray
        }
    }

    private func statusText(for state: NearbyConnectionState?) -> String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .discovered: return "Discovered"
        case .disconnected, .none: return "Offline"
        }
    }
}
