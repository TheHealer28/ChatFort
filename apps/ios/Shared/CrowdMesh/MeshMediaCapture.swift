//
//  MeshMediaCapture.swift
//  ChatFort — Crowd mesh
//
//  Making photos and voice notes small enough for the mesh (wire v3): photos re-drawn from pixels
//  (no EXIF or location) as JPEG ≤ 48 KB with the long edge ≤ 1024; voice notes recorded as AAC-LC
//  (.m4a), mono 16 kHz, stopped before 64 512 B (about 26 s). iOS can't encode HE-AAC at 16 kHz; any
//  AAC in .m4a plays on both platforms. Plus a player for received voice notes.
//

import AVFoundation
import Foundation
import UIKit

enum MeshPhotoEncoder {
    /// JPEG within the photo limit, or nil if even a small version doesn't fit.
    static func encode(_ image: UIImage) -> (data: Data, width: Int, height: Int)? {
        var edge = CGFloat(MeshV3.photoMaxEdge)
        while edge >= 160 {
            let scaled = redraw(image, maxEdge: edge)
            for quality in stride(from: 0.7, through: 0.15, by: -0.1) {
                if let d = scaled.jpegData(compressionQuality: quality), d.count <= MeshV3.photoMaxBytes {
                    return (d, Int(scaled.size.width), Int(scaled.size.height))
                }
            }
            edge *= 0.75
        }
        return nil
    }

    /// New pixels at scale 1 (orientation applied): nothing of the original file's metadata survives.
    private static func redraw(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let size = image.size
        let factor = min(1, maxEdge / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, (size.width * factor).rounded()), height: max(1, (size.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// Records one voice note at a time to a temporary file that is deleted once read.
@MainActor
final class MeshVoiceRecorder: ObservableObject {
    enum RecordError: Error, Equatable {
        case permission
        case failed
        case tooLong
    }

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var url: URL?
    private var maxDuration: TimeInterval = 26

    /// AAC-LC, mono 16 kHz. The encoder runs above the asked rate (12 000 gives ~18.7 kbps, 16 000
    /// ~22.8 kbps), so each try comes with the longest note that stays under the limit; the size
    /// watchdog in `tick` stops earlier if a phone's encoder runs higher still.
    private static let tries: [(bitRate: Int, maxDuration: TimeInterval)] = [(12000, 26), (16000, 21), (24000, 16)]
    /// Audio bytes to stop at: the .m4a header and index (written at the end) add up to ~3 KB.
    private static let stopAtAudioBytes = MeshV3.voiceMaxBytes - 3500
    /// File size at the first tick: the header and the recorder's reserved space (cut before sending).
    private var startSize: Int?

    func start() async -> RecordError? {
        guard !isRecording else { return nil }
        guard await Self.permission() else { return .permission }
        let session = AVAudioSession.sharedInstance()
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mesh-\(UUID().uuidString).m4a")
        do {
            try session.setCategory(.playAndRecord, options: .defaultToSpeaker)
            try session.setActive(true)
        } catch {
            try? session.setCategory(.soloAmbient)
            return .failed
        }
        // A setting the encoder refuses can still create the recorder and fail only in record():
        // try the next one then.
        for t in Self.tries {
            try? FileManager.default.removeItem(at: file)
            guard let r = try? AVAudioRecorder(url: file, settings: Self.settings(bitRate: t.bitRate)),
                  r.prepareToRecord(), r.record(forDuration: t.maxDuration)
            else { continue }
            recorder = r
            url = file
            startSize = nil
            maxDuration = t.maxDuration
            isRecording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            return nil
        }
        logger.error("mesh voice: no recorder setting worked")
        try? session.setCategory(.soloAmbient)
        try? FileManager.default.removeItem(at: file)
        return .failed
    }

    /// Stops and returns the note (deleting the file), or an error if it came out too big.
    func finish() -> Result<(data: Data, durationMs: UInt32), RecordError> {
        // After the time limit the recorder has stopped by itself (currentTime 0): use the elapsed time.
        let duration = max(recorder?.currentTime ?? 0, elapsed)
        let file = url
        stopRecorder()
        guard let file, let recorded = try? Data(contentsOf: file) else { return .failure(.failed) }
        try? FileManager.default.removeItem(at: file)
        let data = MeshM4A.compact(recorded)
        guard !data.isEmpty else { return .failure(.failed) }
        guard data.count <= MeshV3.voiceMaxBytes else { return .failure(.tooLong) }
        return .success((data, UInt32(min(max(duration, 0), TimeInterval(MeshV3.voiceMaxDurationMs) / 1000) * 1000)))
    }

    func cancel() {
        let file = url
        stopRecorder()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    var timeLimit: TimeInterval { maxDuration }

    private func tick() {
        guard let r = recorder else { return }
        if r.isRecording {
            elapsed = r.currentTime
            // Near the size limit (an encoder running above the asked rate): stop here; releasing
            // the button sends what was recorded.
            if let url, let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int {
                let base = startSize ?? size
                startSize = base
                if size - base >= Self.stopAtAudioBytes {
                    r.stop()
                    timer?.invalidate()
                    timer = nil
                }
            }
        } else {
            // Hit the time limit: the recording stopped by itself.
            elapsed = maxDuration
            timer?.invalidate()
            timer = nil
        }
    }

    private func stopRecorder() {
        // Only undo the audio session if we set it: nothing was recording (a cancel during a call,
        // say) must leave the call's session alone.
        let wasRecording = recorder != nil
        recorder?.stop()
        recorder = nil
        url = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        if wasRecording { try? AVAudioSession.sharedInstance().setCategory(.soloAmbient) }
    }

    private static func settings(bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
        ]
    }

    private static func permission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { cont in
                session.requestRecordPermission { cont.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }
}

/// Plays one voice note at a time (from decrypted bytes, never written to disk).
@MainActor
final class MeshVoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = MeshVoicePlayer()

    /// The message ID being played.
    @Published private(set) var playing: String?
    @Published private(set) var position: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ id: String, data: () -> Data?) {
        if playing == id {
            stop()
            return
        }
        stop()
        guard let bytes = data(), let p = try? AVAudioPlayer(data: bytes) else { return }
        // During a call (or a recording) the session is playAndRecord: leave it alone.
        if AVAudioSession.sharedInstance().category != .playAndRecord {
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        }
        p.delegate = self
        p.prepareToPlay()
        guard p.play() else { return }
        player = p
        playing = id
        position = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.position = self?.player?.currentTime ?? 0 }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
        position = 0
        timer?.invalidate()
        timer = nil
        if AVAudioSession.sharedInstance().category == .playback {
            try? AVAudioSession.sharedInstance().setCategory(.soloAmbient)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
