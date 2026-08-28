import Foundation
import os
import TailscaleKit
import HeelerSSH

/// Manages the embedded userspace Tailscale node (libtailscale).
///
/// Unlike the official Tailscale app, this node does **not** register a system
/// VPN (`NEPacketTunnelProvider`). It runs entirely inside the process and
/// exposes a loopback SOCKS5 proxy; tailnet-only traffic is routed through
/// that proxy, everything else stays on the normal network stack. The user can
/// therefore keep a proxy/VPN app (e.g. LOON) running the whole time — there
/// is never a second system tunnel to fight over.
///
/// State machine follows the IPN bus (`watchIPNBus`), NOT `node.up()`:
/// `TailscaleNode.init` already sets `WantRunning` and triggers
/// `StartLoginInteractive`, so the bus emits `NeedsLogin` + `BrowseToURL` on
/// its own, and `Running` once the user completes login. Calling `node.up()`
/// blocks the node actor's serial executor until `Running` — which never
/// happens for an unauthenticated node, so every localAPI call queues behind
/// it forever. See aperture's TSNetManager for the same reasoning.
@MainActor
final class TailnetNodeController: ObservableObject {
    enum NodeState: Equatable {
        case idle
        case starting
        case needsLogin
        case running(ipv4: String?)
        case failed(String)
    }

    @Published private(set) var state: NodeState = .idle
    @Published private(set) var tailnetName: String?
    @Published private(set) var isSocksProxyActive = false
    /// Non-nil while a browser login is required (and not yet complete).
    /// The view presents an `ASWebAuthenticationSession` when this is set.
    @Published private(set) var pendingLoginURL: URL?

    /// True when the node is running and SSH should ride the tailnet.
    var isActive: Bool {
        if case .running = state { return true }
        return false
    }

    private var node: TailscaleNode?
    private var loopback: TailscaleNode.LoopbackConfig?
    private var localAPI: LocalAPIClient?
    private var processor: MessageProcessor?
    private let logger = TailnetLogger()

    /// Application Support state directory (persistent across launches).
    private var stateDirectory: String {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Tailnet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    // MARK: - Lifecycle

    func start() {
        guard node == nil else { return }
        state = .starting
        do {
            let config = Configuration(
                hostName: "heeler-ios",
                path: stateDirectory,
                authKey: nil, // web auth (user logs in via browser)
                controlURL: kDefaultControlURL,
                ephemeral: false)
            let node = try TailscaleNode(config: config, logger: logger)
            self.node = node
            Task { [weak self] in
                await self?.wireUp(node: node)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// After the node is created: start the IPN bus watcher, then get the
    /// loopback SOCKS5 address so SSH can ride the tailnet.
    private func wireUp(node: TailscaleNode) async {
        do {
            // The loopback SOCKS5 proxy is available as soon as the node is
            // started (before login), so wire the SSH layer immediately.
            let loopback = try await node.loopback()
            self.loopback = loopback
            activateProxy(loopback)

            let localAPI = LocalAPIClient(localNode: node, logger: logger)
            self.localAPI = localAPI

            let consumer = TailnetBusConsumer { [weak self] notify in
                self?.handle(notify: notify)
            }
            let processor = try await localAPI.watchIPNBus(
                mask: [.initialState],
                consumer: consumer)
            self.processor = processor
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Maps an IPN notify to view state.
    private func handle(notify: Ipn.Notify?) {
        guard let notify else { return }
        if let state = notify.State {
            switch state {
            case .NeedsLogin:
                self.state = .needsLogin
                if let urlString = notify.BrowseToURL, let url = URL(string: urlString) {
                    pendingLoginURL = url
                }
            case .Running:
                self.state = .running(ipv4: self.loopback?.ip)
                isSocksProxyActive = true
                pendingLoginURL = nil
                refreshTailnetName()
            case .Starting, .NoState, .Stopped:
                break
            @unknown default:
                break
            }
        }
        if notify.LoginFinished != nil {
            // Login completed; the bus will deliver Running on its own.
            pendingLoginURL = nil
        }
    }

    private func refreshTailnetName() {
        guard let node else { return }
        Task { [weak self] in
            if let data = try? await node.statusJSON(),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let selfNode = json["Self"] as? [String: Any],
               let dnsName = selfNode["DNSName"] as? String {
                self?.tailnetName = dnsName
            }
        }
    }

    func stop() {
        guard let node else { return }
        // Point SSH back at direct dialing first.
        SocketConnector.socks5Proxy = nil
        isSocksProxyActive = false
        loopback = nil
        pendingLoginURL = nil
        let cancelProcessor = processor
        processor = nil
        localAPI = nil
        Task { [weak self] in
            cancelProcessor?.cancel()
            try? await node.close()
            self?.node = nil
            self?.state = .idle
            self?.tailnetName = nil
        }
    }

    /// Starts interactive login. `startLoginInteractive()` makes the node
    /// emit `BrowseToURL` on the IPN bus; the view presents that URL.
    func requestLogin() {
        guard let localAPI else { return }
        Task {
            do {
                try await localAPI.startLoginInteractive()
            } catch {
                // fall through; the bus may still surface a URL
            }
        }
    }

    /// Called by the view after the auth session finishes (success or
    /// cancel). The bus's `LoginFinished`/`Running` is authoritative.
    func loginSessionEnded() {
        pendingLoginURL = nil
    }

    // MARK: - Proxy injection

    private func activateProxy(_ loopback: TailscaleNode.LoopbackConfig) {
        guard let port = loopback.port, let ip = loopback.ip else {
            logger.log("Tailnet loopback: no usable address (\(loopback.address))")
            return
        }
        let (user, pass) = splitCredential(loopback.proxyCredential)
        SocketConnector.socks5Proxy = SOCKS5Connector.ProxyEndpoint(
            host: ip,
            port: UInt16(port),
            username: user,
            password: pass)
        logger.log("Tailnet SOCKS5 proxy active at \(ip):\(port)")
    }

    /// libtailscale vends the proxy credential as `"user:pass"`.
    private func splitCredential(_ raw: String) -> (String?, String?) {
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return (raw, nil) }
        return (String(parts[0]), String(parts[1]))
    }
}

/// Receives IPN bus notifications and forwards them to a main-actor callback.
/// `MessageConsumer` is an actor protocol; the sink forwards each notify to
/// the controller, which applies it to `@Published` view state.
actor TailnetBusConsumer: MessageConsumer {
    private let onNotify: @MainActor (Ipn.Notify) -> Void

    init(onNotify: @escaping @MainActor (Ipn.Notify) -> Void) {
        self.onNotify = onNotify
    }

    nonisolated func notify(_ notify: Ipn.Notify) {
        Task { @MainActor [onNotify] in
            onNotify(notify)
        }
    }

    nonisolated func error(_ error: Error) {
        // IPN bus errors are handled by the bus watcher restart logic
        // (TailscaleKit's MessageProcessor handles retries internally).
        // We log and discard; the controller observes state via the bus.
    }
}

/// Writes TailscaleKit logs to the unified log stream.
final class TailnetLogger: LogSink, @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.bybee.heeler.sube", category: "tailnet")

    func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    var logFileHandle: Int32? { nil }
}
