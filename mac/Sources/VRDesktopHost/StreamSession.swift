import Foundation
import WebRTC
import ScreenCaptureKit
import QuartzCore

/// One WebRTC peer connection to the Quest browser.
///
/// The browser is the offerer: it offers `maxSlots` receive-only video transceivers plus a data
/// channel "ctl". The Mac answers and attaches one persistent video track per transceiver ("slot").
/// Selecting other windows only changes which window capture feeds which slot, so no
/// renegotiation is ever needed. The slot -> window mapping is announced on the data channel.
final class StreamSession: NSObject {
    static let maxSlots = 4

    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    /// Control/input messages from the Quest (delivered on the main queue).
    var onMessage: ((ClientMessage) -> Void)?
    /// Called on the main queue when the data channel opens.
    var onChannelOpen: (() -> Void)?
    var onStateChange: ((String) -> Void)?

    private let pc: RTCPeerConnection
    private var channel: RTCDataChannel?
    private var slots: [Slot] = []
    private let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    override init() {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = []                    // LAN only: host candidates are enough
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        pc = StreamSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil)!
        super.init()
        pc.delegate = self
        for i in 0..<Self.maxSlots {
            let source = StreamSession.factory.videoSource()
            let track = StreamSession.factory.videoTrack(with: source, trackId: "slot\(i)")
            slots.append(Slot(index: i, source: source, track: track))
        }
    }

    /// slots[i] -> window id (0 = empty)
    var slotWindowIDs: [UInt32] { slots.map { $0.windowID } }

    // MARK: Offer / answer (non-trickle: the answer already contains all ICE candidates)

    func handleOffer(_ offerSDP: String, completion: @escaping (String?) -> Void) {
        let offer = RTCSessionDescription(type: .offer, sdp: SDP.boostBitrate(offerSDP))
        pc.setRemoteDescription(offer) { [weak self] error in
            guard let self else { return completion(nil) }
            if let error {
                NSLog("setRemoteDescription failed: \(error)")
                return completion(nil)
            }
            // Attach our slot tracks to the browser's video transceivers, in order.
            let videoTransceivers = self.pc.transceivers.filter { $0.mediaType == .video }
            for (i, t) in videoTransceivers.enumerated() where i < self.slots.count {
                t.setDirection(.sendOnly, error: nil)
                t.sender.track = self.slots[i].track
                self.slots[i].sender = t.sender
            }
            self.pc.answer(for: self.constraints) { sdp, error in
                guard let sdp else {
                    NSLog("createAnswer failed: \(String(describing: error))")
                    return completion(nil)
                }
                let answer = RTCSessionDescription(type: .answer, sdp: SDP.preferH264(sdp.sdp))
                self.pc.setLocalDescription(answer) { error in
                    if let error {
                        NSLog("setLocalDescription failed: \(error)")
                        return completion(nil)
                    }
                    self.applyEncodingParams()
                    self.waitForIceGathering(deadline: Date().addingTimeInterval(3)) {
                        completion(self.pc.localDescription?.sdp)
                    }
                }
            }
        }
    }

    private func waitForIceGathering(deadline: Date, then: @escaping () -> Void) {
        if pc.iceGatheringState == .complete || Date() > deadline { return then() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForIceGathering(deadline: deadline, then: then)
        }
    }

    /// Text must stay sharp: keep resolution, drop frame rate under congestion, allow a high bitrate.
    private func applyEncodingParams() {
        for s in slots {
            guard let sender = s.sender else { continue }
            let p = sender.parameters
            for e in p.encodings {
                e.maxBitrateBps = NSNumber(value: 20_000_000)
                e.maxFramerate = NSNumber(value: 60)
            }
            p.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
            sender.parameters = p
        }
    }

    // MARK: Windows -> slots

    /// Streams exactly the given windows (at most maxSlots). Keeps windows that stay selected in their slot.
    @MainActor
    func setWindows(_ ids: [UInt32], catalog: WindowCatalog) async {
        let wanted = Array(ids.prefix(Self.maxSlots))
        for s in slots where s.windowID != 0 && !wanted.contains(s.windowID) {
            s.stopCapture()
        }
        for id in wanted where !slots.contains(where: { $0.windowID == id }) {
            guard let slot = slots.first(where: { $0.windowID == 0 }),
                  let scWindow = catalog.window(id) else { continue }
            do {
                try await slot.startCapture(window: scWindow) { [weak self] in
                    // Window closed or capture failed.
                    Task { @MainActor in
                        slot.stopCapture()
                        self?.sendSlots()
                    }
                }
            } catch {
                NSLog("Could not start capture of window \(id): \(error)")
                send(.error("Nelze zachytit okno: \(error.localizedDescription)"))
            }
        }
        sendSlots()
    }

    private func sendSlots() { send(.slots(slotWindowIDs)) }

    func send(_ msg: ServerMessage) {
        guard let ch = channel, ch.readyState == .open else { return }
        ch.sendData(RTCDataBuffer(data: msg.json(), isBinary: false))
    }

    func close() {
        for s in slots { s.stopCapture() }
        channel?.close()
        pc.close()
    }
}

// MARK: - RTCPeerConnectionDelegate

extension StreamSession: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let names: [RTCIceConnectionState: String] = [
            .new: "nové", .checking: "navazuji", .connected: "připojeno", .completed: "připojeno",
            .failed: "selhalo", .disconnected: "odpojeno", .closed: "zavřeno",
        ]
        let name = names[newState] ?? "?"
        DispatchQueue.main.async { self.onStateChange?(name) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        channel = dataChannel
        dataChannel.delegate = self
        if dataChannel.readyState == .open {
            DispatchQueue.main.async { self.onChannelOpen?() }
        }
    }
}

// MARK: - RTCDataChannelDelegate

extension StreamSession: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open {
            DispatchQueue.main.async { self.onChannelOpen?() }
        }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let msg = ClientMessage.parse(buffer.data) else { return }
        DispatchQueue.main.async { self.onMessage?(msg) }
    }
}

// MARK: - Slot

/// A persistent WebRTC video track fed by whichever window capture is assigned to it.
final class Slot {
    let index: Int
    let source: RTCVideoSource
    let track: RTCVideoTrack
    var sender: RTCRtpSender?
    private(set) var windowID: UInt32 = 0

    private let rtcCapturer: RTCVideoCapturer
    private var capturer: WindowCapturer?
    private let lock = NSLock()
    private var lastBuffer: CVPixelBuffer?
    private var lastFrameTime: CFTimeInterval = 0
    private var idleTimer: DispatchSourceTimer?

    init(index: Int, source: RTCVideoSource, track: RTCVideoTrack) {
        self.index = index
        self.source = source
        self.track = track
        self.rtcCapturer = RTCVideoCapturer(delegate: source)
    }

    @MainActor
    func startCapture(window: SCWindow, onStop: @escaping () -> Void) async throws {
        let c = WindowCapturer(windowID: window.windowID)
        c.onFrame = { [weak self] buffer, _ in self?.push(buffer) }
        c.onStop = { _ in onStop() }
        windowID = window.windowID
        capturer = c
        do {
            try await c.start(window: window)
        } catch {
            windowID = 0
            capturer = nil
            throw error
        }
        startIdleRepeat()
    }

    func stopCapture() {
        idleTimer?.cancel()
        idleTimer = nil
        capturer?.stop()
        capturer = nil
        windowID = 0
        lock.lock(); lastBuffer = nil; lock.unlock()
    }

    private func push(_ buffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        lock.lock(); lastBuffer = buffer; lastFrameTime = now; lock.unlock()
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer),
                                  rotation: ._0,
                                  timeStampNs: Int64(now * 1_000_000_000))
        source.capturer(rtcCapturer, didCapture: frame)
    }

    /// ScreenCaptureKit sends no frames while a window is static. Re-send the last frame a few
    /// times per second so that a fresh decoder (or a lost keyframe) recovers quickly.
    private func startIdleRepeat() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let buf = self.lastBuffer
            let idle = CACurrentMediaTime() - self.lastFrameTime > 0.25
            self.lock.unlock()
            if idle, let buf { self.push(buf) }
        }
        t.resume()
        idleTimer = t
    }
}

// MARK: - SDP helpers

enum SDP {
    /// Moves H.264 payload types to the front of every m=video line. The Quest decodes H.264 in hardware.
    static func preferH264(_ sdp: String) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        let h264PTs = Set(lines.compactMap { line -> String? in
            guard line.hasPrefix("a=rtpmap:"), line.contains("H264/90000") else { return nil }
            return String(line.dropFirst("a=rtpmap:".count).prefix { $0 != " " })
        })
        guard !h264PTs.isEmpty else { return sdp }
        for i in lines.indices where lines[i].hasPrefix("m=video") {
            let parts = lines[i].split(separator: " ").map(String.init)
            guard parts.count > 3 else { continue }
            let pts = Array(parts[3...])
            lines[i] = (Array(parts[0..<3]) + pts.filter { h264PTs.contains($0) } + pts.filter { !h264PTs.contains($0) })
                .joined(separator: " ")
        }
        return lines.joined(separator: "\r\n")
    }

    /// Raises libwebrtc's start/min bitrate so text is readable from the first second.
    static func boostBitrate(_ sdp: String) -> String {
        let extra = ";x-google-start-bitrate=8000;x-google-min-bitrate=2000;x-google-max-bitrate=20000"
        return sdp.components(separatedBy: "\r\n").map { line in
            if line.hasPrefix("a=fmtp:"), line.contains("profile-level-id"), !line.contains("x-google") {
                return line + extra
            }
            return line
        }.joined(separator: "\r\n")
    }
}
