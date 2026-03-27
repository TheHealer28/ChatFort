//
// Created by Avently on 09.02.2023.
// Copyright (c) 2023 SimpleX Chat. All rights reserved.
//

import SwiftUI
import WebRTC
import InqalaabChat
import AVKit

extension Notification.Name {
    static let startCallPiP = Notification.Name("inqalaab.startCallPiP")
    static let stopCallPiP = Notification.Name("inqalaab.stopCallPiP")
}

struct CallViewRemote: UIViewRepresentable {
    var client: WebRTCClient
    @ObservedObject var call: Call
    @State var enablePip: (Bool) -> Void = {_ in }
    @Binding var activeCallViewIsCollapsed: Bool
    @Binding var contentMode: UIView.ContentMode
    @Binding var pipShown: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let remoteCameraRenderer = RTCMTLVideoView(frame: view.frame)
        remoteCameraRenderer.videoContentMode = contentMode
        remoteCameraRenderer.tag = 0

        let screenVideo = call.peerMediaSources.screenVideo
        let remoteScreenRenderer = RTCMTLVideoView(frame: view.frame)
        remoteScreenRenderer.videoContentMode = contentMode
        remoteScreenRenderer.tag = 1
        remoteScreenRenderer.alpha = screenVideo ? 1 : 0

        context.coordinator.cameraRenderer = remoteCameraRenderer
        context.coordinator.screenRenderer = remoteScreenRenderer
        client.addRemoteCameraRenderer(remoteCameraRenderer)
        client.addRemoteScreenRenderer(remoteScreenRenderer)
        if screenVideo {
            addSubviewAndResize(remoteScreenRenderer, remoteCameraRenderer, into: view)
        } else {
            addSubviewAndResize(remoteCameraRenderer, remoteScreenRenderer, into: view)
        }

        if AVPictureInPictureController.isPictureInPictureSupported() {
            makeViewWithRTCRenderer(remoteCameraRenderer, remoteScreenRenderer, view, context)
        }
        return view
    }
    
    func makeViewWithRTCRenderer(_ remoteCameraRenderer: RTCMTLVideoView, _ remoteScreenRenderer: RTCMTLVideoView, _ view: UIView, _ context: Context) {
        // PiP renderers: use AVSampleBufferDisplayLayer instead of RTCMTLVideoView
        // so remote video keeps rendering when the app is backgrounded
        let pipCameraView = SampleBufferVideoCallView(frame: view.frame)
        let pipScreenView = SampleBufferVideoCallView(frame: view.frame)
        let pipRemoteCameraRenderer = SampleBufferRenderer(displayLayer: pipCameraView.sampleBufferDisplayLayer, view: pipCameraView)
        let pipRemoteScreenRenderer = SampleBufferRenderer(displayLayer: pipScreenView.sampleBufferDisplayLayer, view: pipScreenView)

        let pipVideoCallViewController = AVPictureInPictureVideoCallViewController()
        pipVideoCallViewController.preferredContentSize = CGSize(width: 1080, height: 1920)
        let pipContentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: view,
            contentViewController: pipVideoCallViewController
        )

        let pipController = AVPictureInPictureController(contentSource: pipContentSource)
        pipController.canStartPictureInPictureAutomaticallyFromInline = true
        pipController.delegate = context.coordinator
        context.coordinator.pipController = pipController
        context.coordinator.pipCameraRenderer = pipRemoteCameraRenderer
        context.coordinator.pipScreenRenderer = pipRemoteScreenRenderer
        context.coordinator.willShowHide = { show in
            if show {
                client.addRemoteCameraRenderer(pipRemoteCameraRenderer)
                client.addRemoteScreenRenderer(pipRemoteScreenRenderer)
                context.coordinator.relayout()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    activeCallViewIsCollapsed = true
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    activeCallViewIsCollapsed = false
                }
            }
        }
        context.coordinator.didShowHide = { show in
            if show {
                remoteCameraRenderer.isHidden = true
                remoteScreenRenderer.isHidden = true
            } else {
                client.removeRemoteCameraRenderer(pipRemoteCameraRenderer)
                client.removeRemoteScreenRenderer(pipRemoteScreenRenderer)
                remoteCameraRenderer.isHidden = false
                remoteScreenRenderer.isHidden = false
            }
            pipShown = show
        }
        context.coordinator.relayout = {
            let camera = call.peerMediaSources.camera
            let screenVideo = call.peerMediaSources.screenVideo
            pipCameraView.alpha = camera ? 1 : 0
            pipScreenView.alpha = screenVideo ? 1 : 0
            if screenVideo {
                addSubviewAndResize(pipScreenView, pipCameraView, pip: true, into: pipVideoCallViewController.view)
            } else {
                addSubviewAndResize(pipCameraView, pipScreenView, pip: true, into: pipVideoCallViewController.view)
            }
            if let primary = pipVideoCallViewController.view.subviews.first as? SampleBufferVideoCallView {
                primary.sampleBufferDisplayLayer.videoGravity = contentMode == .scaleAspectFill ? .resizeAspectFill : .resizeAspect
            }
            if pipVideoCallViewController.view.subviews.count > 1,
               let secondary = pipVideoCallViewController.view.subviews[1] as? SampleBufferVideoCallView {
                secondary.sampleBufferDisplayLayer.videoGravity = .resizeAspectFill
            }
        }
        DispatchQueue.main.async {
            enablePip = { enable in
                if enable != pipShown /* pipController.isPictureInPictureActive */ {
                    if enable {
                        pipController.startPictureInPicture()
                    } else {
                        pipController.stopPictureInPicture()
                    }
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(client)
    }

    func updateUIView(_ view: UIView, context: Context) {
        logger.debug("CallView.updateUIView remote")
        let camera = view.subviews.first(where: { $0.tag == 0 })!
        let screen = view.subviews.first(where: { $0.tag == 1 })!
        let screenVideo = call.peerMediaSources.screenVideo
        if screenVideo && screen.alpha == 0 {
            screen.alpha = 1
            addSubviewAndResize(screen, camera, into: view)
        } else if !screenVideo && screen.alpha == 1 {
            screen.alpha = 0
            addSubviewAndResize(camera, screen, into: view)
        }
        (view.subviews[0] as! RTCMTLVideoView).videoContentMode = contentMode
        (view.subviews[1] as! RTCMTLVideoView).videoContentMode = .scaleAspectFill

        camera.alpha = call.peerMediaSources.camera ? 1 : 0
        screen.alpha = call.peerMediaSources.screenVideo ? 1 : 0

        DispatchQueue.main.async {
            if activeCallViewIsCollapsed != pipShown {
                logger.debug("CallView PiP: requesting \(activeCallViewIsCollapsed ? "start" : "stop"), pipSupported=\(AVPictureInPictureController.isPictureInPictureSupported()), controller=\(context.coordinator.pipController != nil)")
                enablePip(activeCallViewIsCollapsed)
            } else if pipShown {
                context.coordinator.relayout()
            }
        }
    }
    
    // MARK: - Coordinator
    class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        var cameraRenderer: RTCMTLVideoView?
        var screenRenderer: RTCMTLVideoView?
        var pipCameraRenderer: SampleBufferRenderer?
        var pipScreenRenderer: SampleBufferRenderer?
        var client: WebRTCClient
        var pipController: AVPictureInPictureController? = nil
        var willShowHide: (Bool) -> Void = { _ in }
        var didShowHide: (Bool) -> Void = { _ in }
        var relayout: () -> Void = {}
        private var pipObserver: NSObjectProtocol?

        required init(_ client: WebRTCClient) {
            self.client = client
            super.init()
            pipObserver = NotificationCenter.default.addObserver(forName: .startCallPiP, object: nil, queue: .main) { [weak self] _ in
                guard let self, let pipController = self.pipController else { return }
                if !pipController.isPictureInPictureActive {
                    logger.debug("CallView PiP: starting via notification")
                    pipController.startPictureInPicture()
                }
            }
            NotificationCenter.default.addObserver(forName: .stopCallPiP, object: nil, queue: nil) { [weak self] _ in
                guard let self, let pipController = self.pipController else { return }
                DispatchQueue.main.async {
                    logger.debug("CallView PiP: stopping via notification, active=\(pipController.isPictureInPictureActive)")
                    pipController.stopPictureInPicture()
                    pipController.canStartPictureInPictureAutomaticallyFromInline = false
                    pipController.contentSource = nil
                    self.pipController = nil
                }
            }
        }

        func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            logger.debug("PiP lifecycle: WILL START")
            willShowHide(true)
        }

        func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            logger.debug("PiP lifecycle: DID START")
            didShowHide(true)
        }

        func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
            logger.error("PiP lifecycle: FAILED — \(error.localizedDescription) — \(error)")
        }

        func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            logger.debug("PiP lifecycle: WILL STOP")
            willShowHide(false)
        }

        func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            logger.debug("PiP lifecycle: DID STOP")
            didShowHide(false)
        }

        deinit {
            if let pipObserver { NotificationCenter.default.removeObserver(pipObserver) }
            // TODO: deinit is not called when changing call type from audio to video and back,
            // which causes many renderers can be created and added to stream (if enabling/disabling
            // video while not yet connected in outgoing call)
            pipController?.stopPictureInPicture()
            pipController?.canStartPictureInPictureAutomaticallyFromInline = false
            pipController?.contentSource = nil
            pipController?.delegate = nil
            pipController = nil
            if let cameraRenderer {
                client.removeRemoteCameraRenderer(cameraRenderer)
            }
            if let screenRenderer {
                client.removeRemoteScreenRenderer(screenRenderer)
            }
            if let pipCameraRenderer {
                client.removeRemoteCameraRenderer(pipCameraRenderer)
            }
            if let pipScreenRenderer {
                client.removeRemoteScreenRenderer(pipScreenRenderer)
            }
        }
    }
    
    class SampleBufferVideoCallView: UIView {
        override class var layerClass: AnyClass {
            get { return AVSampleBufferDisplayLayer.self }
        }

        var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
            return layer as! AVSampleBufferDisplayLayer
        }
    }

    /// Bridges WebRTC RTCVideoFrame → AVSampleBufferDisplayLayer for background-safe PiP rendering.
    /// Metal (RTCMTLVideoView) freezes when backgrounded; AVSampleBufferDisplayLayer stays alive.
    class SampleBufferRenderer: NSObject, RTCVideoRenderer {
        let displayLayer: AVSampleBufferDisplayLayer
        let ownerView: UIView
        private var lastTimestamp: Int64 = 0
        private var frameCount: Int = 0
        private var appliedRotation: RTCVideoRotation = ._0

        init(displayLayer: AVSampleBufferDisplayLayer, view: UIView) {
            self.displayLayer = displayLayer
            self.ownerView = view
            super.init()
            displayLayer.videoGravity = .resizeAspectFill
        }

        func setSize(_ size: CGSize) {
            logger.debug("SampleBufferRenderer: setSize \(size.width)x\(size.height)")
        }

        func renderFrame(_ frame: RTCVideoFrame?) {
            guard let frame = frame else { return }
            frameCount += 1
            if frameCount % 60 == 1 {
                logger.debug("SampleBufferRenderer: frame #\(self.frameCount), type=\(String(describing: type(of: frame.buffer))), size=\(frame.width)x\(frame.height), layerStatus=\(self.displayLayer.status.rawValue)")
            }

            // Apply rotation + scale transform so video fills PiP without black bars
            if frame.rotation != appliedRotation {
                appliedRotation = frame.rotation
                DispatchQueue.main.async {
                    let angle: CGFloat
                    switch frame.rotation {
                    case ._90: angle = .pi / 2
                    case ._180: angle = .pi
                    case ._270: angle = -.pi / 2
                    default: angle = 0
                    }
                    let bounds = self.ownerView.bounds
                    if (frame.rotation == ._90 || frame.rotation == ._270) && bounds.width > 0 && bounds.height > 0 {
                        // After 90° rotation, width↔height swap. Scale up to fill.
                        let scale = max(bounds.width / bounds.height, bounds.height / bounds.width)
                        self.ownerView.transform = CGAffineTransform(rotationAngle: angle).scaledBy(x: scale, y: scale)
                    } else {
                        self.ownerView.transform = CGAffineTransform(rotationAngle: angle)
                    }
                }
            }

            // Get CVPixelBuffer — hardware-decoded frames provide this, otherwise convert I420
            let pixelBuffer: CVPixelBuffer
            if let cvBuffer = frame.buffer as? RTCCVPixelBuffer {
                pixelBuffer = cvBuffer.pixelBuffer
            } else {
                guard let converted = self.convertI420ToPixelBuffer(frame) else { return }
                pixelBuffer = converted
            }

            // Create format description
            var formatDesc: CMVideoFormatDescription?
            let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc
            )
            guard fmtStatus == noErr, let formatDesc = formatDesc else { return }

            // Ensure monotonically increasing timestamps to prevent stutter
            var ts = frame.timeStampNs
            if ts <= lastTimestamp {
                ts = lastTimestamp + 33_333_333 // ~30fps fallback
            }
            lastTimestamp = ts

            var timing = CMSampleTimingInfo(
                duration: CMTime.invalid,
                presentationTimeStamp: CMTimeMake(value: ts, timescale: 1_000_000_000),
                decodeTimeStamp: CMTime.invalid
            )

            var sampleBuffer: CMSampleBuffer?
            let sbStatus = CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDesc,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            )
            guard sbStatus == noErr, let sampleBuffer = sampleBuffer else { return }

            // Recover from failed state (can happen on resolution changes)
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            displayLayer.enqueue(sampleBuffer)
        }

        /// Convert I420 RTCVideoFrame to CVPixelBuffer (NV12 format)
        private func convertI420ToPixelBuffer(_ frame: RTCVideoFrame) -> CVPixelBuffer? {
            let i420 = frame.buffer.toI420()
            let width = Int(i420.width)
            let height = Int(i420.height)

            var pixelBuffer: CVPixelBuffer?
            let attrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
            ]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width, height,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                attrs as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

            CVPixelBufferLockBaseAddress(pb, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }

            // Copy Y plane
            let yDst = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
            let yDstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let ySrc = i420.dataY
            let ySrcStride = Int(i420.strideY)
            for row in 0..<height {
                memcpy(yDst + row * yDstStride, ySrc + row * ySrcStride, width)
            }

            // Interleave U+V into NV12 UV plane
            let uvDst = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
            let uvDstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let uSrc = i420.dataU
            let vSrc = i420.dataV
            let uStride = Int(i420.strideU)
            let vStride = Int(i420.strideV)
            let chromaHeight = height / 2
            let chromaWidth = width / 2
            let uvDstBytes = uvDst.assumingMemoryBound(to: UInt8.self)
            let uSrcBytes = uSrc
            let vSrcBytes = vSrc
            for row in 0..<chromaHeight {
                let dstRow = uvDstBytes + row * uvDstStride
                let uRow = uSrcBytes + row * uStride
                let vRow = vSrcBytes + row * vStride
                for col in 0..<chromaWidth {
                    dstRow[col * 2] = uRow[col]
                    dstRow[col * 2 + 1] = vRow[col]
                }
            }

            return pb
        }
    }
}

struct CallViewLocal: UIViewRepresentable {
    var client: WebRTCClient
    var localRendererAspectRatio: Binding<CGFloat?>
    @State var pipStateChanged: (Bool) -> Void = {_ in }
    @Binding var pipShown: Bool

    init(client: WebRTCClient, localRendererAspectRatio: Binding<CGFloat?>, pipShown: Binding<Bool>) {
        self.client = client
        self.localRendererAspectRatio = localRendererAspectRatio
        self._pipShown = pipShown
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let localRenderer = RTCEAGLVideoView(frame: .zero)
        context.coordinator.renderer = localRenderer
        client.addLocalRenderer(localRenderer)
        addSubviewAndResize(localRenderer, nil, into: view)
        DispatchQueue.main.async {
            pipStateChanged = { shown in
                localRenderer.isHidden = shown
            }
        }
        return view
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(client)
    }

    func updateUIView(_ view: UIView, context: Context) {
        logger.debug("CallView.updateUIView local")
        pipStateChanged(pipShown)
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        var renderer: RTCEAGLVideoView?
        var client: WebRTCClient

        required init(_ client: WebRTCClient) {
            self.client = client
        }

        deinit {
            if let renderer {
                client.removeLocalRenderer(renderer)
            }
        }
    }
}

private func addSubviewAndResize(_ fullscreen: UIView, _ end: UIView?, pip: Bool = false, into containerView: UIView) {
    if containerView.subviews.firstIndex(of: fullscreen) == 0 && ((end == nil && containerView.subviews.count == 1) || (end != nil && containerView.subviews.firstIndex(of: end!) == 1)) {
        // Nothing to do, elements on their places
        return
    }
    containerView.removeConstraints(containerView.constraints)
    containerView.subviews.forEach { sub in sub.removeFromSuperview()}

    containerView.addSubview(fullscreen)
    fullscreen.translatesAutoresizingMaskIntoConstraints = false
    fullscreen.layer.cornerRadius = 0
    fullscreen.layer.masksToBounds = false

    if let end {
        containerView.addSubview(end)
        end.translatesAutoresizingMaskIntoConstraints = false
        end.layer.cornerRadius = pip ? 8 : 10
        end.layer.masksToBounds = true
    }

    let constraintFullscreenV = NSLayoutConstraint.constraints(
        withVisualFormat: "V:|[fullscreen]|",
        options: [],
        metrics: nil,
        views: ["fullscreen": fullscreen]
    )
    let constraintFullscreenH = NSLayoutConstraint.constraints(
        withVisualFormat: "H:|[fullscreen]|",
        options: [],
        metrics: nil,
        views: ["fullscreen": fullscreen]
    )

    containerView.addConstraints(constraintFullscreenV)
    containerView.addConstraints(constraintFullscreenH)

    if let end {
        let constraintEndWidth = NSLayoutConstraint(
            item: end, attribute: .width, relatedBy: .equal, toItem: containerView, attribute: .width, multiplier: pip ? 0.5 : 0.3, constant: 0
        )
        let constraintEndHeight = NSLayoutConstraint(
            item: end, attribute: .height, relatedBy: .equal, toItem: containerView, attribute: .width, multiplier: pip ? 0.5 * 1.33 : 0.3 * 1.33, constant: 0
        )
        let constraintEndX = NSLayoutConstraint(
            item: end, attribute: .leading, relatedBy: .equal, toItem: containerView, attribute: .trailing, multiplier: pip ? 0.5 : 0.7, constant: pip ? -8 : -17
        )
        let constraintEndY = NSLayoutConstraint(
            item: end, attribute: .bottom, relatedBy: .equal, toItem: containerView, attribute: .bottom, multiplier: 1, constant: pip ? -8 : -92
        )
        containerView.addConstraint(constraintEndWidth)
        containerView.addConstraint(constraintEndHeight)
        containerView.addConstraint(constraintEndX)
        containerView.addConstraint(constraintEndY)
    }
    containerView.layoutIfNeeded()
}
