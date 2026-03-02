import SwiftUI

/// A single row in the Nearby peer list. Shows avatar, name, last message, and connection status.
struct NearbyPeerRow: View {
    let peer: NearbyPeer
    let conversation: NearbyConversation?
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        HStack(spacing: 12) {
            // Circle avatar with initials
            ZStack {
                Circle()
                    .fill(avatarColor)
                    .frame(width: 48, height: 48)
                Text(initials)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }

            // Name and last message
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(peer.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(theme.colors.onBackground)
                        .lineLimit(1)

                    Spacer()

                    if let timestamp = conversation?.lastMessageTimestamp {
                        Text(formatTimestamp(timestamp))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    if let lastMessage = conversation?.messages.last {
                        Text(lastMessage.isOutgoing ? "You: \(lastMessage.text)" : lastMessage.text)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(connectionStatusText)
                            .font(.subheadline)
                            .foregroundColor(connectionStatusColor)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Unread badge
                    if let unread = conversation?.unreadCount, unread > 0 {
                        Text("\(unread)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.colors.primary)
                            .clipShape(Capsule())
                    }

                    // Connection indicator dot
                    Circle()
                        .fill(connectionDotColor)
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private var initials: String {
        let words = peer.displayName.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(peer.displayName.prefix(2)).uppercased()
    }

    private var avatarColor: Color {
        // Deterministic color from name
        let hash = abs(peer.displayName.hashValue)
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint]
        return colors[hash % colors.count]
    }

    private var connectionStatusText: String {
        switch peer.connectionState {
        case .discovered: return "Discovered"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }

    private var connectionStatusColor: Color {
        switch peer.connectionState {
        case .discovered: return .orange
        case .connecting: return .orange
        case .connected: return .green
        case .disconnected: return .secondary
        }
    }

    private var connectionDotColor: Color {
        switch peer.connectionState {
        case .connected: return .green
        case .connecting, .discovered: return .orange
        case .disconnected: return .gray
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            return formatter.string(from: date)
        }
    }
}
