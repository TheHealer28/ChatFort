//
//  InqalaabShakeDetector.swift
//  Inqalaab (iOS)
//
//  Detects device shake gestures and triggers panic wipe when the
//  configured threshold is reached within a 10-second window.
//
//  Architecture:
//  1. UIWindow extension posts .deviceDidShake on every shake event
//  2. InqalaabShakeDetector counts shakes within a rolling time window
//  3. When count >= threshold AND panic mode is enabled → triggers PanicWipeManager
//

import UIKit
import Foundation

// MARK: - Shake Notification

extension Notification.Name {
    static let deviceDidShake = Notification.Name("InqalaabDeviceDidShake")
}

// MARK: - UIWindow Extension (global shake capture)
// UIWindow is an Objective-C class, so Swift can override its methods
// in extensions via the runtime. This is the standard iOS pattern
// for intercepting shake gestures app-wide.

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
    }
}

// MARK: - Shake Detector

class InqalaabShakeDetector {
    static let shared = InqalaabShakeDetector()

    /// Rolling window of shake timestamps
    private var shakeTimestamps: [Date] = []

    /// Shakes must occur within this window to count toward the threshold
    private let timeWindow: TimeInterval = 10.0

    /// Whether the detector is actively listening
    private var isListening = false

    private init() {}

    /// Start listening for shake events. Call once at app launch.
    func start() {
        guard !isListening else { return }
        isListening = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShake),
            name: .deviceDidShake,
            object: nil
        )
        print("Inqalaab: Shake detector started")
    }

    /// Stop listening. Called during wipe or shutdown.
    func stop() {
        isListening = false
        NotificationCenter.default.removeObserver(self, name: .deviceDidShake, object: nil)
        shakeTimestamps.removeAll()
        print("Inqalaab: Shake detector stopped")
    }

    @objc private func handleShake() {
        // Only process if panic mode is enabled by the user
        guard UserDefaults.standard.bool(forKey: INQALAAB_PANIC_ENABLED) else { return }

        // Don't trigger during an ongoing wipe
        guard !PanicWipeManager.shared.wipeInProgress else { return }

        let now = Date()
        let threshold = UserDefaults.standard.integer(forKey: INQALAAB_PANIC_SHAKE_COUNT)
        let effectiveThreshold = threshold >= 3 ? threshold : 5

        // Prune timestamps outside the rolling window
        shakeTimestamps = shakeTimestamps.filter { now.timeIntervalSince($0) <= timeWindow }

        // Record this shake
        shakeTimestamps.append(now)

        print("Inqalaab: Shake detected (\(shakeTimestamps.count)/\(effectiveThreshold) in \(timeWindow)s window)")

        if shakeTimestamps.count >= effectiveThreshold {
            print("Inqalaab: PANIC THRESHOLD REACHED — triggering emergency wipe!")
            shakeTimestamps.removeAll()

            // Stop listening to prevent re-trigger during wipe
            stop()

            // Trigger the wipe
            PanicWipeManager.shared.performPanicWipe()
        }
    }
}
