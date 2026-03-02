import SwiftUI

/// List of discovered nearby peers with their conversations.
/// Replaces the normal chat list when Nearby mode is active.
struct NearbyPeerListView: View {
    @EnvironmentObject var nearbyModel: NearbyModel
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        if nearbyModel.peers.isEmpty && nearbyModel.conversations.isEmpty {
            NearbyEmptyState()
        } else {
            List {
                // Status header
                nearbyStatusHeader
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                // Connected peers with conversations
                let items = mergedPeerList
                ForEach(items, id: \.peerId) { item in
                    NavigationLink(
                        destination: NearbyConversationView(peerId: item.peerId)
                            .environmentObject(nearbyModel)
                            .environmentObject(theme)
                    ) {
                        NearbyPeerRow(
                            peer: item.peer,
                            conversation: item.conversation
                        )
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Status Header

    @ViewBuilder
    private var nearbyStatusHeader: some View {
        HStack(spacing: 8) {
            if nearbyModel.isSearching {
                ProgressView()
                    .scaleEffect(0.8)
            }

            let connectedCount = nearbyModel.peers.filter { $0.connectionState == .connected }.count
            let totalCount = nearbyModel.peers.count

            if totalCount == 0 {
                Text("Searching for nearby peers...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("\(connectedCount) connected, \(totalCount) found nearby")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Merged Peer List

    /// Combines peers and conversations into a single sorted list.
    private var mergedPeerList: [PeerListItem] {
        var items: [PeerListItem] = []
        var seen = Set<String>()

        // First: peers with conversations (sorted by last message)
        for conversation in nearbyModel.sortedConversations {
            let peerId = conversation.id
            seen.insert(peerId)
            let peer = nearbyModel.peers.first(where: { $0.id == peerId }) ?? NearbyPeer(
                id: peerId,
                displayName: conversation.peerDisplayName,
                connectionState: .disconnected,
                lastSeen: conversation.lastMessageTimestamp ?? Date()
            )
            items.append(PeerListItem(peerId: peerId, peer: peer, conversation: conversation))
        }

        // Then: discovered peers without conversations (sorted by connection state)
        let connectedFirst: [NearbyConnectionState] = [.connected, .connecting, .discovered, .disconnected]
        let remainingPeers = nearbyModel.peers
            .filter { !seen.contains($0.id) }
            .sorted { lhs, rhs in
                let lhsOrder = connectedFirst.firstIndex(of: lhs.connectionState) ?? 99
                let rhsOrder = connectedFirst.firstIndex(of: rhs.connectionState) ?? 99
                return lhsOrder < rhsOrder
            }

        for peer in remainingPeers {
            items.append(PeerListItem(peerId: peer.id, peer: peer, conversation: nil))
        }

        return items
    }
}

// MARK: - Helper Struct

private struct PeerListItem {
    let peerId: String
    let peer: NearbyPeer
    let conversation: NearbyConversation?
}
