import Foundation
import Security

/// Connects the Mac (as "host") to the public relay server (server/, deployed on Kubernetes).
/// The Quest page served by the relay sends its WebRTC offer through it; we answer the same way.
/// Only signaling goes through the relay, video flows directly from the Mac to the Quest.
final class RelayClient: NSObject, URLSessionWebSocketDelegate {
    /// (offer SDP, reply) -> call reply(answer SDP or nil). Called on the main queue.
    var onOffer: ((String, @escaping (String?) -> Void) -> Void)?
    /// Called on the main queue.
    var onStateChange: ((String) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var url: URL?
    private var running = false
    private var retryDelay: TimeInterval = 1
    private var pingTimer: Timer?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    /// serverURL: e.g. https://vr.example.com
    func start(serverURL: URL, room: String) {
        stop()
        guard var c = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return }
        c.scheme = (c.scheme == "http") ? "ws" : "wss"
        c.path = "/ws"
        c.queryItems = [URLQueryItem(name: "role", value: "host"), URLQueryItem(name: "room", value: room)]
        url = c.url
        running = true
        retryDelay = 1
        connect()
    }

    func stop() {
        running = false
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setState("vypnuto")
    }

    private func connect() {
        guard running, let url else { return }
        setState("připojuji")
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 1024 * 1024
        task = t
        t.resume()
        receive(on: t)
    }

    private func scheduleReconnect() {
        guard running else { return }
        pingTimer?.invalidate()
        setState("nepřipojeno, zkouším znovu")
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.task == nil || self.task?.state != .running else { return }
            self.connect()
        }
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.task === t else { return }
                switch result {
                case .failure:
                    self.task = nil
                    self.scheduleReconnect()
                case let .success(msg):
                    var data: Data?
                    switch msg {
                    case let .string(s): data = Data(s.utf8)
                    case let .data(d): data = d
                    @unknown default: break
                    }
                    if let data { self.handle(data) }
                    self.receive(on: t)
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["type"] as? String == "offer",
              let sdp = o["sdp"] as? String,
              let from = o["from"] as? String else { return }
        onOffer?(sdp) { [weak self] answer in
            DispatchQueue.main.async {
                if let answer {
                    self?.send(["type": "answer", "sdp": answer, "to": from])
                } else {
                    self?.send(["type": "error", "message": "Mac nedokázal navázat spojení", "to": from])
                }
            }
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let t = task, let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        t.send(.string(s)) { err in
            if let err { NSLog("Relay send failed: \(err)") }
        }
    }

    private func setState(_ s: String) { onStateChange?(s) }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        retryDelay = 1
        setState("připojeno")
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak webSocketTask] _ in
            webSocketTask?.sendPing { _ in }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        task = nil
        scheduleReconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        self.task = nil
        scheduleReconnect()
    }

    // MARK: Room code

    /// Secret pairing code: 24 random bytes, base64url (32 chars). Anyone with the code can see and
    /// control the shared windows, so treat the link like a password.
    static func newRoomCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
