import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Captures a single window with ScreenCaptureKit and hands out CVPixelBuffers.
/// The capture resolution follows the window size (in pixels, i.e. Retina scale applied),
/// capped so that the longer edge is at most `maxLongEdge`.
final class WindowCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    let windowID: UInt32
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "capture.window", qos: .userInteractive)
    private var currentSize: CGSize = .zero
    private var resizeTimer: DispatchSourceTimer?
    private let maxLongEdge: CGFloat
    private let fps: Int

    init(windowID: UInt32, maxLongEdge: CGFloat = 2560, fps: Int = 60) {
        self.windowID = windowID
        self.maxLongEdge = maxLongEdge
        self.fps = fps
    }

    func start(window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = makeConfig(for: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        watchResize(scale: CGFloat(filter.pointPixelScale))
    }

    func stop() {
        resizeTimer?.cancel()
        resizeTimer = nil
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    private func makeConfig(for pointSize: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        var px = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        let longEdge = max(px.width, px.height)
        if longEdge > maxLongEdge {
            let k = maxLongEdge / longEdge
            px = CGSize(width: px.width * k, height: px.height * k)
        }
        // Encoders want even dimensions.
        px = CGSize(width: max(2, floor(px.width / 2) * 2), height: max(2, floor(px.height / 2) * 2))
        currentSize = pointSize

        let c = SCStreamConfiguration()
        c.width = Int(px.width)
        c.height = Int(px.height)
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        c.queueDepth = 5
        c.showsCursor = false
        c.scalesToFit = true
        c.colorSpaceName = CGColorSpace.sRGB
        return c
    }

    /// Windows can be resized at any time; re-configure the stream when that happens.
    private func watchResize(scale: CGFloat) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, let stream = self.stream,
                  let b = WindowCatalog.currentBounds(of: self.windowID) else { return }
            if abs(b.width - self.currentSize.width) > 1 || abs(b.height - self.currentSize.height) > 1 {
                let cfg = self.makeConfig(for: b.size, scale: scale)
                stream.updateConfiguration(cfg) { err in
                    if let err { NSLog("updateConfiguration failed: \(err)") }
                }
            }
        }
        t.resume()
        resizeTimer = t
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only "complete" frames carry new pixels; idle/blank frames are skipped.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Capture of window \(windowID) stopped: \(error)")
        onStop?(error)
    }
}
