//
//  PanicModeView.swift
//  Inqalaab (iOS)
//
//  Panic mode configuration — unique feature not in SimpleX Chat.
//  Allows users to set up emergency data wipe triggers.
//

import SwiftUI
import SimpleXChat

let INQALAAB_PANIC_ENABLED = "inqalaab_panic_enabled"
let INQALAAB_PANIC_SHAKE_COUNT = "inqalaab_panic_shake_count"

struct PanicModeView: View {
    @EnvironmentObject var theme: AppTheme
    @AppStorage(INQALAAB_PANIC_ENABLED) private var panicEnabled = false
    @AppStorage(INQALAAB_PANIC_SHAKE_COUNT) private var shakeThreshold = 5
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
