import SwiftUI

/// A single message bubble in a Nearby conversation.
struct NearbyMessageBubble: View {
    let message: NearbyMessage
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 60) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .font(.body)
                    .foregroundColor(message.isOutgoing ? .white : theme.colors.onBackground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(formatTime(message.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }

    private var bubbleColor: Color {
        message.isOutgoing
            ? theme.colors.primary
            : Color(.systemGray5)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
