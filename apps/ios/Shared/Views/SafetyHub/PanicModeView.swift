//
//  PanicModeView.swift
//  Inqalaab (iOS)
//
//  Panic mode configuration — unique feature not in SimpleX Chat.
//  Allows users to set up emergency data wipe triggers.
//

import SwiftUI
import InqalaabChat

let INQALAAB_PANIC_ENABLED = "inqalaab_panic_enabled"
let INQALAAB_PANIC_SHAKE_COUNT = "inqalaab_panic_shake_count"
let INQALAAB_DEADMAN_ENABLED = "inqalaab_deadman_enabled"
let INQALAAB_DEADMAN_HOURS = "inqalaab_deadman_hours"
let INQALAAB_LAST_APP_OPEN = "inqalaab_last_app_open"

struct PanicModeView: View {
    @EnvironmentObject var theme: AppTheme
    @AppStorage(INQALAAB_PANIC_ENABLED) private var panicEnabled = false
    @AppStorage(INQALAAB_PANIC_SHAKE_COUNT) private var shakeThreshold = 5
    @AppStorage(INQALAAB_DEADMAN_ENABLED) private var deadmanEnabled = false
    @AppStorage(INQALAAB_DEADMAN_HOURS) private var deadmanHours = 48
    @State private var showTestAlert = false
    @State private var showEnableConfirm = false

    var body: some View {
        List {
            // SECTION: Overview
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title)
                            .foregroundColor(.orange)
                        Text("Panic Mode")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    Text("When triggered, Panic Mode immediately and permanently deletes all your messages, contacts, and profile data. Use this in emergency situations when you need to quickly protect your communications.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            // SECTION: Enable/Disable
            Section {
                Toggle(isOn: Binding(
                    get: { panicEnabled },
                    set: { newValue in
                        if newValue {
                            showEnableConfirm = true
                        } else {
                            panicEnabled = false
                        }
                    }
                )) {
                    HStack(spacing: 12) {
                        Image(systemName: "power")
                            .foregroundColor(panicEnabled ? .green : .gray)
                        Text("Enable Panic Mode")
                    }
                }
                .alert("Enable Panic Mode?", isPresented: $showEnableConfirm) {
                    Button("Cancel", role: .cancel) { }
                    Button("Enable") {
                        panicEnabled = true
                    }
                } message: {
                    Text("When panic mode is triggered, ALL data will be permanently deleted. Make sure you understand this before enabling.")
                }
            } header: {
                Text("Activation")
            }

            if panicEnabled {
                // SECTION: Trigger Method
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Shake Device")
                                .font(.body)
                            Text("Shake your device rapidly to trigger wipe")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Stepper(value: $shakeThreshold, in: 3...10) {
                        HStack {
                            Text("Shake count:")
                            Text("\(shakeThreshold) times")
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                        }
                    }
                } header: {
                    Text("Trigger Method")
                } footer: {
                    Text("Higher count = less accidental triggers. Recommended: 5+")
                }

                // SECTION: What Gets Deleted
                Section {
                    deleteRow("All messages and conversations", icon: "bubble.left.and.bubble.right")
                    deleteRow("All contacts and groups", icon: "person.2")
                    deleteRow("Your profile and address", icon: "person.crop.circle")
                    deleteRow("Server connections", icon: "server.rack")
                    deleteRow("All local files and media", icon: "photo.on.rectangle")
                } header: {
                    Text("What Gets Deleted")
                } footer: {
                    Text("This action is irreversible. There is no recovery.")
                        .foregroundColor(.red)
                }

                // SECTION: Test
                Section {
                    Button {
                        showTestAlert = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "testtube.2")
                                .foregroundColor(.blue)
                            Text("Test Panic Trigger")
                        }
                    }
                    .alert("Test Successful", isPresented: $showTestAlert) {
                        Button("OK") { }
                    } message: {
                        Text("Panic mode is configured and ready. In a real emergency, shaking your device \(shakeThreshold) times will immediately wipe all data.")
                    }
                } header: {
                    Text("Test")
                } footer: {
                    Text("This test does NOT delete any data")
                }

                // SECTION: Deadman's Switch
                Section {
                    Toggle(isOn: $deadmanEnabled) {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.badge.exclamationmark")
                                .foregroundColor(deadmanEnabled ? .orange : .gray)
                            Text("Deadman's Switch")
                        }
                    }
                    .tint(.orange)

                    if deadmanEnabled {
                        Stepper(value: $deadmanHours, in: 12...168, step: 12) {
                            HStack {
                                Text("Auto-wipe after:")
                                Text("\(deadmanHours) hours")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.orange)
                            }
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                            Text("If you don't open Inqalaab within \(deadmanHours) hours, all data will be wiped on next launch.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)

                        // Show last opened time
                        if let lastOpen = UserDefaults.standard.object(forKey: INQALAAB_LAST_APP_OPEN) as? Date {
                            HStack(spacing: 8) {
                                Image(systemName: "clock")
                                    .foregroundColor(.secondary)
                                Text("Last opened: \(lastOpen, style: .relative) ago")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Deadman's Switch")
                } footer: {
                    Text("Protects your data if you lose access to your device for an extended period")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Panic Mode")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func deleteRow(_ text: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.red.opacity(0.7))
                .frame(width: 24)
            Text(text)
                .font(.callout)
        }
    }
}
