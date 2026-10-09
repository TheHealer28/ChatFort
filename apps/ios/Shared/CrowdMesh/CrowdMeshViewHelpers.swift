//
//  CrowdMeshViewHelpers.swift
//  ChatFort — Crowd mesh
//
//  Small pieces shared by the Crowd mesh screens: limits, wording (distance, errors, previews),
//  banner, unread badge, avatar, the team code QR image, a sensitive copy, and marking a
//  conversation read while it is really on screen.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins
#if canImport(InqalaabChat)
import InqalaabChat
#endif

/// A screen pushed from the Crowd mesh root. One programmatic link drives all of them, so a list
/// changing underneath (someone walking out of range, a chat moving to the top) never pops a chat.
enum CrowdMeshRoute: Hashable {
    case team(id: String, name: String)
    case privateChat(id: String, name: String)
    /// A linked ChatFort contact (id = binding).
    case contactChat(id: String, name: String)
}

@MainActor
enum CrowdMeshUI {
    /// Same as Android; `CrowdMesh.setNickname` trims to this too.
    static let maxNicknameCharacters = 24
    /// Nicknames travel as at most 32 UTF-8 bytes (MeshWire.maxNickBytes); an Urdu letter takes 2.
    static let maxNicknameBytes = 32
    /// Same as Android.
    static let maxTeamNameCharacters = 40
    /// MeshWire.maxTextBytes: longer messages are refused with `.tooLong`.
    static let maxMessageBytes = 1000
    /// The compose bar shows a length counter from this many bytes on.
    static let messageCounterFromBytes = 800

    /// Longest prefix within both limits, never splitting a character.
    static func limited(_ s: String, characters: Int, bytes: Int = .max) -> String {
        if s.count <= characters && s.utf8.count <= bytes { return s }
        var out = ""
        var used = 0
        for ch in s.prefix(characters) {
            let n = String(ch).utf8.count
            if used + n > bytes { break }
            out.append(ch)
            used += n
        }
        return out
    }

    static func limitedNickname(_ s: String) -> String {
        limited(s, characters: maxNicknameCharacters, bytes: maxNicknameBytes)
    }

    /// Random session nicknames look like "anon1234". They stay out of the nickname field, so saving
    /// it untouched keeps the nickname random (a blank field means "random") instead of pinning it.
    static func editableNickname(_ name: String) -> String {
        let digits = name.dropFirst(4)
        let isRandom = name.hasPrefix("anon") && !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
        return isRandom ? "" : name
    }

    /// 0 hops = right next to you, n = through n phones.
    static func distance(_ hops: Int) -> Text {
        switch hops {
        case ..<1: return Text("Right next to you")
        case 1: return Text("Through 1 phone")
        default: return Text("Through \(hops) phones")
        }
    }

    static func errorText(_ error: CrowdMeshError) -> Text {
        switch error {
        case .invalidTeamCode: return Text("That isn't a ChatFort team code.")
        case .alreadyInTeam: return Text("You're already in this team.")
        case .notRunning:
            // `sendPrivate` also says .notRunning when it has no key for the person yet.
            return CrowdMesh.shared.status == .running
                ? Text("Can't reach this person yet.")
                : Text("The crowd mesh isn't running. Start it to send messages.")
        case .tooLong: return Text("Too long. Shorten your message to send it.")
        }
    }

    /// Last-message line for team rows (with the sender) and private chat rows. Message text is never localized.
    static func preview(_ message: MeshChatMessage?, showSender: Bool) -> Text {
        guard let m = message else { return Text("No messages yet.") }
        var text = Text(verbatim: m.text.replacingOccurrences(of: "\n", with: " "))
        if let media = m.media {
            let kind = media.kind == .photo ? Text("Photo") : Text("Voice note")
            text = m.text.isEmpty ? kind : kind + Text(verbatim: ": ") + text
        }
        if m.isMine { return Text("You:") + Text(verbatim: " ") + text }
        return showSender ? Text(verbatim: m.senderName + ": ") + text : text
    }

    /// Team codes never contain spaces. Pasted ones can carry spaces, line breaks or invisible
    /// characters from other apps, which would make a good code look invalid.
    static func cleanedTeamCode(_ code: String) -> String {
        let scalars = code.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0.properties.generalCategory != .format
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// For display only: an invisible break point between characters so a long code wraps anywhere
    /// instead of being hyphenated (a hyphen would read as part of the code). Copy the real code.
    static func wrappableCode(_ code: String) -> String {
        code.map(String.init).joined(separator: "\u{200B}")
    }

    /// Time for today, otherwise day and month.
    static func shortDate(_ date: Date) -> Text {
        Calendar.current.isDateInToday(date)
            ? Text(date, style: .time)
            : Text(date, format: .dateTime.day().month(.abbreviated))
    }

    static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Team codes are secrets: this phone only (no Universal Clipboard), cleared after 5 minutes.
    /// Android marks the clip sensitive for the same reason.
    /// Change count of the clipboard right after we copied a team code, so the panic wipe can clear
    /// it without reading the clipboard (a read would show iOS's "Allow Paste?" prompt).
    static var copiedSecretChangeCount: Int?

    static func copySecret(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(5 * 60)]
        )
        copiedSecretChangeCount = UIPasteboard.general.changeCount
    }
}

/// Full-width note under the navigation bar: red warnings, green privacy notes, orange status.
struct CrowdMeshBanner: View {
    let icon: String
    let text: Text
    var detail: Text? = nil
    let tint: Color
    /// Warnings keep their text in the tint colour; notes use normal text.
    var tintedText = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundColor(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                text
                    .font(.footnote.weight(tintedText ? .semibold : .regular))
                    .foregroundColor(tintedText ? tint : .primary)
                if let detail = detail {
                    detail
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A shape, not a bare colour: a colour background runs up under the navigation bar.
        .background(Rectangle().fill(tint.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }
}

struct CrowdMeshUnreadBadge: View {
    let count: Int

    var body: some View {
        Text(verbatim: count > 99 ? "99+" : String(count))
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(InqalaabGreen))
            .accessibilityLabel(Text("\(count) unread"))
    }
}

struct CrowdMeshAvatar: View {
    let systemImage: String
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundColor(InqalaabGreen)
            .frame(width: size, height: size)
            .background(Circle().fill(InqalaabGreen.opacity(0.14)))
            .accessibilityHidden(true)
    }
}

/// Chevron for rows that open a chat (rows are buttons, see `CrowdMeshRoute`). Flips for Urdu.
struct CrowdMeshChevron: View {
    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.footnote.weight(.semibold))
            .foregroundColor(Color(.tertiaryLabel))
            .accessibilityHidden(true)
    }
}

/// Two buttons side by side, stacked at accessibility text sizes.
struct CrowdMeshButtonPair<First: View, Second: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    private let first: First
    private let second: Second

    init(@ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.first = first()
        self.second = second()
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 10) { first; second }
        } else {
            HStack(spacing: 12) { first; second }
        }
    }
}

/// Marks a conversation read only while it is really on screen: visible (not under a pushed chat or
/// on another tab), the app in front, and `isFrontmost`. Android does this with `visibleConversation`.
struct CrowdMeshMarkRead: ViewModifier {
    /// Newest message ID: a new message on screen is read straight away.
    let newestId: String?
    var isFrontmost = true
    let markRead: @MainActor () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                markIfSeen(visible: true, frontmost: isFrontmost, phase: scenePhase)
            }
            .onDisappear { isVisible = false }
            .onChange(of: newestId) { _ in markIfSeen(visible: isVisible, frontmost: isFrontmost, phase: scenePhase) }
            .onChange(of: isFrontmost) { frontmost in markIfSeen(visible: isVisible, frontmost: frontmost, phase: scenePhase) }
            .onChange(of: scenePhase) { phase in markIfSeen(visible: isVisible, frontmost: isFrontmost, phase: phase) }
    }

    private func markIfSeen(visible: Bool, frontmost: Bool, phase: ScenePhase) {
        if visible && frontmost && phase == .active { markRead() }
    }
}
