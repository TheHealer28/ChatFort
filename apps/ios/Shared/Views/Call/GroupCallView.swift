//
//  GroupCallView.swift
//  Inqalaab (iOS)
//
//  Group-call UI (increment 3): full-screen call screen with participant list,
//  mute/speaker controls and timer; incoming-call ring screen (non-CallKit
//  consent path); and the compact collapsed panel.
//

import SwiftUI
import InqalaabChat

// MARK: - Full-screen active call

struct GroupCallScreen: View {
    @ObservedObject var coordinator = GroupCallCoordinator.shared

    var body: some View {
        if let call = coordinator.activeGroupCall {
            GroupCallScreenContent(call: call, coordinator: coordinator)
        }
    }
}

private struct GroupCallScreenContent: View {
    @ObservedObject var call: GroupCall
    @ObservedObject var coordinator: GroupCallCoordinator

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                // Header
                HStack {
                    Button {
                        coordinator.callViewCollapsed = true
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.8))
                            .padding(8)
                    }
                    Spacer()
                }
                .padding(.horizontal)

                VStack(spacing: 6) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 40))
                        .foregroundColor(InqalaabGreen)
                    Text(call.groupName)
                        .font(.title2.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    callTimer
                    Text("\(call.connectedCount + 1) of \(call.totalCount) on the call")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }

                // Participants
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(call.orderedParticipants) { p in
                            GroupCallParticipantRow(participant: p)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                Spacer()

                // Controls
                HStack(spacing: 40) {
                    controlButton(
                        icon: coordinator.micEnabled ? "mic.fill" : "mic.slash.fill",
                        label: coordinator.micEnabled ? "Mute" : "Unmute",
                        active: !coordinator.micEnabled
                    ) {
                        coordinator.setMicEnabled(!coordinator.micEnabled)
                    }
                    controlButton(
                        icon: coordinator.speakerEnabled ? "speaker.wave.3.fill" : "speaker.fill",
                        label: "Speaker",
                        active: coordinator.speakerEnabled
                    ) {
                        coordinator.setSpeakerEnabled(!coordinator.speakerEnabled)
                    }
                    VStack(spacing: 6) {
                        Button {
                            coordinator.endGroupCall()
                        } label: {
                            Image(systemName: "phone.down.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(Color.red))
                        }
                        Text("End")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(.bottom, 36)
            }
        }
    }

    @ViewBuilder private var callTimer: some View {
        if let startedAt = call.startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { _ in
                Text(durationText(from: startedAt))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
            }
        } else {
            Text("Connecting…")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private func durationText(from start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func controlButton(icon: String, label: LocalizedStringKey, active: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(active ? .black : .white)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(active ? Color.white : Color.white.opacity(0.2)))
            }
            Text(label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
    }
}

// MARK: - Incoming ring (non-CallKit consent path)

struct IncomingGroupCallView: View {
    @ObservedObject var coordinator = GroupCallCoordinator.shared

    var body: some View {
        if let pending = coordinator.pendingIncomingCall {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 24) {
                    Spacer()
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 56))
                        .foregroundColor(InqalaabGreen)
                    VStack(spacing: 8) {
                        Text(pending.groupName)
                            .font(.title.weight(.semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("Group call from \(pending.callerName)")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Spacer()
                    HStack(spacing: 60) {
                        VStack(spacing: 8) {
                            Button {
                                coordinator.declinePendingCall()
                            } label: {
                                Image(systemName: "phone.down.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                                    .frame(width: 72, height: 72)
                                    .background(Circle().fill(Color.red))
                            }
                            Text("Decline")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        VStack(spacing: 8) {
                            Button {
                                coordinator.acceptPendingCall()
                            } label: {
                                Image(systemName: "phone.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                                    .frame(width: 72, height: 72)
                                    .background(Circle().fill(Color.green))
                            }
                            Text("Accept")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding(.bottom, 48)
                }
            }
            .onAppear { SoundPlayer.shared.startRingtone() }
            .onDisappear { SoundPlayer.shared.stopRingtone() }
        }
    }
}

// MARK: - Collapsed compact panel

struct GroupCallPanel: View {
    @ObservedObject var coordinator = GroupCallCoordinator.shared

    var body: some View {
        if let call = coordinator.activeGroupCall, coordinator.callViewCollapsed {
            GroupCallPanelContent(call: call, coordinator: coordinator)
        }
    }
}

private struct GroupCallPanelContent: View {
    @ObservedObject var call: GroupCall
    @ObservedObject var coordinator: GroupCallCoordinator

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.and.waveform.fill")
                .foregroundColor(InqalaabGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.groupName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(call.connectedCount + 1) of \(call.totalCount) on the call")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                coordinator.endGroupCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.red))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.thinMaterial))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            coordinator.callViewCollapsed = false
        }
    }
}

private struct GroupCallParticipantRow: View {
    @ObservedObject var participant: GroupCallParticipant

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
            Text(participant.displayName)
                .font(.body)
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
            Text(participant.state.text)
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
    }

    private var dotColor: Color {
        switch participant.state {
        case .connected: return .green
        case .connecting, .invited: return .orange
        case .reconnecting: return .yellow
        case .failed, .left, .unreachable: return .gray
        }
    }
}
