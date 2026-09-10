import Foundation
import os
import Network
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
    /// True once the node has authenticated and reached Running. This is the
    /// authoritative "login really succeeded" signal (the IPN bus only emits
    /// Running after the control plane has accepted the node).
    @Published private(set) var isVerified = false
    /// Non-nil while a browser login is required (and not yet complete).
    /// The view presents an `ASWebAuthenticationSession` when this is set.
    @Published private(set) var pendingLoginURL: URL?

    /// Per-peer connection health, keyed by the peer's hostname(s) and tailnet
    /// IP(s) as reported by `statusJSON`. The health monitor fills this on a
    /// timer while the node runs; the Console's DERP-relay hint reads it.
    @Published private(set) var peerHealth: [String: TailnetPeerHealth] = [:]
    /// The peer health monitor's last error, surfaced in the Tailnet settings
    /// pane for diagnosis; nil while healthy or before the first sample.
    @Published private(set) var healthCheckError: String?

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
    /// When the last proxy-failure rebuild happened, for throttling.
    private var lastProxyRebuildAt: ContinuousClock.Instant?
    /// When the health monitor last forced a re-dial, for throttling.
    private var lastHealthRedialAt: ContinuousClock.Instant?
    /// The running health-poll task; nil while the node is not verified.
    private var healthTask: Task<Void, Never>?

    /// How often the health monitor samples peer status. Direct/DERP and
    /// online/stale transitions land within one interval; the interval is
    /// long enough that the poll is not the dominant battery draw.
    private static let healthCheckInterval: Duration = .seconds(15)
    /// Minimum gap between health-triggered re-dials, longer than the poll
    /// interval so a genuinely dead peer cannot churn the node.
    private static let healthRedialThrottle: Duration = .seconds(60)
    /// A peer whose last WireGuard handshake is older than this is treated
    /// as stale even when the status still says online.
    private static let staleHandshakeWindow: TimeInterval = 90

    /// Watches for network path changes (WiFi↔cellular). iOS tears down every
    /// existing connection on such a switch, including the node's control/DERP
    /// sessions, so we re-dial via `up()` to restore the tailnet. Without this,
    /// a node that was verified on WiFi goes stale on cellular and every SSH
    /// attempt through the proxy fails.
    private var pathMonitor: NWPathMonitor?
    private var lastKnownInterfaceType: NWInterface.InterfaceType?

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

    /// Starts (or restarts) the embedded node, optionally with an auth key.
    /// The auth key must be set before `tailscale_start`, so it can only be
    /// supplied at creation time — an already-running unauthenticated node
    /// must be torn down and recreated with the key.
    func start(authKey: String? = nil) {
        // If a node already exists, only the current auth state matters; a
        // freshly provided key requires a restart (key is init-time only).
        if let node, authKey != nil {
            stopNodeForRestart(node)
        }
        guard self.node == nil else { return }
        state = .starting
        do {
            let config = Configuration(
                hostName: "heeler-ios",
                path: stateDirectory,
                authKey: authKey, // web auth if nil
                controlURL: kDefaultControlURL,
                ephemeral: false)
            let node = try TailscaleNode(config: config, logger: logger)
            self.node = node
            startPathMonitor()
            installProxyFailureRebuild()
            Task { [weak self] in
                await self?.wireUp(node: node)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Registers the SSH-layer callback that rebuilds this node when a
    /// proxy dial fails. The proxy is loopback to the embedded node; when it
    /// stops answering (control/DERP stale after a background stay, or the
    /// node hung), the SSH reconnect loop would otherwise dial the same dead
    /// proxy forever. Rebuilding swaps in a fresh loopback proxy for the
    /// next attempt — the same recovery a full app restart gets, without
    /// leaving the app.
    ///
    /// Registration is idempotent and happens on every `start()`; the
    /// rebuild itself is throttled so a Host that is genuinely unreachable
    /// cannot churn the node every retry.
    private func installProxyFailureRebuild() {
        SocketConnector.onProxyDialFailure = { @Sendable [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.rebuildAfterProxyFailure()
            }
        }
    }

    /// Rebuilds the node after a tailnet SSH dial failure, at most once per
    /// throttling window.
    ///
    /// Three states:
    /// 1. No node at all (never started, e.g. the app launched while a Host
    ///    dial raced ahead of `tailnet.start()`): start one now.
    /// 2. Node exists but is not verified (control plane unreachable):
    ///    re-dial it — the proxy was never set, so a rebuild is the same
    ///    work with more churn.
    /// 3. Node verified: tear it down and recreate so the next attempt gets
    ///    a fresh loopback proxy.
    private func rebuildAfterProxyFailure() {
        let now = ContinuousClock.now
        if let last = lastProxyRebuildAt,
            now - last < Self.proxyRebuildThrottle
        {
            return
        }
        lastProxyRebuildAt = now

        guard let dead = node else {
            logger.log("Tailnet: tailnet SSH failed with no node; starting")
            start()
            return
        }
        guard isVerified else {
            logger.log("Tailnet: tailnet SSH failed; node not verified; re-dialing")
            Task {
                try? await dead.up()
            }
            return
        }
        logger.log("Tailnet: SSH proxy dial failed; rebuilding node")
        stopNodeForRestart(dead)
        start()
    }

    /// Minimum gap between proxy-failure rebuilds: long enough that a Host
    /// outage does not churn the node, short enough that a stale node is
    /// repaired promptly after the first failure.
    private static let proxyRebuildThrottle: Duration = .seconds(20)

    /// Tears down a running node so a new one can be created with an auth key.
    /// Clears `node` synchronously (the close happens in the background) so a
    /// subsequent `start(authKey:)` can create a fresh node immediately.
    private func stopNodeForRestart(_ node: TailscaleNode) {
        SocketConnector.socks5Proxy = nil
        isSocksProxyActive = false
        loopback = nil
        pendingLoginURL = nil
        let cancelProcessor = processor
        processor = nil
        localAPI = nil
        self.node = nil
        Task {
            cancelProcessor?.cancel()
            try? await node.close()
        }
    }

    /// After the node is created: start the IPN bus watcher, then keep the
    /// loopback SOCKS5 config ready. The proxy is injected into the SSH layer
    /// only once the node is verified (Running) — before that the tailnet
    /// isn't reachable, and routing connections through a not-yet-up node
    /// would make every tailnet SSH attempt fail with connectionFailed.
    private func wireUp(node: TailscaleNode) async {
        do {
            let loopback = try await node.loopback()
            self.loopback = loopback

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
                isVerified = false
                stopHealthMonitor()
                // Node is not usable yet — don't route SSH through it.
                SocketConnector.socks5Proxy = nil
                isSocksProxyActive = false
                if let urlString = notify.BrowseToURL, let url = URL(string: urlString) {
                    pendingLoginURL = url
                }
            case .Running:
                isVerified = true
                isSocksProxyActive = true
                pendingLoginURL = nil
                // Node authenticated: now route tailnet destinations through
                // its loopback SOCKS5 proxy.
                if let loopback {
                    activateProxy(loopback)
                }
                refreshRunningState()
                startHealthMonitor()
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

    /// Fetch the authoritative tailnet facts once the node is Running: the
    /// real tailnet IP(s) from `addrs()` (NOT the loopback proxy address) and
    /// the node's MagicDNS name from statusJSON.
    private func refreshRunningState() {
        guard let node else { return }
        Task { [weak self] in
            var ip: String?
            var name: String?
            if let ips = try? await node.addrs() {
                ip = ips.ip4 ?? ips.ip6
            }
            if let data = try? await node.statusJSON(),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let selfNode = json["Self"] as? [String: Any],
               let dnsName = selfNode["DNSName"] as? String {
                name = dnsName
            }
            self?.state = .running(ipv4: ip)
            self?.tailnetName = name
        }
    }

    // MARK: - Peer health monitor

    /// Starts the periodic peer-health sampler. Idempotent; a running node
    /// that reaches Running again (e.g. after a rebuild) simply keeps the
    /// existing loop. The loop samples `statusJSON`, decodes per-peer
    /// direct/relay + online/stale health, publishes it for the DERP-relay
    /// hint, and re-dials the node when a peer looks dead but the node still
    /// claims Running — the gap a proxy-failure rebuild cannot see because
    /// nothing tried to dial through the proxy.
    private func startHealthMonitor() {
        guard healthTask == nil else { return }
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.samplePeerHealth()
                try? await Task.sleep(for: Self.healthCheckInterval)
            }
        }
    }

    private func stopHealthMonitor() {
        healthTask?.cancel()
        healthTask = nil
        peerHealth = [:]
        healthCheckError = nil
    }

    /// One sampling pass: fetch status, decode peers, publish health, and
    /// trigger a throttled re-dial if any peer is unhealthy while the node
    /// claims Running.
    private func samplePeerHealth() async {
        guard let node, isVerified else { return }
        do {
            let data = try await node.statusJSON()
            let status = try JSONDecoder().decode(IpnState.Status.self, from: data)
            let health = Self.peerHealth(from: status)
            guard !Task.isCancelled else { return }
            peerHealth = health
            healthCheckError = nil
            // A peer that is offline or whose handshake is stale means the
            // tailnet path died even though the node still says Running.
            // Nothing else will re-dial in that state (the proxy is set, so
            // dials fail only when a Host actually tries to connect) — so
            // force a control-plane/DERP re-dial, throttled.
            if health.values.contains(where: { !$0.isHealthy }) {
                healthTriggeredRedial()
            }
        } catch {
            guard !Task.isCancelled else { return }
            healthCheckError = error.localizedDescription
        }
    }

    /// Decodes the raw status into the per-key health dictionary. Keys are
    /// every hostname and tailnet IP a peer carries, so a Host configured
    /// with `100.x`, `magic-name`, or `magic-name.tailnet.ts.net` all find
    /// the same peer.
    static func peerHealth(from status: TailscaleKit.IpnState.Status) -> [String: TailnetPeerHealth] {
        var result: [String: TailnetPeerHealth] = [:]
        guard let peers = status.Peer else { return result }
        for peer in peers.values {
            let health = TailnetPeerHealth(
                online: peer.Online,
                relay: peer.Relay,
                lastHandshake: peer.LastHandshake.isGoZeroTime
                    ? nil : peer.LastHandshake)
            var keys: [String] = []
            if !peer.DNSName.isEmpty {
                keys.append(peer.DNSName)
                // MagicDNS short name: `host.tailnet.ts.net` → `host`.
                if let dot = peer.DNSName.firstIndex(of: ".") {
                    keys.append(String(peer.DNSName[..<dot]))
                }
            }
            if let ips = peer.TailscaleIPs {
                keys.append(contentsOf: ips)
            }
            for key in keys {
                result[key.lowercased()] = health
            }
        }
        return result
    }

    /// Throttled re-dial when the health monitor finds a dead/stale peer.
    private func healthTriggeredRedial() {
        let now = ContinuousClock.now
        if let last = lastHealthRedialAt,
            now - last < Self.healthRedialThrottle
        {
            return
        }
        lastHealthRedialAt = now
        guard let node else { return }
        logger.log("Tailnet: health monitor found an unhealthy peer; re-dialing")
        Task {
            try? await node.up()
        }
    }

    /// Whether a peer is currently relayed through DERP, for the Console's
    /// slow-path hint. Mirrors `peerHealth` lookups by the Host's address.
    /// Returns nil when the peer is not (yet) in the health map.
    func isPeerRelayed(address: String) -> Bool? {
        peerHealth[address.lowercased()]?.isRelayed
    }

    /// Whether the peer behind a Host address looks dead (offline or stale
    /// handshake), for diagnostics.
    func isPeerHealthy(address: String) -> Bool? {
        peerHealth[address.lowercased()]?.isHealthy
    }

    func stop() {
        guard let node else { return }
        // Point SSH back at direct dialing first.
        SocketConnector.socks5Proxy = nil
        isVerified = false
        isSocksProxyActive = false
        loopback = nil
        pendingLoginURL = nil
        stopHealthMonitor()
        let cancelProcessor = processor
        processor = nil
        localAPI = nil
        stopPathMonitor()
        Task { [weak self] in
            cancelProcessor?.cancel()
            try? await node.close()
            self?.node = nil
            self?.state = .idle
            self?.tailnetName = nil
        }
    }

    // MARK: - Network path monitoring

    /// Watches for WiFi↔cellular (or any interface) changes and re-dials the
    /// node when the active interface changes. iOS tears down every existing
    /// connection on such a switch, so the node's control/DERP sessions go
    /// stale and need a fresh `up()` to restore the tailnet.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        self.pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let current = Self.activeInterfaceType(path)
            Task { @MainActor [weak self] in
                self?.handleNetworkChange(to: current)
            }
        }
        monitor.start(queue: .main)
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastKnownInterfaceType = nil
    }

    @MainActor
    private func handleNetworkChange(to interface: NWInterface.InterfaceType?) {
        guard isVerified, let node else { return }
        if interface != lastKnownInterfaceType {
            logger.log("Tailnet: network interface changed \(lastKnownInterfaceType.map(String.init(describing:)) ?? "nil") -> \(interface.map(String.init(describing:)) ?? "nil"); re-dialing")
            lastKnownInterfaceType = interface
            Task {
                // Re-dial control plane + DERP over the new network path.
                try? await node.up()
            }
        } else {
            lastKnownInterfaceType = interface
        }
    }

    /// The primary active interface from a path, or nil when none is usable.
    /// `nonisolated` because NWPathMonitor's callback runs off the main actor.
    private nonisolated static func activeInterfaceType(_ path: NWPath) -> NWInterface.InterfaceType? {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wiredEthernet }
        return nil
    }

    /// Re-check the network on foreground return: the app may have been
    /// suspended on WiFi and resumed on cellular (or vice versa) without the
    /// path monitor having seen the transition, leaving the node's sessions
    /// stale. The monitor will not re-fire for the same path, so compare
    /// against the current monitor snapshot and re-dial if it differs.
    func networkMayHaveChanged() {
        guard let pathMonitor, isVerified else { return }
        let current = Self.activeInterfaceType(pathMonitor.currentPath)
        handleNetworkChange(to: current)
    }

    /// Forces a control-plane/DERP re-dial on foreground return regardless of
    /// interface change. The audio keepalive keeps this process alive through
    /// a background stay, but iOS still restricts background networking: the
    /// node's sessions go stale on the same interface (no NWPathMonitor
    /// transition to catch), so returning finds the SOCKS5 proxy resolving
    /// nothing. `node.up()` is idempotent and cheap on a live node, so this
    /// is safe to call on every `.active` — it re-establishes the tailnet
    /// when it went stale and is a no-op when it did not.
    func restoreOnForeground() {
        guard let node, isVerified else { return }
        logger.log("Tailnet: foreground return; re-dialing control plane + DERP")
        Task {
            try? await node.up()
        }
    }

    /// Starts interactive login. `startLoginInteractive()` makes the node
    /// emit `BrowseToURL` on the IPN bus; the view presents that URL.
    /// If the node is still wiring up (localAPI not yet ready), waits a
    /// moment and retries.
    func requestLogin() {
        Task { [weak self] in
            // Wait up to ~5s for the localAPI client to come up after start().
            for _ in 0..<25 {
                if Task.isCancelled { return }
                if let localAPI = self?.localAPI {
                    do {
                        try await localAPI.startLoginInteractive()
                        return
                    } catch {
                        // fall through; the bus may still surface a URL
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(200))
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
        // tsnet's loopback SOCKS5 server (tailscale.com/tsnet Loopback)
        // authenticates with a FIXED username "tsnet" and the per-instance
        // proxy credential as the password. The credential is a raw 32-char
        // hex string — NOT "user:pass" — so passing it through splitCredential
        // would send the hex as the username and fail auth on every dial.
        SocketConnector.socks5Proxy = SOCKS5Connector.ProxyEndpoint(
            host: ip,
            port: UInt16(port),
            username: "tsnet",
            password: loopback.proxyCredential)
        logger.log("Tailnet SOCKS5 proxy active at \(ip):\(port)")
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
