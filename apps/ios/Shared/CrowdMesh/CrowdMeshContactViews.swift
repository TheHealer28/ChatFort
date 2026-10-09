//
//  CrowdMeshContactViews.swift
//  ChatFort — Crowd mesh
//
//  Wire v3 screens: your ChatFort contacts on the mesh (linked automatically while online), their
//  chat, and photos / voice notes in chats (bubbles, photo button, hold-to-record).
//

import SwiftUI
import UIKit
#if canImport(InqalaabChat)
import InqalaabChat
#endif

// MARK: - Contacts list rows

struct CrowdMeshContactRow: View {
    let contact: MeshLinkedContact

    var body: some View {
        HStack(spacing: 12) {
            CrowdMeshAvatar(systemImage: "person.crop.circle.badge.checkmark")
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: contact.name)
                        .font(.body.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let date = contact.lastMessage?.date {
                        CrowdMeshUI.shortDate(date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    CrowdMeshContactPresence(contact: contact)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if contact.unread > 0 {
                        CrowdMeshUnreadBadge(count: contact.unread)
                    }
                }
            }
            CrowdMeshChevron()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens your chat with this contact over the mesh"))
    }
}

/// "Nearby now" (green) or when they were last heard on the mesh.
struct CrowdMeshContactPresence: View {
    let contact: MeshLinkedContact

    var body: some View {
        if contact.isNearby {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill").font(.system(size: 8))
                Text("Nearby now")
            }
            .foregroundColor(InqalaabGreen)
        } else if let heard = contact.lastHeard {
            Text("Last nearby \(Text(heard, style: .relative)) ago").foregroundColor(.secondary)
        } else {
            Text("Not seen nearby").foregroundColor(.secondary)
        }
    }
}

// MARK: - Contact chat

struct CrowdMeshContactChatView: View {
    @ObservedObject private var mesh = CrowdMesh.shared
    @Environment(\.dismiss) private var dismiss
    let binding: String
    let name: String
    @State private var draft = ""
    @State private var closing = false

    private var contact: MeshLinkedContact? { mesh.linkedContacts.first { $0.id == binding } }

    var body: some View {
        let messages = mesh.contactMessages(binding)
        VStack(spacing: 0) {
            CrowdMeshStatusNotice()
            CrowdMeshBanner(icon: "lock.fill", text: Text("Your ChatFort contact. Only they can read this."),
                            detail: reach, tint: InqalaabGreen)
            CrowdMeshMessageList(messages: messages)
            CrowdMeshComposeBar(text: $draft, placeholder: "Message", attachments: {
                CrowdMeshMediaButtons { type, data, durationMs, width, height in
                    mesh.sendContactMedia(binding, type, data: data, durationMs: durationMs, width: width, height: height)
                }
            }) { mesh.sendContactText(binding, text: $0) }
        }
        .navigationTitle(Text(verbatim: contact?.name ?? name))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { mesh.openContactChat(binding) }
        .modifier(CrowdMeshMarkRead(newestId: messages.last?.id) { mesh.markRead(contact: binding) })
        // Unlinked, deleted, wiped or another profile: close (once).
        .onChange(of: contact == nil) { gone in if gone { close() } }
    }

    private var reach: Text {
        guard let contact else { return Text("Not seen nearby") }
        if contact.isNearby { return Text("Nearby now") }
        return Text("Messages wait and are sent when they're nearby (up to 24 h).")
    }

    private func close() {
        guard !closing else { return }
        closing = true
        dismiss()
    }
}

// MARK: - Media in messages

/// Decoded photos, by file name (decrypting and decoding on every redraw would be wasteful).
@MainActor
enum CrowdMeshMediaCache {
    private static let images = NSCache<NSString, UIImage>()

    static func image(_ media: MeshMediaInfo) -> UIImage? {
        guard let file = media.file else { return nil }
        if let img = images.object(forKey: file as NSString) { return img }
        guard let data = CrowdMesh.shared.mediaData(media), let img = UIImage(data: data) else { return nil }
        images.setObject(img, forKey: file as NSString)
        return img
    }

    static func clear() { images.removeAllObjects() }
}

struct CrowdMeshMediaBubble: View {
    let message: MeshChatMessage
    let media: MeshMediaInfo
    @State private var showFull = false

    var body: some View {
        Group {
            if media.failed {
                status(Text(media.kind == .photo ? "Couldn't receive this photo." : "Couldn't receive this voice note."),
                       icon: "exclamationmark.triangle")
            } else if !media.isComplete {
                VStack(alignment: .leading, spacing: 6) {
                    Label(media.kind == .photo ? "Photo" : "Voice note",
                          systemImage: media.kind == .photo ? "photo" : "waveform")
                        .font(.subheadline)
                    ProgressView(value: Double(media.received), total: Double(max(media.total, 1)))
                        .frame(width: 160)
                    Text("Receiving \(media.received)/\(media.total)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(10)
            } else if media.kind == .photo {
                photo
            } else {
                CrowdMeshVoiceRow(id: message.id, media: media)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(message.isMine ? InqalaabGreen.opacity(0.18) : Color(.systemGray5))
        )
    }

    @ViewBuilder private var photo: some View {
        if let image = CrowdMeshMediaCache.image(media) {
            Button { showFull = true } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Photo"))
            .fullScreenCover(isPresented: $showFull) { CrowdMeshPhotoViewer(image: image) }
        } else {
            status(Text("Photo"), icon: "photo")
        }
    }

    private func status(_ text: Text, icon: String) -> some View {
        Label { text } icon: { Image(systemName: icon) }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .padding(10)
    }
}

struct CrowdMeshVoiceRow: View {
    let id: String
    let media: MeshMediaInfo
    @ObservedObject private var player = MeshVoicePlayer.shared

    private var isPlaying: Bool { player.playing == id }
    private var duration: TimeInterval { TimeInterval(media.durationMs) / 1000 }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle(id) { CrowdMesh.shared.mediaData(media) }
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .foregroundColor(InqalaabGreen)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? Text("Stop") : Text("Play voice note"))
            ProgressView(value: isPlaying ? min(player.position, duration) : 0, total: max(duration, 0.1))
                .frame(width: 110)
            Text(verbatim: CrowdMeshMediaButtons.timeText(isPlaying ? player.position : duration))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

struct CrowdMeshPhotoViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(MagnificationGesture().onChanged { scale = max(1, min($0, 4)) }.onEnded { _ in
                    if scale < 1.1 { withAnimation { scale = 1 } }
                })
                .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2 } }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.white.opacity(0.85))
                    .padding()
            }
            .accessibilityLabel(Text("Close"))
        }
    }
}

// MARK: - Photo button and hold-to-record

/// Camera / photo library, and hold-to-record for voice notes. Results are already within the mesh
/// limits; `onSend` returns the controller's answer.
struct CrowdMeshMediaButtons: View {
    typealias Send = @MainActor (MeshMediaType, Data, UInt32, UInt16, UInt16) -> Result<Void, CrowdMeshError>
    let onSend: Send
    @StateObject private var recorder = MeshVoiceRecorder()
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var picked: UIImage?
    @State private var error: Text?
    @State private var cancelRecording = false
    /// The mic is held down. Resets by itself if the system cancels the touch (an alert, say).
    @GestureState private var holding = false

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Button { showLibrary = true } label: { Label("Photo library", systemImage: "photo.on.rectangle") }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                }
            } label: {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundColor(InqalaabGreen)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel(Text("Send a photo"))
            micButton
        }
        .padding(.bottom, 2)
        .sheet(isPresented: $showLibrary) {
            // Photos only: a video would be turned into a thumbnail.
            LibraryMediaListPicker(addMedia: { content in await MainActor.run { picked = content.uiImage } },
                                   selectionLimit: 1, filter: .images,
                                   didFinishPicking: { _ in await MainActor.run { showLibrary = false } })
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraImagePicker(image: $picked).ignoresSafeArea()
        }
        .onChange(of: picked) { image in
            guard let image else { return }
            picked = nil
            sendPhoto(image)
        }
        .overlay(alignment: .bottomLeading) {
            if recorder.isRecording {
                recordingPill.offset(y: -48)
            } else if let error {
                error
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemBackground)))
                    .fixedSize()
                    .offset(y: -44)
                    .onTapGesture { self.error = nil }
            }
        }
    }

    private var micButton: some View {
        Image(systemName: recorder.isRecording ? "mic.circle.fill" : "mic")
            .font(.title3)
            .foregroundColor(recorder.isRecording ? .red : InqalaabGreen)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($holding) { _, state, _ in state = true }
                    .onChanged { value in
                        // Slide away to cancel.
                        if abs(value.translation.width) > 80 || value.translation.height < -80 { cancelRecording = true }
                    }
            )
            .onChange(of: holding) { down in
                if down {
                    cancelRecording = false
                    startRecording()
                } else {
                    if cancelRecording {
                        recorder.cancel()
                    } else if recorder.isRecording {
                        finishRecording()
                    }
                    cancelRecording = false
                }
            }
            .accessibilityLabel(Text("Hold to record a voice note"))
            .accessibilityAddTraits(.isButton)
    }

    private var recordingPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "record.circle").foregroundColor(.red)
            Text(verbatim: "\(Self.timeText(recorder.elapsed)) / \(Self.timeText(recorder.timeLimit))")
                .font(.caption.monospacedDigit())
            Text(cancelRecording ? "Release to cancel" : "Release to send · slide away to cancel")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .fixedSize()
    }

    private func startRecording() {
        error = nil
        guard ChatModel.shared.activeCall == nil else {
            error = Text("You can't record during a call.")
            return
        }
        Task {
            if let e = await recorder.start() {
                error = e == .permission ? Text("Allow the microphone for ChatFort in Settings.") : Text("Couldn't record.")
            } else if !holding {
                // Released (or the touch was cancelled) before recording began.
                recorder.cancel()
            }
        }
    }

    private func finishRecording() {
        switch recorder.finish() {
        case let .success(note):
            guard note.durationMs >= 500 else { error = Text("Hold the button while you speak."); return }
            report(onSend(.voice, note.data, note.durationMs, 0, 0))
        case .failure(.tooLong):
            error = Text("Too long for the mesh. Record a shorter voice note.")
        case .failure:
            error = Text("Couldn't record.")
        }
    }

    private func sendPhoto(_ image: UIImage) {
        guard let photo = MeshPhotoEncoder.encode(image) else {
            error = Text("Couldn't make this photo small enough for the mesh.")
            return
        }
        report(onSend(.photo, photo.data, 0, UInt16(clamping: photo.width), UInt16(clamping: photo.height)))
    }

    private func report(_ result: Result<Void, CrowdMeshError>) {
        if case let .failure(e) = result { error = CrowdMeshUI.errorText(e) } else { error = nil }
    }

    static func timeText(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
