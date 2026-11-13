import SwiftUI
import AppKit

@main
struct VRDesktopHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var host = HostController()

    var body: some Scene {
        MenuBarExtra("VR Desktop", systemImage: "rectangle.on.rectangle") {
            MenuContent().environmentObject(host)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    }
}

/// Glue between the window catalog, the web server, the WebRTC session and input injection.
@MainActor
final class HostController: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var selected: [UInt32] = []          // in selection order
    @Published var clientConnected = false
    @Published var connectionState = "čeká na Quest"
    @Published var screenAccess = CGPreflightScreenCaptureAccess()
    @Published var accessibilityAccess = InputInjector.isTrusted
    @Published var lastError: String?
    let ips = NetworkInfo.localIPv4()
    var urls: [String] { ips.map { "https://\($0):\(WebServer.httpsPort)" } }

    private let catalog = WindowCatalog()
    private let server = WebServer()
    private let injector = InputInjector()
    private var session: StreamSession?
    private var refreshTimer: Timer?

    init() {
        if !screenAccess { screenAccess = CGRequestScreenCaptureAccess() }
        if !accessibilityAccess { InputInjector.promptForAccessibility() }

        server.onOffer = { [weak self] sdp, reply in
            guard let self else { return reply(nil) }
            self.newSession().handleOffer(sdp, completion: reply)
        }
        do {
            try server.start()
        } catch {
            lastError = "Server nelze spustit: \(error.localizedDescription)"
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshWindows() }
        }
        Task { await refreshWindows() }
    }

    func refreshWindows() async {
        accessibilityAccess = InputInjector.isTrusted
        screenAccess = CGPreflightScreenCaptureAccess()
        do {
            let list = try await catalog.refresh()
            if list != windows {
                windows = list
                session?.send(.windows(list))
            }
            // Drop selected windows that were closed.
            let alive = Set(list.map(\.id))
            if selected.contains(where: { !alive.contains($0) }) {
                selected.removeAll { !alive.contains($0) }
                await applySelection()
            }
        } catch {
            lastError = "Seznam oken: \(error.localizedDescription)"
        }
    }

    func isSelected(_ id: UInt32) -> Bool { selected.contains(id) }

    func toggle(_ id: UInt32) {
        if let i = selected.firstIndex(of: id) { selected.remove(at: i) }
        else if selected.count < StreamSession.maxSlots { selected.append(id) }
        Task { await applySelection() }
    }

    private func applySelection() async {
        await session?.setWindows(selected, catalog: catalog)
    }

    // MARK: Session lifecycle

    /// Each POST /offer (page load / reconnect in the Quest browser) replaces the previous session.
    private func newSession() -> StreamSession {
        session?.close()
        let s = StreamSession()
        s.onMessage = { [weak self] msg in self?.handle(msg) }
        s.onChannelOpen = { [weak self, weak s] in
            guard let self, let s else { return }
            s.send(.hello(name: Host.current().localizedName ?? "Mac", version: 1, maxWindows: StreamSession.maxSlots))
            s.send(.windows(self.windows))
            Task { await s.setWindows(self.selected, catalog: self.catalog) }
        }
        s.onStateChange = { [weak self] state in
            self?.connectionState = state
            self?.clientConnected = (state == "připojeno")
        }
        session = s
        connectionState = "navazuji"
        return s
    }

    private func handle(_ msg: ClientMessage) {
        switch msg {
        case .listWindows:
            Task {
                await refreshWindows()
                session?.send(.windows(windows))
            }
        case let .select(ids):
            selected = Array(ids.prefix(StreamSession.maxSlots))
            Task { await applySelection() }
        case let .input(input):
            injector.handle(input)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var host: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VR Desktop").font(.headline)

            HStack {
                Circle().fill(host.clientConnected ? .green : .orange).frame(width: 8, height: 8)
                Text("Quest: \(host.connectionState)").font(.caption)
            }
            Text("V prohlížeči Questu otevři:").font(.caption)
            ForEach(host.urls, id: \.self) { url in
                Text(url).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
            }
            if host.urls.isEmpty {
                Text("Mac není připojený k Wi-Fi ani Ethernetu.").font(.caption).foregroundStyle(.red)
            }

            if !host.screenAccess {
                Label("Povol „Nahrávání obrazovky“ v Nastavení > Soukromí a zabezpečení, pak aplikaci restartuj.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            if !host.accessibilityAccess {
                Label("Povol „Zpřístupnění“, jinak nepůjde ovládat okna z Questu.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            if let err = host.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Divider()
            Text("Okna ke streamování (max \(StreamSession.maxSlots))").font(.subheadline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(host.windows, id: \.id) { w in
                        Toggle(isOn: Binding(get: { host.isSelected(w.id) },
                                             set: { _ in host.toggle(w.id) })) {
                            VStack(alignment: .leading) {
                                Text(w.title).lineLimit(1)
                                Text("\(w.app) · \(Int(w.width))×\(Int(w.height))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 320)

            Divider()
            HStack {
                Button("Obnovit") { Task { await host.refreshWindows() } }
                Spacer()
                Button("Ukončit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}
