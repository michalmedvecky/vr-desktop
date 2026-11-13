import Foundation
import Network
import Security

/// Tiny HTTPS server for the Quest browser.
///   GET  /            -> the WebXR client (index.html, app.js, three.module.min.js)
///   POST /offer       -> body {"sdp": "<offer>"}, returns {"sdp": "<answer>"}
/// WebXR and WebRTC need a secure context, hence HTTPS with a self-signed certificate.
/// A second plain-HTTP listener only redirects to the HTTPS URL.
final class WebServer {
    static let httpsPort: UInt16 = 8443
    static let httpPort: UInt16 = 8080

    /// (offer SDP, reply) -> call reply(answer SDP or nil). Called on the main queue.
    var onOffer: ((String, @escaping (String?) -> Void) -> Void)?

    private var tlsListener: NWListener?
    private var httpListener: NWListener?
    private let queue = DispatchQueue(label: "webserver")
    private let webRoot: URL

    init() {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("index.html").path) {
            webRoot = res
        } else {
            // `swift run` from a checkout: mac/Web next to Sources/.
            webRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Web")
        }
    }

    func start() throws {
        let identity = try TLSIdentity.loadOrCreate()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        let tlsParams = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        tlsParams.allowLocalEndpointReuse = true
        let l = try NWListener(using: tlsParams, on: NWEndpoint.Port(rawValue: Self.httpsPort)!)
        l.newConnectionHandler = { [weak self] c in self?.serve(c, redirectOnly: false) }
        l.stateUpdateHandler = { NSLog("HTTPS listener: \($0)") }
        l.start(queue: queue)
        tlsListener = l

        let httpParams = NWParameters.tcp
        httpParams.allowLocalEndpointReuse = true
        if let h = try? NWListener(using: httpParams, on: NWEndpoint.Port(rawValue: Self.httpPort)!) {
            h.newConnectionHandler = { [weak self] c in self?.serve(c, redirectOnly: true) }
            h.start(queue: queue)
            httpListener = h
        }
    }

    // MARK: HTTP

    private func serve(_ conn: NWConnection, redirectOnly: Bool) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data()) { [weak self] req in
            guard let self, let req else { conn.cancel(); return }
            if redirectOnly {
                let host = (req.headers["host"] ?? "").split(separator: ":").first.map(String.init) ?? ""
                self.respond(conn, status: "301 Moved Permanently",
                             headers: ["Location": "https://\(host):\(Self.httpsPort)/"], body: Data())
                return
            }
            self.route(req, conn)
        }
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private func readRequest(_ conn: NWConnection, buffer: Data, done: @escaping (Request?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let requestLine = lines.removeFirst().split(separator: " ")
                var headers: [String: String] = [:]
                for l in lines {
                    guard let idx = l.firstIndex(of: ":") else { continue }
                    headers[l[..<idx].lowercased()] = l[l.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                let body = buf[headerEnd.upperBound...]
                if body.count >= length, requestLine.count >= 2 {
                    let path = String(requestLine[1]).split(separator: "?").first.map(String.init) ?? "/"
                    return done(Request(method: String(requestLine[0]), path: path, headers: headers, body: Data(body.prefix(length))))
                }
            }
            if isComplete || error != nil || buf.count > 4 * 1024 * 1024 { return done(nil) }
            self.readRequest(conn, buffer: buf, done: done)
        }
    }

    private func route(_ req: Request, _ conn: NWConnection) {
        switch (req.method, req.path) {
        case ("POST", "/offer"):
            guard let o = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let sdp = o["sdp"] as? String else {
                return respond(conn, status: "400 Bad Request", body: Data("bad offer".utf8))
            }
            DispatchQueue.main.async {
                guard let onOffer = self.onOffer else {
                    return self.respond(conn, status: "503 Service Unavailable", body: Data())
                }
                onOffer(sdp) { answer in
                    guard let answer,
                          let json = try? JSONSerialization.data(withJSONObject: ["sdp": answer]) else {
                        return self.respond(conn, status: "500 Internal Server Error", body: Data("negotiation failed".utf8))
                    }
                    self.respond(conn, status: "200 OK", headers: ["Content-Type": "application/json"], body: json)
                }
            }
        case ("GET", _):
            let name = req.path == "/" ? "index.html" : String(req.path.dropFirst())
            // Only serve plain file names from the web root.
            guard !name.contains("/"), !name.contains(".."),
                  let data = try? Data(contentsOf: webRoot.appendingPathComponent(name)) else {
                return respond(conn, status: "404 Not Found", body: Data("not found".utf8))
            }
            respond(conn, status: "200 OK", headers: ["Content-Type": Self.mime(name), "Cache-Control": "no-cache"], body: data)
        default:
            respond(conn, status: "405 Method Not Allowed", body: Data())
        }
    }

    private func respond(_ conn: NWConnection, status: String, headers: [String: String] = [:], body: Data) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func mime(_ name: String) -> String {
        switch (name as NSString).pathExtension {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}

/// Self-signed certificate, created once with the system `openssl` and stored in
/// ~/Library/Application Support/VRDesktop/identity.p12.
enum TLSIdentity {
    private static let password = "vrdesktop"

    static func loadOrCreate() throws -> SecIdentity {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VRDesktop", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p12 = dir.appendingPathComponent("identity.p12")
        if !FileManager.default.fileExists(atPath: p12.path) {
            try create(in: dir)
        }
        let data = try Data(contentsOf: p12)
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            // Corrupt or incompatible file: recreate on next launch.
            try? FileManager.default.removeItem(at: p12)
            throw NSError(domain: "TLSIdentity", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Import certifikátu selhal (\(status))"])
        }
        return identity as! SecIdentity
    }

    private static func create(in dir: URL) throws {
        let key = dir.appendingPathComponent("key.pem").path
        let cert = dir.appendingPathComponent("cert.pem").path
        let p12 = dir.appendingPathComponent("identity.p12").path
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                 "-subj", "/CN=VR Desktop", "-keyout", key, "-out", cert])
        try run(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12,
                 "-name", "VR Desktop", "-passout", "pass:\(password)",
                 "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES"])
    }

    private static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "TLSIdentity", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "openssl \(args.first ?? "") selhal"])
        }
    }
}

enum NetworkInfo {
    /// Local IPv4 addresses (Wi-Fi / Ethernet), for display in the menu.
    static func localIPv4() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}
