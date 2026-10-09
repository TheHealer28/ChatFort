//
//  CrowdMeshIntroView.swift
//  ChatFort — Crowd mesh
//
//  The start screen: what the crowd mesh is, what others can see, the nickname, the iPhone
//  background limits, what stops it from running (Bluetooth off / not allowed / unsupported), Start.
//

import SwiftUI
import UIKit
#if canImport(InqalaabChat)
import InqalaabChat
#endif

struct CrowdMeshIntroView: View {
    @ObservedObject private var mesh = CrowdMesh.shared
    /// Blank means a random nickname (see `CrowdMeshUI.editableNickname`).
    @State private var nickname = CrowdMeshUI.editableNickname(CrowdMesh.shared.nickname)
    @FocusState private var nicknameFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // First thing on screen, and not pinned: at large text sizes a pinned card
                        // would leave no room for the rest.
                        problemCard
                        hero
                        nicknameField
                        safetyLines
                        iPhoneNote
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .id(Self.top)
                }
                .onChange(of: mesh.status) { _ in
                    withAnimation { proxy.scrollTo(Self.top, anchor: .top) }
                }
            }
            Divider()
            bottomBar
        }
    }

    private static let top = "top"

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.largeTitle)
                .foregroundColor(InqalaabGreen)
                .frame(width: heroSize, height: heroSize)
                .background(Circle().fill(InqalaabGreen.opacity(0.12)))
                .accessibilityHidden(true)
            Text("Reach everyone nearby, up to 7 hops, no internet")
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Each phone passes messages on to the next: roughly 100–300 m through a crowd. The more people run it, the further it reaches.")
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nicknameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your crowd nickname")
                .font(.headline)
            TextField("Random nickname", text: $nickname)
                .focused($nicknameFocused)
                // Applied on Start; while starting or waiting for Bluetooth, change it on People.
                .disabled(mesh.status != .stopped)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.done)
                .onSubmit { nicknameFocused = false }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemBackground)))
                .onChange(of: nickname) { value in
                    let limited = CrowdMeshUI.limitedNickname(value)
                    if limited != value { nickname = limited }
                }
            Text("Leave it blank to get a random nickname.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label {
                Text("Don't use your real name. Anyone nearby can see your nickname.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption.weight(.medium))
            .foregroundColor(.red)
        }
    }

    private var safetyLines: some View {
        VStack(alignment: .leading, spacing: 16) {
            safetyLine(
                icon: "megaphone.fill",
                title: Text("Everyone"),
                detail: Text("Anyone nearby can read it. Never post names, plans or where people at risk are.")
            )
            safetyLine(
                icon: "person.3.fill",
                title: Text("Teams"),
                detail: Text("Only team members can read it. Share team codes face to face.")
            )
            safetyLine(
                icon: "lock.fill",
                title: Text("People"),
                detail: Text("Private messages: only the person you write to can read them.")
            )
            safetyLine(
                icon: "dot.radiowaves.left.and.right",
                title: Text("Bluetooth"),
                detail: Text("Bluetooth makes your phone detectable nearby. Stop the crowd mesh when you don't need it.")
            )
            safetyLine(
                icon: "battery.25",
                title: Text("Battery"),
                detail: Text("It uses extra battery. Carry a power bank if you can.")
            )
        }
    }

    private func safetyLine(icon: String, title: Text, detail: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(InqalaabGreen)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.subheadline.weight(.semibold))
                detail
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// iOS only: a backgrounded iPhone stops advertising in a way other phones can find.
    private var iPhoneNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "iphone")
                .foregroundColor(.orange)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep ChatFort open for the best reach.")
                    .font(.subheadline.weight(.semibold))
                Text("In the background, this iPhone can still reach phones nearby, but most phones can't find it until ChatFort is open again.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Start

    /// Once started, the mesh waits for Bluetooth by itself (on again, or allowed in Settings) and
    /// runs as soon as it can, so problems offer guidance and Cancel rather than "try again".
    private var bottomBar: some View {
        VStack(spacing: 10) {
            switch mesh.status {
            case .stopped:
                primaryButton(enabled: true) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .accessibilityHidden(true)
                    Text("Start crowd mesh")
                }
            case .starting:
                primaryButton(enabled: false) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("Starting…")
                }
            case .bluetoothOff:
                primaryButton(enabled: false) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("Waiting for Bluetooth…")
                }
            case .unauthorized, .unsupported, .running:
                EmptyView()
            }
            if mesh.status != .stopped {
                // Let people back out, or the phone starts advertising later, when they turn
                // Bluetooth on for something else.
                Button("Cancel") { mesh.stop() }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder private var problemCard: some View {
        switch mesh.status {
        case .bluetoothOff:
            problem(title: Text("Bluetooth is off"), detail: Text("Turn on Bluetooth in Control Centre."))
        case .unauthorized:
            problem(title: Text("Bluetooth isn't allowed"), detail: Text("Allow Bluetooth for ChatFort in Settings."), opensSettings: true)
        case .unsupported:
            problem(title: Text("Bluetooth isn't available"), detail: Text("This device has no Bluetooth LE, which the crowd mesh needs."))
        case .stopped, .starting, .running:
            EmptyView()
        }
    }

    private func problem(title: Text, detail: Text, opensSettings: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.subheadline.weight(.semibold))
                    detail
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if opensSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(InqalaabGreen)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    private func primaryButton<Content: View>(enabled: Bool, @ViewBuilder label: () -> Content) -> some View {
        Button { start() } label: {
            HStack(spacing: 10) { label() }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(enabled ? InqalaabGreen : Color(.systemGray))
                )
        }
        .disabled(!enabled)
    }

    private func start() {
        nicknameFocused = false
        // Blank = random for this session (Android v2: random per session unless the user picks one).
        mesh.setNickname(nickname)
        mesh.start()
    }
}
