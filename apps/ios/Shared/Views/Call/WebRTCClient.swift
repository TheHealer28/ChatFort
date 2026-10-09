//
// Created by Avently on 09.02.2023.
// Copyright (c) 2023 SimpleX Chat. All rights reserved.
//

import WebRTC
import LZString
import SwiftUI
import InqalaabChat

final class WebRTCClient: NSObject, RTCVideoViewDelegate, RTCFrameEncryptorDelegate, RTCFrameDecryptorDelegate {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        // Inqalaab: MUST stay VP8. SimpleX negotiates 1:1 video on VP8; this is
        // the known-good `stable` baseline. An H.264 experiment (and then removing
        // this line entirely, leaving the factory default) both broke video —
        // local camera rendered but nothing transmitted in either direction
        // because the video codec failed to negotiate. Do not change without
        // on-device A/B verification that remote video actually flows.
        videoEncoderFactory.preferredCodec = RTCVideoCodecInfo(name: kRTCVp8CodecName)
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
    private static let ivTagBytes: Int = 28
    private static let enableEncryption: Bool = true
    private var chat_ctrl = getChatCtrl()

    struct Call {
        var connection: RTCPeerConnection
        var iceCandidates: IceCandidates
        var localCamera: RTCVideoCapturer?
        var localAudioTrack: RTCAudioTrack?
        var localVideoTrack: RTCVideoTrack?
        var remoteAudioTrack: RTCAudioTrack?
        var remoteVideoTrack: RTCVideoTrack?
        var remoteScreenAudioTrack: RTCAudioTrack?
        var remoteScreenVideoTrack: RTCVideoTrack?
        var device: AVCaptureDevice.Position
        var aesKey: String?
        var frameEncryptor: RTCFrameEncryptor?
        var frameDecryptor: RTCFrameDecryptor?
        var peerHasOldVersion: Bool
    }

    struct NotConnectedCall {
        var audioTrack: RTCAudioTrack?
        var localCameraAndTrack: (RTCVideoCapturer, RTCVideoTrack)?
        var device: AVCaptureDevice.Position = .front
    }

    actor IceCandidates {
        private var candidates: [RTCIceCandidate] = []

        func getAndClear() async -> [RTCIceCandidate] {
            let cs = candidates
            candidates = []
            return cs
        }

        func append(_ c: RTCIceCandidate) async {
            candidates.append(c)
        }
    }

    private let rtcAudioSession =  RTCAudioSession.sharedInstance()
    private let audioQueue = DispatchQueue(label: "com.inqalaab.app.audio")
    private var sendCallResponse: (WVAPIMessage) async -> Void
    // Inqalaab: when this client is one leg of a group call (N clients at once),
    // ending it must NOT deactivate the shared RTCAudioSession or close PiP —
    // that would mute/kill the other live legs. The group-call coordinator owns
    // those shared resources and restores them when the LAST leg ends.
    // Default false → 1:1 behavior unchanged.
    var groupLegMode = false
    var activeCall: Call?
    var notConnectedCall: NotConnectedCall?
    // Temporary call-quality stats logger (see startStatsDiagnostics()).
    var statsDiagnosticsTask: Task<Void, Never>? = nil
    // Inqalaab: calls survive network drops (same protocol as Android). After the
    // call has connected once, ICE `disconnected` or `failed` starts one grace
    // timer instead of ending the call. Meanwhile the side that made the original
    // offer (the `.start` command) restarts ICE over the chat channel (see "ICE
    // restart" below). The call ends only if it hasn't recovered when the timer
    // fires. `reconnect` is guarded by `reconnectLock`: the ICE delegate runs on
    // WebRTC's signaling thread, the timer on main, restart steps in tasks.
    static let reconnectGraceSeconds: TimeInterval = 30
    private struct Reconnect {
        var wasConnected = false
        var graceTimer: DispatchWorkItem?
        var isOfferer = false
        var restartLoop: Task<Void, Never>?
        var restartOpsTail: Task<Void, Never>?
        var gen = 0             // offerer: last restart generation sent
        var sentOfferGen: Int?  // offerer: generation of the offer currently set locally
        var answeredGen = 0     // answerer: last generation answered
        var newestOfferGen = 0  // answerer: newest generation received
    }
    private let reconnectLock = NSLock()
    private var reconnect = Reconnect()
    private var localRendererAspectRatio: Binding<CGFloat?>

    var cameraRenderers: [RTCVideoRenderer] = []
    var screenRenderers: [RTCVideoRenderer] = []

    @available(*, unavailable)
    override init() {
        fatalError("Unimplemented")
    }

    required init(_ sendCallResponse: @escaping (WVAPIMessage) async -> Void, _ localRendererAspectRatio: Binding<CGFloat?>, groupLegMode: Bool = false) {
        self.sendCallResponse = sendCallResponse
        self.localRendererAspectRatio = localRendererAspectRatio
        self.groupLegMode = groupLegMode
        if !groupLegMode {
            rtcAudioSession.useManualAudio = CallController.useCallKit()
            rtcAudioSession.isAudioEnabled = !CallController.useCallKit()
        }
        // Group legs must NOT touch the shared session flags: legs are created at
        // unpredictable times (some AFTER CallKit's didActivate enabled audio), and
        // this reset silenced the whole group call. The coordinator (non-CallKit)
        // or CallKit didActivate/didDeactivate own these flags for group calls.
        logger.debug("WebRTCClient: rtcAudioSession has manual audio \(self.rtcAudioSession.useManualAudio) and audio enabled \(self.rtcAudioSession.isAudioEnabled)")
        super.init()
    }

    // Inqalaab: use public STUN servers for NAT traversal
    let defaultIceServers: [WebRTC.RTCIceServer] = [
        WebRTC.RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
        WebRTC.RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"]),
    ]

    func initializeCall(_ iceServers: [WebRTC.RTCIceServer]?, _ mediaType: CallMediaType, _ aesKey: String?, _ relay: Bool?) -> Call {
        let connection = createPeerConnection(iceServers ?? getWebRTCIceServers() ?? defaultIceServers, relay)
        connection.delegate = self
        let device = notConnectedCall?.device ?? .front
        var localCamera: RTCVideoCapturer? = nil
        var localAudioTrack: RTCAudioTrack? = nil
        var localVideoTrack: RTCVideoTrack? = nil
        if let localCameraAndTrack = notConnectedCall?.localCameraAndTrack {
            (localCamera, localVideoTrack) = localCameraAndTrack
        } else if notConnectedCall == nil && mediaType == .video {
            (localCamera, localVideoTrack) = createVideoTrackAndStartCapture(device)
        }
        if let audioTrack = notConnectedCall?.audioTrack {
            localAudioTrack = audioTrack
        } else if notConnectedCall == nil {
            localAudioTrack = createAudioTrack()
        }
        notConnectedCall?.localCameraAndTrack = nil
        notConnectedCall?.audioTrack = nil

        var frameEncryptor: RTCFrameEncryptor? = nil
        var frameDecryptor: RTCFrameDecryptor? = nil
        if aesKey != nil {
            let encryptor = RTCFrameEncryptor.init(sizeChange: Int32(WebRTCClient.ivTagBytes))
            encryptor.delegate = self
            frameEncryptor = encryptor

            let decryptor = RTCFrameDecryptor.init(sizeChange: -Int32(WebRTCClient.ivTagBytes))
            decryptor.delegate = self
            frameDecryptor = decryptor
        }
        return Call(
            connection: connection,
            iceCandidates: IceCandidates(),
            localCamera: localCamera,
            localAudioTrack: localAudioTrack,
            localVideoTrack: localVideoTrack,
            device: device,
            aesKey: aesKey,
            frameEncryptor: frameEncryptor,
            frameDecryptor: frameDecryptor,
            peerHasOldVersion: false
        )
    }

    func createPeerConnection(_ iceServers: [WebRTC.RTCIceServer], _ relay: Bool?) -> RTCPeerConnection {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])

        guard let connection = WebRTCClient.factory.peerConnection(
            with: getCallConfig(iceServers, relay),
            constraints: constraints, delegate: nil
        )
        else {
            fatalError("Unable to create RTCPeerConnection")
        }
        return connection
    }

    func getCallConfig(_ iceServers: [WebRTC.RTCIceServer], _ relay: Bool?) -> RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceTransportPolicy = relay == true ? .relay : .all
        // Allows to wait 30 sec before `failing` connection if the answer from remote side is not received in time
        config.iceInactiveTimeout = 30_000
        return config
    }

    func addIceCandidates(_ connection: RTCPeerConnection, _ remoteIceCandidates: [RTCIceCandidate]) {
        remoteIceCandidates.forEach { candidate in
            connection.add(candidate.toWebRTCCandidate()) { error in
                if let error = error {
                    logger.error("Adding candidate error \(error)")
                }
            }
        }
    }

    func sendCallCommand(command: WCallCommand) async {
        var resp: WCallResponse? = nil
        let pc = activeCall?.connection
        switch command {
        case let .capabilities(media): // outgoing
            let localCameraAndTrack: (RTCVideoCapturer, RTCVideoTrack)? = media == .video
            ? createVideoTrackAndStartCapture(.front)
            : nil
            notConnectedCall = NotConnectedCall(audioTrack: createAudioTrack(), localCameraAndTrack: localCameraAndTrack, device: .front)
            resp = .capabilities(capabilities: CallCapabilities(encryption: WebRTCClient.enableEncryption))
        case let .start(media: media, aesKey, iceServers, relay): // incoming
            logger.debug("starting incoming call - create webrtc session")
            if activeCall != nil { endCall() }
            let encryption = WebRTCClient.enableEncryption
            let call = initializeCall(iceServers?.toWebRTCIceServers(), media, encryption ? aesKey : nil, relay)
            activeCall = call
            // This side makes the original offer, so it drives ICE restarts.
            withReconnect { $0.isOfferer = true }
            setupLocalTracks(true, call)
            let (offer, error) = await call.connection.offer()
            if let offer = offer {
                setupEncryptionForLocalTracks(call)
                resp = .offer(
                    offer: compressToBase64(input: encodeJSON(CustomRTCSessionDescription(type: offer.type.toSdpType(), sdp: offer.sdp))),
                    iceCandidates: compressToBase64(input: encodeJSON(await self.getInitialIceCandidates())),
                    capabilities: CallCapabilities(encryption: encryption)
                )
                self.waitForMoreIceCandidates()
            } else {
                resp = .error(message: "offer error: \(error?.localizedDescription ?? "unknown error")")
            }
        case let .offer(offer, iceCandidates, media, aesKey, iceServers, relay): // outgoing
            if activeCall != nil {
                resp = .error(message: "accept: call already started")
            } else if !WebRTCClient.enableEncryption && aesKey != nil {
                resp = .error(message: "accept: encryption is not supported")
            } else if let offer: CustomRTCSessionDescription = decodeJSON(decompressFromBase64(input: offer)),
                      let remoteIceCandidates: [RTCIceCandidate] = decodeJSON(decompressFromBase64(input: iceCandidates)) {
                let call = initializeCall(iceServers?.toWebRTCIceServers(), media, WebRTCClient.enableEncryption ? aesKey : nil, relay)
                activeCall = call
                withReconnect { $0.isOfferer = false }
                let pc = call.connection
                if let type = offer.type, let sdp = offer.sdp {
                    if (try? await pc.setRemoteDescription(RTCSessionDescription(type: type.toWebRTCSdpType(), sdp: sdp))) != nil {
                        setupLocalTracks(false, call)
                        setupEncryptionForLocalTracks(call)
                        pc.transceivers.forEach { transceiver in
                            transceiver.setDirection(.sendRecv, error: nil)
                        }
                        await adaptToOldVersion(pc.transceivers.count <= 2)
                        let (answer, error) = await pc.answer()
                        if let answer = answer {
                            self.addIceCandidates(pc, remoteIceCandidates)
                            resp = .answer(
                                answer: compressToBase64(input: encodeJSON(CustomRTCSessionDescription(type: answer.type.toSdpType(), sdp: answer.sdp))),
                                iceCandidates: compressToBase64(input: encodeJSON(await self.getInitialIceCandidates()))
                            )
                            self.waitForMoreIceCandidates()
                        } else {
                            resp = .error(message: "answer error: \(error?.localizedDescription ?? "unknown error")")
                        }
                    } else {
                        resp = .error(message: "accept: remote description is not set")
                    }
                }
            }
        case let .answer(answer, iceCandidates): // incoming
            if pc == nil {
                resp = .error(message: "answer: call not started")
            } else if pc?.localDescription == nil {
                resp = .error(message: "answer: local description is not set")
            } else if pc?.remoteDescription != nil {
                resp = .error(message: "answer: remote description already set")
            } else if let answer: CustomRTCSessionDescription = decodeJSON(decompressFromBase64(input: answer)),
                      let remoteIceCandidates: [RTCIceCandidate] = decodeJSON(decompressFromBase64(input: iceCandidates)),
                      let type = answer.type, let sdp = answer.sdp,
                      let pc = pc {
                if (try? await pc.setRemoteDescription(RTCSessionDescription(type: type.toWebRTCSdpType(), sdp: sdp))) != nil {
                    var currentDirection: RTCRtpTransceiverDirection = .sendOnly
                    if pc.transceivers.count > 2 {
                        pc.transceivers[2].currentDirection(&currentDirection)
                    }
                    await adaptToOldVersion(currentDirection == .sendOnly)
                    addIceCandidates(pc, remoteIceCandidates)
                    resp = .ok
                } else {
                    resp = .error(message: "answer: remote description is not set")
                }
            }
        case let .ice(iceCandidates):
            let extraInfo = decompressFromBase64(input: iceCandidates)
            if let pc = pc, let restart: IceRestartMessage = decodeJSON(extraInfo) {
                receiveIceRestart(restart, pc)
                resp = .ok
            } else if let pc = pc,
               let remoteIceCandidates: [RTCIceCandidate] = decodeJSON(extraInfo) {
                addIceCandidates(pc, remoteIceCandidates)
                resp = .ok
            } else {
                resp = .error(message: "ice: call not started")
            }
        case let .media(source, enable):
            if activeCall == nil {
                resp = .error(message: "media: call not started")
            } else {
                await enableMedia(source, enable)
                resp = .ok
            }
        case .end:
            // TODO possibly, endCall should be called before returning .ok
            await sendCallResponse(.init(corrId: nil, resp: .ok, command: command))
            endCall()
        }
        if let resp = resp {
            await sendCallResponse(.init(corrId: nil, resp: resp, command: command))
        }
    }

    func getInitialIceCandidates() async -> [RTCIceCandidate] {
        await untilIceComplete(timeoutMs: 750, stepMs: 150) {}
        let candidates = await activeCall?.iceCandidates.getAndClear() ?? []
        logger.debug("WebRTCClient: sending initial ice candidates: \(candidates.count)")
        return candidates
    }

    func waitForMoreIceCandidates() {
        Task {
            await untilIceComplete(timeoutMs: 12000, stepMs: 1500) {
                let candidates = await self.activeCall?.iceCandidates.getAndClear() ?? []
                if candidates.count > 0 {
                    logger.debug("WebRTCClient: sending more ice candidates: \(candidates.count)")
                    await self.sendIceCandidates(candidates)
                }
            }
        }
    }

    func sendIceCandidates(_ candidates: [RTCIceCandidate]) async {
        await self.sendCallResponse(.init(
            corrId: nil,
            resp: .ice(iceCandidates: compressToBase64(input: encodeJSON(candidates))),
            command: nil)
        )
    }

    func setupMuteUnmuteListener(_ transceiver: RTCRtpTransceiver, _ track: RTCMediaStreamTrack) {
        // logger.log("Setting up mute/unmute listener in the call without encryption for mid = \(transceiver.mid)")
        Task {
            var lastBytesReceived: Int64 = 0
            // muted initially
            var mutedSeconds = 4
            while let call = self.activeCall, transceiver.receiver.track?.readyState == .live {
                let stats: RTCStatisticsReport = await call.connection.statistics(for: transceiver.receiver)
                let stat = stats.statistics.values.first(where: { stat in stat.type == "inbound-rtp"})
                if let stat {
                    //logger.debug("Stat \(stat.debugDescription)")
                    let bytes = stat.values["bytesReceived"] as? Int64 ?? 0
                    if bytes <= lastBytesReceived {
                        mutedSeconds += 1
                        if mutedSeconds == 3 {
                            await MainActor.run {
                                self.onMediaMuteUnmute(transceiver.mid, true)
                            }
                        }
                    } else {
                        if mutedSeconds >= 3 {
                            await MainActor.run {
                                self.onMediaMuteUnmute(transceiver.mid, false)
                            }
                        }
                        lastBytesReceived = bytes
                        mutedSeconds = 0
                    }
                }
                try? await Task.sleep(nanoseconds: 1000_000000)
            }
        }
    }

    @MainActor
    func onMediaMuteUnmute(_ transceiverMid: String?, _ mute: Bool) {
        guard let activeCall = ChatModel.shared.activeCall else { return }
        let source = mediaSourceFromTransceiverMid(transceiverMid)
        logger.log("Mute/unmute \(source.rawValue) track = \(mute) with mid = \(transceiverMid ?? "nil")")
        if source == .mic && activeCall.peerMediaSources.mic == mute {
            activeCall.peerMediaSources.mic = !mute
        } else if (source == .camera && activeCall.peerMediaSources.camera == mute) {
            activeCall.peerMediaSources.camera = !mute
        } else if (source == .screenAudio && activeCall.peerMediaSources.screenAudio == mute) {
            activeCall.peerMediaSources.screenAudio = !mute
        } else if (source == .screenVideo && activeCall.peerMediaSources.screenVideo == mute) {
            activeCall.peerMediaSources.screenVideo = !mute
        }
    }

    @MainActor
    func enableMedia(_ source: CallMediaSource, _ enable: Bool) {
        logger.debug("WebRTCClient: enabling media \(source.rawValue) \(enable)")
        source == .camera ? setCameraEnabled(enable) : setAudioEnabled(enable)
    }

    @MainActor
    func adaptToOldVersion(_ peerHasOldVersion: Bool) {
        activeCall?.peerHasOldVersion = peerHasOldVersion
        if peerHasOldVersion {
            logger.debug("The peer has an old version. Remote audio track is nil = \(self.activeCall?.remoteAudioTrack == nil), video = \(self.activeCall?.remoteVideoTrack == nil)")
            onMediaMuteUnmute("0", false)
            if activeCall?.remoteVideoTrack != nil {
                onMediaMuteUnmute("1", false)
            }
            if ChatModel.shared.activeCall?.localMediaSources.camera == true && ChatModel.shared.activeCall?.peerMediaSources.camera == false {
                logger.debug("Stopping video track for the old version")
                if let senders = activeCall?.connection.senders, senders.count > 1 {
                    senders[1].track = nil
                }
                ChatModel.shared.activeCall?.localMediaSources.camera = false
                (activeCall?.localCamera as? RTCCameraVideoCapturer)?.stopCapture()
                activeCall?.localCamera = nil
                activeCall?.localVideoTrack = nil
            }
        }
    }

    func addLocalRenderer(_ renderer: RTCEAGLVideoView) {
        if let activeCall {
            if let track = activeCall.localVideoTrack {
                track.add(renderer)
            }
        } else if let notConnectedCall {
            if let track = notConnectedCall.localCameraAndTrack?.1 {
                track.add(renderer)
            }
        }
        // To get width and height of a frame, see videoView(videoView:, didChangeVideoSize)
        renderer.delegate = self
    }

    func removeLocalRenderer(_ renderer: RTCEAGLVideoView) {
        if let activeCall {
            if let track = activeCall.localVideoTrack {
                track.remove(renderer)
            }
        } else if let notConnectedCall {
            if let track = notConnectedCall.localCameraAndTrack?.1 {
                track.remove(renderer)
            }
        }
        renderer.delegate = nil
    }

    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        guard size.height > 0 else { return }
        localRendererAspectRatio.wrappedValue = size.width / size.height
    }

    func setupLocalTracks(_ incomingCall: Bool, _ call: Call) {
        let pc = call.connection
        let transceivers = call.connection.transceivers
        let audioTrack = call.localAudioTrack
        let videoTrack = call.localVideoTrack

        if incomingCall {
            let micCameraInit = RTCRtpTransceiverInit()
            // streamIds required for old versions which adds tracks from stream, not from track property
            micCameraInit.streamIds = ["micCamera"]

            let screenAudioVideoInit = RTCRtpTransceiverInit()
            screenAudioVideoInit.streamIds = ["screenAudioVideo"]

            // incoming call, no transceivers yet. But they should be added in order: mic, camera, screen audio, screen video
            // mid = 0, mic
            if let audioTrack {
                pc.addTransceiver(with: audioTrack, init: micCameraInit)
            } else {
                pc.addTransceiver(of: .audio, init: micCameraInit)
            }
            // mid = 1, camera
            if let videoTrack {
                pc.addTransceiver(with: videoTrack, init: micCameraInit)
            } else {
                pc.addTransceiver(of: .video, init: micCameraInit)
            }
            // mid = 2, screenAudio
            pc.addTransceiver(of: .audio, init: screenAudioVideoInit)
            // mid = 3, screenVideo
            pc.addTransceiver(of: .video, init: screenAudioVideoInit)
            // Inqalaab group legs: mids 4+ are pre-negotiated audio "forward
            // slots". The group-call HOST plugs other participants' live audio
            // tracks into these senders (sender.track is replaceable at runtime,
            // no renegotiation), so every participant hears everyone through
            // their single leg to the host. Negotiated in the initial offer —
            // the answering side inherits them from SDP. Idle (nil track) unless
            // the host fills them. 1:1 calls (groupLegMode=false) are untouched.
            if groupLegMode {
                let forwardInit = RTCRtpTransceiverInit()
                forwardInit.streamIds = ["groupForward"]
                for _ in 0..<(GROUP_CALL_MAX_PARTICIPANTS - 2) {
                    pc.addTransceiver(of: .audio, init: forwardInit)
                }
            }
        } else {
            // new version
            if transceivers.count > 2 {
                // Outgoing call. All transceivers are ready. Don't addTrack() because it will create new transceivers, replace existing (nil) tracks
                transceivers
                    .first(where: { elem in mediaSourceFromTransceiverMid(elem.mid) == .mic })?
                    .sender.track = audioTrack
                transceivers
                    .first(where: { elem in mediaSourceFromTransceiverMid(elem.mid) == .camera })?
                    .sender.track = videoTrack
            } else {
                // old version, only two transceivers
                if let audioTrack {
                    pc.add(audioTrack, streamIds: ["micCamera"])
                } else {
                    // it's important to have any track in order to be able to turn it on again (currently it's off)
                    let sender = pc.add(createAudioTrack(), streamIds: ["micCamera"])
                    sender?.track = nil
                }
                if let videoTrack {
                    pc.add(videoTrack, streamIds: ["micCamera"])
                } else {
                    // it's important to have any track in order to be able to turn it on again (currently it's off)
                    let localVideoSource = WebRTCClient.factory.videoSource()
                    let localVideoTrack = WebRTCClient.factory.videoTrack(with: localVideoSource, trackId: "video0")
                    let sender = pc.add(localVideoTrack, streamIds: ["micCamera"])
                    sender?.track = nil
                }
            }
        }
    }

    // MARK: - Group-call audio forwarding (host side)

    /// The live remote audio track of this leg (the participant's voice), used
    /// by the group-call host to forward into other legs' slots.
    var remoteAudioTrackForForwarding: RTCAudioTrack? {
        activeCall?.remoteAudioTrack
    }

    /// Host side: plug other participants' audio tracks into this leg's
    /// pre-negotiated forward slots (mids 4+, audio, "groupForward" stream).
    /// sender.track replacement needs no renegotiation; frames re-encode and
    /// pass through this leg's frame encryptor like the host's own mic.
    func setForwardedAudioTracks(_ tracks: [RTCAudioTrack]) {
        guard groupLegMode, let call = activeCall else { return }
        let slotMids: Set<String> = Set((4..<(4 + GROUP_CALL_MAX_PARTICIPANTS - 2)).map { String($0) })
        let slots = call.connection.transceivers.filter { t in
            t.mediaType == .audio && t.mid != nil && slotMids.contains(t.mid)
        }
        for (i, slot) in slots.enumerated() {
            let track = i < tracks.count ? tracks[i] : nil
            if slot.sender.track !== track {
                slot.sender.track = track
            }
        }
    }

    func mediaSourceFromTransceiverMid(_ mid: String?) -> CallMediaSource {
        switch mid {
        case "0":
            return .mic
        case "1":
            return .camera
        case "2":
            return .screenAudio
        case "3":
            return .screenVideo
        default:
            return .unknown
        }
    }

    // Should be called after local description set
    func setupEncryptionForLocalTracks(_ call: Call) {
        if let encryptor = call.frameEncryptor {
            call.connection.senders.forEach { $0.setRtcFrameEncryptor(encryptor) }
        }
    }

    func frameDecryptor(_ decryptor: RTCFrameDecryptor, mediaType: RTCRtpMediaType, withFrame encrypted: Data) -> Data? {
        guard encrypted.count > 0 else { return nil }
        if var key: [CChar] = activeCall?.aesKey?.cString(using: .utf8),
           let pointer: UnsafeMutableRawPointer = malloc(encrypted.count) {
            memcpy(pointer, (encrypted as NSData).bytes, encrypted.count)
            let isKeyFrame = encrypted[0] & 1 == 0
            let clearTextBytesSize = mediaType.rawValue == 0 ? 1 : isKeyFrame ? 10 : 3
            logCrypto("decrypt", chat_decrypt_media(&key, pointer.advanced(by: clearTextBytesSize), Int32(encrypted.count - clearTextBytesSize)))
            return Data(bytes: pointer, count: encrypted.count - WebRTCClient.ivTagBytes)
        } else {
            return nil
        }
    }

    func frameEncryptor(_ encryptor: RTCFrameEncryptor, mediaType: RTCRtpMediaType, withFrame unencrypted: Data) -> Data? {
        guard unencrypted.count > 0 else { return nil }
        if var key: [CChar] = activeCall?.aesKey?.cString(using: .utf8),
           let pointer: UnsafeMutableRawPointer = malloc(unencrypted.count + WebRTCClient.ivTagBytes) {
            memcpy(pointer, (unencrypted as NSData).bytes, unencrypted.count)
            let isKeyFrame = unencrypted[0] & 1 == 0
            let clearTextBytesSize = mediaType.rawValue == 0 ? 1 : isKeyFrame ? 10 : 3
            logCrypto("encrypt", chat_encrypt_media(chat_ctrl, &key, pointer.advanced(by: clearTextBytesSize), Int32(unencrypted.count + WebRTCClient.ivTagBytes - clearTextBytesSize)))
            return Data(bytes: pointer, count: unencrypted.count + WebRTCClient.ivTagBytes)
        } else {
            return nil
        }
    }

    private func logCrypto(_ op: String, _ r: UnsafeMutablePointer<CChar>?) {
        if let r = r {
            let err = fromCString(r)
            if err != "" {
                logger.error("\(op) error: \(err)")
//            } else {
//                logger.debug("\(op) ok")
            }
        }
    }

    func addRemoteCameraRenderer(_ renderer: RTCVideoRenderer) {
        if activeCall?.remoteVideoTrack != nil {
            activeCall?.remoteVideoTrack?.add(renderer)
        } else {
            cameraRenderers.append(renderer)
        }
    }

    func removeRemoteCameraRenderer(_ renderer: RTCVideoRenderer) {
        if activeCall?.remoteVideoTrack != nil {
            activeCall?.remoteVideoTrack?.remove(renderer)
        } else {
            cameraRenderers.removeAll(where: { $0.isEqual(renderer) })
        }
    }

    func addRemoteScreenRenderer(_ renderer: RTCVideoRenderer) {
        if activeCall?.remoteScreenVideoTrack != nil {
            activeCall?.remoteScreenVideoTrack?.add(renderer)
        } else {
            screenRenderers.append(renderer)
        }
    }

    func removeRemoteScreenRenderer(_ renderer: RTCVideoRenderer) {
        if activeCall?.remoteScreenVideoTrack != nil {
            activeCall?.remoteScreenVideoTrack?.remove(renderer)
        } else {
            screenRenderers.removeAll(where: { $0.isEqual(renderer) })
        }
    }

    func startCaptureLocalVideo(_ device: AVCaptureDevice.Position?, _ capturer: RTCVideoCapturer?) {
#if targetEnvironment(simulator)
        guard
            let capturer = (activeCall?.localCamera ?? notConnectedCall?.localCameraAndTrack?.0) as? RTCFileVideoCapturer
        else {
            logger.error("Unable to work with a file capturer")
            return
        }
        capturer.stopCapture()
        // Drag video file named `video.mp4` to `sounds` directory in the project from any other path in filesystem
        capturer.startCapturing(fromFileNamed: "sounds/video.mp4")
#else
        guard
            let capturer = capturer as? RTCCameraVideoCapturer,
            let camera = (RTCCameraVideoCapturer.captureDevices().first { $0.position == device })
        else {
            logger.error("Unable to find a camera or local track")
            return
        }

        let supported = RTCCameraVideoCapturer.supportedFormats(for: camera)
        let height: (AVCaptureDevice.Format) -> Int32 = { (format: AVCaptureDevice.Format) in CMVideoFormatDescriptionGetDimensions(format.formatDescription).height }
        let width: (AVCaptureDevice.Format) -> Int32 = { (format: AVCaptureDevice.Format) in CMVideoFormatDescriptionGetDimensions(format.formatDescription).width }
        // Inqalaab: capture real 720p. Camera formats are landscape-native
        // (width x height, e.g. 1280x720), so the old `height == 1280` test never
        // matched and the `height >= 480` fallback picked the FIRST ascending
        // format — 640x480. Verified on-device via CallQuality logs ("camera
        // capturing 640x480"). Prefer 1280x720 explicitly; keep the old
        // fallbacks for cameras without it. WebRTC still adapts down if CPU or
        // bandwidth can't sustain it, so this only raises the ceiling.
        let format = supported.first(where: { width($0) == 1280 && height($0) == 720 })
                    ?? supported.first(where: { height($0) == 1280 })
                    ?? supported.first(where: { height($0) >= 480 && height($0) < 1280 })
                    ?? supported.first(where: { height($0) > 1280 })
        guard
            let format = format,
            let fps = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate })
        else {
            logger.error("Unable to find any format for camera or to choose FPS")
            return
        }

        logger.debug("Format for camera is \(format.description)")

        capturer.stopCapture()
        capturer.startCapture(with: camera,
            format: format,
            fps: Int(min(24, fps.maxFrameRate)))
#endif
    }

    private func createAudioTrack() -> RTCAudioTrack {
        let audioConstrains = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = WebRTCClient.factory.audioSource(with: audioConstrains)
        let audioTrack = WebRTCClient.factory.audioTrack(with: audioSource, trackId: "audio0")
        return audioTrack
    }

    private func createVideoTrackAndStartCapture(_ device: AVCaptureDevice.Position) -> (RTCVideoCapturer, RTCVideoTrack) {
        let localVideoSource = WebRTCClient.factory.videoSource()

        #if targetEnvironment(simulator)
        let localCamera = RTCFileVideoCapturer(delegate: localVideoSource)
        #else
        let localCamera = RTCCameraVideoCapturer(delegate: localVideoSource)
        #endif

        let localVideoTrack = WebRTCClient.factory.videoTrack(with: localVideoSource, trackId: "video0")
        startCaptureLocalVideo(device, localCamera)
        return (localCamera, localVideoTrack)
    }

    func endCall() {
        if !groupLegMode {
            NotificationCenter.default.post(name: .stopCallPiP, object: nil)
        }
        let (graceTimer, restartLoop) = withReconnect { r in
            let running = (r.graceTimer, r.restartLoop)
            r = Reconnect()
            return running
        }
        graceTimer?.cancel()
        restartLoop?.cancel()
        // Stop the stats loop before close so it never races a closing connection.
        statsDiagnosticsTask?.cancel()
        statsDiagnosticsTask = nil
        // Inqalaab: always run teardown off the main thread. `connection.close()`
        // is slow (upstream already dispatched it on iOS 15 for lockups); at 720p
        // a video call has noticeably more to drain, and running it sync on main
        // froze the UI for a moment at call end. The iOS 15 path has shipped this
        // async pattern for years, so ordering is already tolerated by callers.
        DispatchQueue.global(qos: .utility).async { self._endCall() }
    }

    private func _endCall() {
        statsDiagnosticsTask?.cancel()
        statsDiagnosticsTask = nil
        (notConnectedCall?.localCameraAndTrack?.0 as? RTCCameraVideoCapturer)?.stopCapture()
        guard let call = activeCall else { return }
        logger.debug("WebRTCClient: ending the call")
        call.connection.close()
        call.connection.delegate = nil
        call.frameEncryptor?.delegate = nil
        call.frameDecryptor?.delegate = nil
        (call.localCamera as? RTCCameraVideoCapturer)?.stopCapture()
        if !groupLegMode {
            // Group legs share the audio session; the coordinator restores it
            // once, after the last leg closes.
            audioSessionToDefaults()
        }
        activeCall = nil
    }

    func untilIceComplete(timeoutMs: UInt64, stepMs: UInt64, action: @escaping () async -> Void) async {
        var t: UInt64 = 0
        repeat {
            _ = try? await Task.sleep(nanoseconds: stepMs * 1000000)
            t += stepMs
            await action()
        } while t < timeoutMs && activeCall?.connection.iceGatheringState != .complete
    }
}


/// Inqalaab: ICE restart message, sent as the `rtcIceCandidates` string of call
/// extra info (x.call.extra), same format as Android: LZString base64 of
/// {"chatfortIceRestart": "offer" | "answer", "gen": n, "sdp": "..."}.
/// Normal extra info is a JSON array of candidates, so the two can't be confused.
struct IceRestartMessage: Codable {
    var chatfortIceRestart: String
    var gen: Int
    var sdp: String
}

extension WebRTC.RTCPeerConnection {
    func mediaConstraints(iceRestart: Bool = false) -> RTCMediaConstraints {
        var mandatory = [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                         kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue]
        if iceRestart {
            mandatory[kRTCMediaConstraintsIceRestart] = kRTCMediaConstraintsValueTrue
        }
        return RTCMediaConstraints(mandatoryConstraints: mandatory, optionalConstraints: nil)
    }

    func offer(iceRestart: Bool = false) async -> (RTCSessionDescription?, Error?) {
        await withCheckedContinuation { cont in
            offer(for: mediaConstraints(iceRestart: iceRestart)) { (sdp, error) in
                self.processSDP(cont, sdp, error)
            }
        }
    }

    func answer() async -> (RTCSessionDescription?, Error?)  {
        await withCheckedContinuation { cont in
            answer(for: mediaConstraints()) { (sdp, error) in
                self.processSDP(cont, sdp, error)
            }
        }
    }

    private func processSDP(_ cont: CheckedContinuation<(RTCSessionDescription?, Error?), Never>, _ sdp: RTCSessionDescription?, _ error: Error?) {
        if let sdp = sdp {
            self.setLocalDescription(sdp, completionHandler: { (error) in
                if let error = error {
                    cont.resume(returning: (nil, error))
                } else {
                    cont.resume(returning: (sdp, nil))
                }
            })
        } else {
            cont.resume(returning: (nil, error))
        }
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ connection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        logger.debug("Connection new signaling state: \(stateChanged.rawValue)")
    }

    func peerConnection(_ connection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        logger.debug("Connection did add stream")
    }

    func peerConnection(_ connection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        logger.debug("Connection did remove stream")
    }

    func peerConnectionShouldNegotiate(_ connection: RTCPeerConnection) {
        logger.debug("Connection should negotiate")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        if let track = transceiver.receiver.track {
            DispatchQueue.main.async {
                // Doesn't work for outgoing video call (audio in video call works ok still, same as incoming call)
//                if let decryptor = self.activeCall?.frameDecryptor {
//                    transceiver.receiver.setRtcFrameDecryptor(decryptor)
//                }
                let source = self.mediaSourceFromTransceiverMid(transceiver.mid)
                switch source {
                case .mic: self.activeCall?.remoteAudioTrack = track as? RTCAudioTrack
                case .camera:
                    self.activeCall?.remoteVideoTrack = track as? RTCVideoTrack
                    self.cameraRenderers.forEach({ renderer in
                        self.activeCall?.remoteVideoTrack?.add(renderer)
                    })
                    self.cameraRenderers.removeAll()
                case .screenAudio: self.activeCall?.remoteScreenAudioTrack = track as? RTCAudioTrack
                case .screenVideo:
                    self.activeCall?.remoteScreenVideoTrack = track as? RTCVideoTrack
                    self.screenRenderers.forEach({ renderer in
                        self.activeCall?.remoteScreenVideoTrack?.add(renderer)
                    })
                    self.screenRenderers.removeAll()
                case .unknown:
                    // Group-call forward slots (mids 4+): another participant's
                    // audio relayed by the host. Attach this leg's frame
                    // decryptor so the forwarded audio decrypts (it's encrypted
                    // with this leg's key), then it auto-plays and mixes.
                    if self.groupLegMode, let decryptor = self.activeCall?.frameDecryptor {
                        transceiver.receiver.setRtcFrameDecryptor(decryptor)
                    }
                }
            }
            self.setupMuteUnmuteListener(transceiver, track)
        }
    }

    func peerConnection(_ connection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        debugPrint("Connection new connection state: \(newState.toString() ?? "" + newState.rawValue.description) \(connection.receivers)")

        guard let connectionStateString = newState.toString(),
              let iceConnectionStateString = connection.iceConnectionState.toString(),
              let iceGatheringStateString = connection.iceGatheringState.toString(),
              let signalingStateString = connection.signalingState.toString()
        else {
            return
        }
        // Decided here, in delegate order: the Task below can run out of order.
        let (endNow, beforeFirstConnect) = connectionStateChanged(newState, connection)
        Task {
            await sendCallResponse(.init(
                corrId: nil,
                resp: .connection(state: ConnectionState(
                    connectionState: connectionStateString,
                    iceConnectionState: iceConnectionStateString,
                    iceGatheringState: iceGatheringStateString,
                    signalingState: signalingStateString)
                ),
                command: nil)
            )

            switch newState {
            // Initial setup only: an ICE restart passes through `checking` again,
            // and redoing this would reset the user's speaker choice.
            case .checking where beforeFirstConnect:
                if let frameDecryptor = activeCall?.frameDecryptor {
                    connection.receivers.forEach { $0.setRtcFrameDecryptor(frameDecryptor) }
                }
                let enableSpeaker: Bool = ChatModel.shared.activeCall?.localMediaSources.hasVideo == true
                setSpeakerEnabledAndConfigureSession(enableSpeaker)
            case .connected: sendConnectedEvent(connection)
            default: ()
            }
            if endNow { endCall() }
        }
    }

    private func withReconnect<T>(_ f: (inout Reconnect) -> T) -> T {
        reconnectLock.lock()
        defer { reconnectLock.unlock() }
        return f(&reconnect)
    }

    private static func isUp(_ connection: RTCPeerConnection) -> Bool {
        connection.iceConnectionState == .connected || connection.iceConnectionState == .completed
    }

    /// Inqalaab: whether the call must end now, and whether it has never connected
    /// yet. Before the first connect, `disconnected`/`failed` end the call at once
    /// (unchanged). After it, they start one grace timer, plus ICE restarts on the
    /// offerer; reconnecting cancels both.
    private func connectionStateChanged(_ state: RTCIceConnectionState, _ connection: RTCPeerConnection) -> (endNow: Bool, beforeFirstConnect: Bool) {
        var stop: (DispatchWorkItem?, Task<Void, Never>?) = (nil, nil)
        var startGraceTimer: DispatchWorkItem?
        let result: (Bool, Bool) = withReconnect { r in
            let beforeFirstConnect = !r.wasConnected
            switch state {
            case .connected, .completed:
                r.wasConnected = true
                stop = (r.graceTimer, r.restartLoop)
                r.graceTimer = nil
                r.restartLoop = nil
                return (false, beforeFirstConnect)
            case .disconnected, .failed:
                if !r.wasConnected {
                    stop = (r.graceTimer, nil)
                    r.graceTimer = nil
                    return (true, beforeFirstConnect)
                }
                if r.graceTimer == nil {
                    let timer = graceTimer(connection)
                    r.graceTimer = timer
                    startGraceTimer = timer
                    if r.isOfferer { r.restartLoop = iceRestartLoop(connection) }
                }
                return (false, beforeFirstConnect)
            default:
                return (false, beforeFirstConnect)
            }
        }
        stop.0?.cancel()
        stop.1?.cancel()
        if let startGraceTimer {
            logger.debug("WebRTCClient: connection lost, waiting up to \(Int(WebRTCClient.reconnectGraceSeconds))s to recover")
            DispatchQueue.main.asyncAfter(deadline: .now() + WebRTCClient.reconnectGraceSeconds, execute: startGraceTimer)
        }
        return result
    }

    private func graceTimer(_ connection: RTCPeerConnection) -> DispatchWorkItem {
        DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            let restartLoop = self.withReconnect { r in
                let loop = r.restartLoop
                r.graceTimer = nil
                r.restartLoop = nil
                return loop
            }
            restartLoop?.cancel()
            // A newer call may have replaced this one within the grace window.
            guard self.activeCall?.connection === connection, !WebRTCClient.isUp(connection) else { return }
            logger.debug("WebRTCClient: connection did not recover, ending the call")
            self.endCall()
        }
    }

    // MARK: ICE restart (Inqalaab, same protocol as Android)
    // After a real network loss WebRTC can't recover without new ICE credentials.
    // While in the grace period the offerer re-offers with `IceRestart` every 3 s;
    // the answerer answers. Both travel as call extra info (x.call.extra).

    private func iceRestartLoop(_ connection: RTCPeerConnection) -> Task<Void, Never> {
        Task { [weak self, weak connection] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self, let connection,
                      self.activeCall?.connection === connection, !WebRTCClient.isUp(connection)
                else { return }
                await self.enqueueIceRestartStep { await self.sendIceRestartOffer(connection) }.value
            }
        }
    }

    /// Restart steps run one at a time, in order: the loop's offers, and incoming
    /// restart messages (several queued ones can arrive together).
    @discardableResult
    private func enqueueIceRestartStep(_ step: @escaping () async -> Void) -> Task<Void, Never> {
        withReconnect { r in
            let previous = r.restartOpsTail
            let task = Task {
                await previous?.value
                await step()
            }
            r.restartOpsTail = task
            return task
        }
    }

    /// Offerer: one restart attempt. Sends nothing while there is no network yet
    /// (no candidates in the new offer); the loop tries again.
    private func sendIceRestartOffer(_ connection: RTCPeerConnection) async {
        guard activeCall?.connection === connection, !WebRTCClient.isUp(connection) else { return }
        // From here an answer to an older offer is stale.
        withReconnect { $0.sentOfferGen = nil }
        if connection.signalingState == .haveLocalOffer {
            do {
                try await connection.setLocalDescription(RTCSessionDescription(type: .rollback, sdp: ""))
            } catch {
                logger.error("WebRTCClient: ICE restart rollback error: \(error.localizedDescription)")
            }
        }
        let (offer, error) = await connection.offer(iceRestart: true)
        guard offer != nil else {
            logger.error("WebRTCClient: ICE restart offer error: \(error?.localizedDescription ?? "unknown error")")
            return
        }
        await waitForIceGathering(connection)
        guard let sdp = connection.localDescription?.sdp, sdp.contains("a=candidate:") else {
            logger.debug("WebRTCClient: ICE restart: no network yet")
            return
        }
        let gen = withReconnect { r in
            r.gen += 1
            r.sentOfferGen = r.gen
            return r.gen
        }
        logger.debug("WebRTCClient: ICE restart: sending offer \(gen)")
        await sendIceRestart(IceRestartMessage(chatfortIceRestart: "offer", gen: gen, sdp: sdp))
    }

    private func receiveIceRestart(_ msg: IceRestartMessage, _ connection: RTCPeerConnection) {
        if msg.chatfortIceRestart == "offer" {
            withReconnect { $0.newestOfferGen = max($0.newestOfferGen, msg.gen) }
        }
        enqueueIceRestartStep { [weak self] in await self?.processIceRestart(msg, connection) }
    }

    private func processIceRestart(_ msg: IceRestartMessage, _ connection: RTCPeerConnection) async {
        guard activeCall?.connection === connection else { return }
        switch msg.chatfortIceRestart {
        case "offer":
            // Answerer only; skip already-answered and superseded (queued) offers.
            let answer = withReconnect { r in
                guard !r.isOfferer, msg.gen > r.answeredGen, msg.gen >= r.newestOfferGen else { return false }
                r.answeredGen = msg.gen
                return true
            }
            guard answer else { return }
            do {
                try await connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: msg.sdp))
            } catch {
                logger.error("WebRTCClient: ICE restart: remote offer error: \(error.localizedDescription)")
                return
            }
            let (localAnswer, error) = await connection.answer()
            guard localAnswer != nil else {
                logger.error("WebRTCClient: ICE restart answer error: \(error?.localizedDescription ?? "unknown error")")
                return
            }
            await waitForIceGathering(connection)
            guard let sdp = connection.localDescription?.sdp else { return }
            logger.debug("WebRTCClient: ICE restart: sending answer \(msg.gen)")
            await sendIceRestart(IceRestartMessage(chatfortIceRestart: "answer", gen: msg.gen, sdp: sdp))
        case "answer":
            // Offerer only; anything but the answer to the offer set now is stale.
            let current = withReconnect { r in r.isOfferer && r.sentOfferGen == msg.gen }
            guard current, connection.signalingState == .haveLocalOffer else { return }
            do {
                try await connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: msg.sdp))
                logger.debug("WebRTCClient: ICE restart: applied answer \(msg.gen)")
            } catch {
                logger.error("WebRTCClient: ICE restart: remote answer error: \(error.localizedDescription)")
            }
        default: ()
        }
    }

    /// Until ICE gathering completes, at most 4 s. With continual gathering it may
    /// never "complete"; candidates gathered so far are in the local description.
    private func waitForIceGathering(_ connection: RTCPeerConnection) async {
        var waitedMs = 0
        while connection.iceGatheringState != .complete && waitedMs < 4000 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waitedMs += 200
        }
    }

    private func sendIceRestart(_ msg: IceRestartMessage) async {
        await sendCallResponse(.init(
            corrId: nil,
            resp: .ice(iceCandidates: compressToBase64(input: encodeJSON(msg))),
            command: nil)
        )
    }

    func peerConnection(_ connection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        logger.debug("connection new gathering state: \(newState.toString() ?? "" + newState.rawValue.description)")
    }

    func peerConnection(_ connection: RTCPeerConnection, didGenerate candidate: WebRTC.RTCIceCandidate) {
//        logger.debug("Connection generated candidate \(candidate.debugDescription)")
        Task {
            await self.activeCall?.iceCandidates.append(candidate.toCandidate(nil, nil))
        }
    }

    func peerConnection(_ connection: RTCPeerConnection, didRemove candidates: [WebRTC.RTCIceCandidate]) {
        logger.debug("Connection did remove candidates")
    }

    func peerConnection(_ connection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ connection: RTCPeerConnection,
                        didChangeLocalCandidate local: WebRTC.RTCIceCandidate,
                        remoteCandidate remote: WebRTC.RTCIceCandidate,
                        lastReceivedMs lastDataReceivedMs: Int32,
                        changeReason reason: String) {
//        logger.debug("Connection changed candidate \(reason) \(remote.debugDescription) \(remote.description)")
    }

    // Inqalaab: call-quality diagnostics, DEBUG BUILDS ONLY (no-op in release).
    // Logs every 5s what the video encoder is actually doing: capture resolution
    // vs encoded/sent resolution, and qualityLimitationReason ("cpu" = software
    // VP8 encode can't keep up; "bandwidth" = network estimate is throttling;
    // "none" = sending at full quality). This evidence found the 640x480-capture
    // and 685kbps-cap bugs — keep it for development.
    private func startStatsDiagnostics() {
        #if !DEBUG
        return
        #endif
        statsDiagnosticsTask?.cancel()
        statsDiagnosticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled,
                      let connection = self?.activeCall?.connection,
                      connection.signalingState != .closed
                else { return }
                let report: RTCStatisticsReport = await withCheckedContinuation { cont in
                    connection.statistics { cont.resume(returning: $0) }
                }
                for stat in report.statistics.values {
                    let kind = stat.values["kind"] as? String
                    if stat.type == "outbound-rtp", kind == "video" {
                        let w = (stat.values["frameWidth"] as? NSNumber)?.intValue ?? 0
                        let h = (stat.values["frameHeight"] as? NSNumber)?.intValue ?? 0
                        let fps = (stat.values["framesPerSecond"] as? NSNumber)?.intValue ?? 0
                        let target = (stat.values["targetBitrate"] as? NSNumber)?.intValue ?? 0
                        let reason = stat.values["qualityLimitationReason"] as? String ?? "?"
                        logger.debug("CallQuality: SENDING video \(w)x\(h) @\(fps)fps target \(target / 1000) kbps — limited by: \(reason)")
                    } else if stat.type == "media-source", kind == "video" {
                        let w = (stat.values["width"] as? NSNumber)?.intValue ?? 0
                        let h = (stat.values["height"] as? NSNumber)?.intValue ?? 0
                        let fps = (stat.values["framesPerSecond"] as? NSNumber)?.intValue ?? 0
                        logger.debug("CallQuality: camera capturing \(w)x\(h) @\(fps)fps")
                    } else if stat.type == "inbound-rtp", kind == "video" {
                        let w = (stat.values["frameWidth"] as? NSNumber)?.intValue ?? 0
                        let h = (stat.values["frameHeight"] as? NSNumber)?.intValue ?? 0
                        let fps = (stat.values["framesPerSecond"] as? NSNumber)?.intValue ?? 0
                        logger.debug("CallQuality: receiving video \(w)x\(h) @\(fps)fps")
                    }
                }
            }
        }
    }

    // Inqalaab: raise the camera video sender's bitrate ceiling once connected.
    // On-device CallQuality logs showed sending capped at ~685 kbps target,
    // "limited by: bandwidth", which forces 480x360 even on good networks —
    // libwebrtc's default video cap is conservative. 2 Mbps comfortably carries
    // VP8 720p@24. This is a CEILING for the congestion estimator, not a fixed
    // rate: on genuinely weak networks the estimator still ramps down as before.
    // Only the camera transceiver (mid "1") is touched — not screen share.
    private func applyVideoSenderQuality(_ connection: WebRTC.RTCPeerConnection) {
        guard let sender = connection.transceivers.first(where: { $0.mid == "1" })?.sender else { return }
        let params = sender.parameters
        params.encodings.forEach { $0.maxBitrateBps = NSNumber(value: 2_000_000) }
        sender.parameters = params
        logger.debug("WebRTCClient: video sender max bitrate raised to 2 Mbps")
    }

    func sendConnectedEvent(_ connection: WebRTC.RTCPeerConnection) {
        applyVideoSenderQuality(connection)
        startStatsDiagnostics()
        connection.statistics { (stats: RTCStatisticsReport) in
            stats.statistics.values.forEach { stat in
//                logger.debug("Stat \(stat.debugDescription)")
                if stat.type == "candidate-pair", stat.values["state"] as? String == "succeeded",
                   let localId = stat.values["localCandidateId"] as? String,
                   let remoteId = stat.values["remoteCandidateId"] as? String,
                   let localStats = stats.statistics[localId],
                   let remoteStats = stats.statistics[remoteId]
                {
                    Task {
                        await self.sendCallResponse(.init(
                            corrId: nil,
                            resp: .connected(connectionInfo: ConnectionInfo(
                                localCandidate: RTCIceCandidate(
                                    candidateType: RTCIceCandidateType.init(rawValue: (localStats.values["candidateType"] as? String) ?? "unknown"),
                                    protocol: localStats.values["protocol"] as? String,
                                    sdpMid: nil,
                                    sdpMLineIndex: nil,
                                    candidate: ""
                                ),
                                remoteCandidate: RTCIceCandidate(
                                    candidateType: RTCIceCandidateType.init(rawValue: (remoteStats.values["candidateType"] as? String) ?? "unknown"),
                                    protocol: remoteStats.values["protocol"] as? String,
                                    sdpMid: nil,
                                    sdpMLineIndex: nil,
                                    candidate: ""))),
                            command: nil)
                        )
                    }
                }
            }
        }
    }
}

extension WebRTCClient {
    static func isAuthorized(for type: AVMediaType) async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: type)
        var isAuthorized = status == .authorized
        if status == .notDetermined {
            isAuthorized = await AVCaptureDevice.requestAccess(for: type)
        }
        return isAuthorized
    }

    static func showUnauthorizedAlert(for type: AVMediaType) {
        if type == .audio {
            AlertManager.shared.showAlert(Alert(
                title: Text("No permission to record speech"),
                message: Text("To record speech please grant permission to use Microphone."),
                primaryButton: .default(Text("Open Settings")) {
                    DispatchQueue.main.async {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
                    }
                },
                secondaryButton: .cancel()
            ))
        } else if type == .video {
            AlertManager.shared.showAlert(Alert(
                title: Text("No permission to record video"),
                message: Text("To record video please grant permission to use Camera."),
                primaryButton: .default(Text("Open Settings")) {
                    DispatchQueue.main.async {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
                    }
                },
                secondaryButton: .cancel()
            ))
        }
    }

    func setSpeakerEnabledAndConfigureSession( _ enabled: Bool, skipExternalDevice: Bool = false) {
        logger.debug("WebRTCClient: configuring session with speaker enabled \(enabled)")
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.rtcAudioSession.lockForConfiguration()
            defer {
                self.rtcAudioSession.unlockForConfiguration()
            }
            do {
                let hasExternalAudioDevice = self.rtcAudioSession.session.hasExternalAudioDevice()
                if enabled {
                    try self.rtcAudioSession.setCategory(AVAudioSession.Category.playAndRecord.rawValue, with: [.defaultToSpeaker, .allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
                    try self.rtcAudioSession.setMode(AVAudioSession.Mode.videoChat.rawValue)
                    if hasExternalAudioDevice && !skipExternalDevice, let preferred = self.rtcAudioSession.session.preferredInputDevice() {
                        try self.rtcAudioSession.setPreferredInput(preferred)
                    } else {
                        try self.rtcAudioSession.overrideOutputAudioPort(.speaker)
                    }
                } else {
                    try self.rtcAudioSession.setCategory(AVAudioSession.Category.playAndRecord.rawValue, with: [.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP])
                    try self.rtcAudioSession.setMode(AVAudioSession.Mode.voiceChat.rawValue)
                    try self.rtcAudioSession.overrideOutputAudioPort(.none)
                }
                if hasExternalAudioDevice && !skipExternalDevice {
                    logger.debug("WebRTCClient: configuring session with external device available, skip configuring speaker")
                }
                try self.rtcAudioSession.setActive(true)
                logger.debug("WebRTCClient: configuring session with speaker enabled \(enabled) success")
            } catch let error {
                logger.debug("Error configuring AVAudioSession: \(error)")
            }
        }
    }

    func audioSessionToDefaults() {
        logger.debug("WebRTCClient: audioSession to defaults")
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.rtcAudioSession.lockForConfiguration()
            defer {
                self.rtcAudioSession.unlockForConfiguration()
            }
            do {
                try self.rtcAudioSession.setCategory(AVAudioSession.Category.ambient.rawValue)
                try self.rtcAudioSession.setMode(AVAudioSession.Mode.default.rawValue)
                try self.rtcAudioSession.overrideOutputAudioPort(.none)
                try self.rtcAudioSession.setActive(false)
                logger.debug("WebRTCClient: audioSession to defaults success")
            } catch let error {
                logger.debug("Error configuring AVAudioSession with defaults: \(error)")
            }
        }
    }

    @MainActor
    func setAudioEnabled(_ enabled: Bool) {
        if activeCall != nil {
            activeCall?.localAudioTrack = enabled ? createAudioTrack() : nil
            activeCall?.connection.transceivers.first(where: { t in mediaSourceFromTransceiverMid(t.mid) == .mic })?.sender.track = activeCall?.localAudioTrack
        } else if notConnectedCall != nil {
            notConnectedCall?.audioTrack = enabled ? createAudioTrack() : nil
        }
        ChatModel.shared.activeCall?.localMediaSources.mic = enabled
    }

    @MainActor
    func setCameraEnabled(_ enabled: Bool) {
        if let call = activeCall {
            if enabled {
                if call.localVideoTrack == nil {
                    let device = activeCall?.device ?? notConnectedCall?.device ?? .front
                    let (camera, track) = createVideoTrackAndStartCapture(device)
                    activeCall?.localCamera = camera
                    activeCall?.localVideoTrack = track
                }
            } else {
                (call.localCamera as? RTCCameraVideoCapturer)?.stopCapture()
                activeCall?.localCamera = nil
                activeCall?.localVideoTrack = nil
            }
            call.connection.transceivers
                .first(where: { t in mediaSourceFromTransceiverMid(t.mid) == .camera })?
                .sender.track = activeCall?.localVideoTrack
            ChatModel.shared.activeCall?.localMediaSources.camera = activeCall?.localVideoTrack != nil
        } else if let call = notConnectedCall {
            if enabled {
                let device = activeCall?.device ?? notConnectedCall?.device ?? .front
                notConnectedCall?.localCameraAndTrack = createVideoTrackAndStartCapture(device)
            } else {
                (call.localCameraAndTrack?.0 as? RTCCameraVideoCapturer)?.stopCapture()
                notConnectedCall?.localCameraAndTrack = nil
            }
            ChatModel.shared.activeCall?.localMediaSources.camera = notConnectedCall?.localCameraAndTrack != nil
        }
    }

    func flipCamera() {
        let device = activeCall?.device ?? notConnectedCall?.device
        if activeCall != nil {
            activeCall?.device = device == .front ? .back : .front
        } else {
            notConnectedCall?.device = device == .front ? .back : .front
        }
        startCaptureLocalVideo(
            activeCall?.device ?? notConnectedCall?.device,
            (activeCall?.localCamera ?? notConnectedCall?.localCameraAndTrack?.0) as? RTCCameraVideoCapturer
        )
    }
}

extension AVAudioSession {
    func hasExternalAudioDevice() -> Bool {
        availableInputs?.allSatisfy({ $0.portType == .builtInMic }) != true
    }

    func preferredInputDevice() -> AVAudioSessionPortDescription? {
//        logger.debug("Preferred input device: \(String(describing: self.availableInputs?.filter({ $0.portType != .builtInMic })))")
        return availableInputs?.filter({ $0.portType != .builtInMic }).last
    }
}

struct CustomRTCSessionDescription: Codable {
    public var type: RTCSdpType?
    public var sdp: String?
}

enum RTCSdpType: String, Codable {
    case answer
    case offer
    case pranswer
    case rollback
}

extension RTCIceCandidate {
    func toWebRTCCandidate() -> WebRTC.RTCIceCandidate {
        WebRTC.RTCIceCandidate(
            sdp: candidate,
            sdpMLineIndex: Int32(sdpMLineIndex ?? 0),
            sdpMid: sdpMid
        )
    }
}

extension WebRTC.RTCIceCandidate {
    func toCandidate(_ candidateType: RTCIceCandidateType?, _ protocol: String?) -> RTCIceCandidate {
        RTCIceCandidate(
            candidateType: candidateType,
            protocol: `protocol`,
            sdpMid: sdpMid,
            sdpMLineIndex: Int(sdpMLineIndex),
            candidate: sdp
        )
    }
}


extension [RTCIceServer] {
    func toWebRTCIceServers() -> [WebRTC.RTCIceServer] {
        self.map {
            WebRTC.RTCIceServer(
                urlStrings: $0.urls,
                username: $0.username,
                credential: $0.credential
            ) }
    }
}

extension RTCSdpType {
    func toWebRTCSdpType() -> WebRTC.RTCSdpType {
        switch self {
        case .answer: return WebRTC.RTCSdpType.answer
        case .offer: return WebRTC.RTCSdpType.offer
        case .pranswer: return WebRTC.RTCSdpType.prAnswer
        case .rollback: return WebRTC.RTCSdpType.rollback
        }
    }
}

extension WebRTC.RTCSdpType {
    func toSdpType() -> RTCSdpType {
        switch self {
        case .answer: return RTCSdpType.answer
        case .offer: return RTCSdpType.offer
        case .prAnswer: return RTCSdpType.pranswer
        case .rollback: return RTCSdpType.rollback
        default: return RTCSdpType.answer // should never be here
        }
    }
}

extension RTCPeerConnectionState {
    func toString() -> String? {
        switch self {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed: return"failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        default: return nil // unknown
        }
    }
}

extension RTCIceConnectionState {
    func toString() -> String? {
        switch self {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        default: return nil // unknown or unused on the other side
        }
    }
}

extension RTCIceGatheringState {
    func toString() -> String? {
        switch self {
        case .new: return "new"
        case .gathering: return "gathering"
        case .complete: return "complete"
        default: return nil // unknown
        }
    }
}

extension RTCSignalingState {
    func toString() -> String? {
        switch self {
        case .stable: return "stable"
        case .haveLocalOffer: return "have-local-offer"
        case .haveLocalPrAnswer: return "have-local-pranswer"
        case .haveRemoteOffer: return "have-remote-offer"
        case .haveRemotePrAnswer: return "have-remote-pranswer"
        case .closed: return "closed"
        default: return nil // unknown
        }
    }
}
