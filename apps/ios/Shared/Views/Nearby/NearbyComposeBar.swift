import SwiftUI

/// Simplified compose bar for Nearby conversations — text field + send button.
struct NearbyComposeBar: View {
    @Binding var text: String
    let onSend: () -> Void
    let isConnected: Bool
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        HStack(spacing: 8) {
            TextField(
                isConnected ? "Message..." : "Peer disconnected",
                text: $text
            )
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .disabled(!isConnected)

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(canSend ? theme.colors.primary : .gray)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        isConnected && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
