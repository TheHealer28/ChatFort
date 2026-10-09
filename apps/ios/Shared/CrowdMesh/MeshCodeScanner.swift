//
//  MeshCodeScanner.swift
//  ChatFort — Crowd mesh
//
//  Camera scanner for team QR codes. Reuses the New chat scanner (it asks for camera access).
//

import SwiftUI

struct MeshCodeScanner: View {
    var onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showScanner = true

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                ScannerInView(showQRCodeScanner: $showScanner, processQRCode: { resp in
                    if case let .success(r) = resp {
                        onScan(r.string)
                        dismiss()
                    }
                }, scanMode: .oncePerCode)
                Text("Point the camera at a team QR code.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
            }
            .padding(.top)
            .navigationTitle("Scan team code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
