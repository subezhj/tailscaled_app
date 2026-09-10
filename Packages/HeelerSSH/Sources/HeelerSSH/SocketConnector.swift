import Darwin
import Dispatch
import Foundation

public enum SocketConnector {
    /// Optional SOCKS5 proxy (embedded userspace Tailscale node). When set,
    /// tailnet connections are dialed through the proxy instead of directly —
    /// the proxy resolves hostnames (MagicDNS) and rides the tailnet. This is
    /// how Heeler reaches tailnet hosts without registering a system VPN, so
    /// it coexists with an always-on proxy app (e.g. LOON).
    public static var socks5Proxy: SOCKS5Connector.ProxyEndpoint? {
        get { _socks5Proxy }
        set { _socks5Proxy = newValue }
    }
    private static nonisolated(unsafe) var _socks5Proxy: SOCKS5Connector.ProxyEndpoint?

    /// Diagnostic override: when true, non-tailnet destinations (LAN, public
    /// IPs) are dialed directly instead of through the SOCKS5 proxy. Lets the
    /// user prove whether a failure is the proxy path or the target host.
    /// Tailnet destinations are unaffected — there is no route to
    /// 100.64.0.0/10 without the embedded node, so they always ride the
    /// proxy.
    public static var forceDirect: Bool {
        get { _forceDirect }
        set { _forceDirect = newValue }
    }
    private static nonisolated(unsafe) var _forceDirect = false

    /// Fired when a connection that rode the tailnet SOCKS5 proxy fails. The
    /// embedded Tailscale node's loopback proxy can go stale (control-plane
    /// or DERP sessions die after a long background stay, or the node itself
    /// hangs), and every retry then dials the same dead proxy — the SSH layer
    /// cannot repair it, only recreate the node. The owner (app layer)
    /// registers this to tear the node down and rebuild it, which swaps in a
    /// fresh proxy the next retry can use. Throttled by the owner, not here.
    public static var onProxyDialFailure: (@Sendable () -> Void)? {
        get { _onProxyDialFailure }
        set { _onProxyDialFailure = newValue }
    }
    private static nonisolated(unsafe) var _onProxyDialFailure: (@Sendable () -> Void)?

    /// Diagnostic record of the most recent connection attempt: which host,
    /// whether it rode the tailnet proxy, and whether it failed. Lets the UI
    /// answer "did my SSH actually go through Tailscale?"
    public private(set) static var lastDialReport: DialReport? {
        get { _lastDialReport }
        set { _lastDialReport = newValue }
    }
    private static nonisolated(unsafe) var _lastDialReport: DialReport?

    public struct DialReport: Sendable, Equatable {
        public let host: String
        public let port: UInt16
        public let viaProxy: Bool
        public let failed: Bool
        public let at: Date

        public init(host: String, port: UInt16, viaProxy: Bool, failed: Bool, at: Date = Date()) {
            self.host = host
            self.port = port
            self.viaProxy = viaProxy
            self.failed = failed
            self.at = at
        }
    }

    // MARK: - Test seam (upstream #current-transport-v4)

    /// Upstream's injectable connect operations: every syscall a direct dial
    /// performs is routed through these, so the candidate loop's deadline
    /// splitting can be tested without real sockets. The tailnet entry point
    /// below adds proxy routing on top; the direct core stays pure.
    enum ConnectionState: Sendable {
        case connected
        case inProgress
        case failed
    }

    struct Operations: Sendable {
        let now: @Sendable () -> ContinuousClock.Instant
        let makeSocket: @Sendable (Int32, Int32, Int32) -> Int32
        let setNonBlocking: @Sendable (Int32) -> Bool
        let beginConnection: @Sendable (Int32, SocketAddress) -> ConnectionState
        let waitUntilWritable:
            @Sendable (Int32, ContinuousClock.Instant) async throws -> Void
        let connectionSucceeded: @Sendable (Int32) -> Bool
        let closeSocket: @Sendable (Int32) -> Void

        static func live(
            makeSocket: @escaping @Sendable (Int32, Int32, Int32) -> Int32 = {
                socket($0, $1, $2)
            }
        ) -> Self {
            Operations(
                now: { ContinuousClock.now },
                makeSocket: makeSocket,
                setNonBlocking: { descriptor in
                    let flags = fcntl(descriptor, F_GETFL, 0)
                    return flags >= 0
                        && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
                },
                beginConnection: { descriptor, address in
                    let result = address.bytes.withUnsafeBytes { bytes -> Int32 in
                        guard let baseAddress = bytes.baseAddress else { return -1 }
                        return Darwin.connect(
                            descriptor,
                            baseAddress.assumingMemoryBound(to: sockaddr.self),
                            socklen_t(bytes.count))
                    }
                    if result == 0 { return .connected }
                    return errno == EINPROGRESS ? .inProgress : .failed
                },
                waitUntilWritable: { descriptor, deadline in
                    try await SocketReadiness.wait(
                        descriptor: descriptor,
                        directions: .write,
                        until: deadline)
                },
                connectionSucceeded: { descriptor in
                    var socketError: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    return getsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_ERROR,
                        &socketError,
                        &length) == 0 && socketError == 0
                },
                closeSocket: { descriptor in
                    _ = Darwin.close(descriptor)
                })
        }
    }

    // MARK: - Tailnet-aware entry point

    /// The tailnet-aware dial: tailnet destinations ride the embedded node's
    /// SOCKS5 proxy (when one is injected); everything else dials directly.
    /// Direct dials go through the upstream testable core (`Operations`).
    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant
    ) async throws -> Int32 {
        // Split tunnel: only tailnet destinations (100.64.0.0/10, *.ts.net,
        // fd7a:/48) ride the embedded node's SOCKS5 proxy — the tsnet proxy
        // cannot dial non-tailnet hosts, so routing everything through it
        // breaks LAN/public destinations with connectionFailed. Everything
        // else dials directly.
        //
        // `forceDirect` skips the proxy for non-tailnet hosts (LAN, public
        // IPs) so the user can rule the proxy path out of a diagnosis.
        // Tailnet destinations always go through the proxy regardless of
        // forceDirect — there is no route to 100.64.0.0/10 on iOS without
        // the embedded node, so a forced direct dial would always fail
        // (connectionFailed / timeout).
        let isTailnet = TailnetTarget.isTailnet(endpoint.host)
        let viaProxy = (socks5Proxy != nil) && isTailnet
        do {
            let descriptor: Int32
            if viaProxy, let proxy = socks5Proxy {
                descriptor = try await SOCKS5Connector.connect(
                    via: proxy,
                    to: endpoint.host,
                    targetPort: endpoint.port,
                    until: deadline)
            } else {
                descriptor = try await connectDirect(to: endpoint, until: deadline)
            }
            lastDialReport = DialReport(
                host: endpoint.host, port: endpoint.port,
                viaProxy: viaProxy, failed: false)
            return descriptor
        } catch {
            lastDialReport = DialReport(
                host: endpoint.host, port: endpoint.port,
                viaProxy: viaProxy, failed: true)
            // A failure dialing a tailnet destination means the embedded
            // node's side of the path is broken — either the loopback proxy
            // is stale (control/DERP sessions died in a background stay) or
            // the proxy is not set at all because the node is not verified,
            // in which case this dial went direct into the CGNAT range with
            // no iOS route and failed with connectionFailed. The SSH layer
            // cannot repair either; notify the owner to start/rebuild the
            // node so the next attempt gets a working proxy. Direct dials to
            // non-tailnet hosts never take this path.
            if isTailnet {
                onProxyDialFailure?()
            }
            throw error
        }
    }

    /// Direct dial without any SOCKS5 indirection. Used both for ordinary
    /// connections and (critically) by `SOCKS5Connector` to reach the proxy
    /// itself — routing the proxy connection back through `connect(to:)`
    /// re-enters the SOCKS5 path and stack-overflows.
    static func connectDirect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant
    ) async throws -> Int32 {
        try await connect(
            to: endpoint,
            until: deadline,
            resolver: DNSServiceAddressResolver(),
            operations: .live())
    }

    // MARK: - Direct core (upstream)

    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant,
        resolver: any SocketAddressResolving,
        makeSocket: @escaping @Sendable (Int32, Int32, Int32) -> Int32
    ) async throws -> Int32 {
        try await connect(
            to: endpoint,
            until: deadline,
            resolver: resolver,
            operations: .live(makeSocket: makeSocket))
    }

    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant,
        resolver: any SocketAddressResolving,
        operations: Operations
    ) async throws -> Int32 {
        guard !endpoint.host.isEmpty, endpoint.port > 0 else {
            throw SSHError.invalidEndpoint
        }

        try checkProgress(until: deadline, now: operations.now())
        let addresses = try await resolver.resolve(endpoint, until: deadline)
        var lastError: SSHError = .connectionFailed
        for (index, address) in addresses.enumerated() {
            do {
                let candidateStart = operations.now()
                try checkProgress(until: deadline, now: candidateStart)
                let remainingCandidates = addresses.count - index
                // Split the time still owned by the caller evenly across the
                // candidates that have not yet had a chance to connect.
                let candidateDeadline = min(
                    candidateStart.advanced(
                        by: candidateStart.duration(to: deadline) / remainingCandidates),
                    deadline)
                return try await connect(
                    to: address,
                    until: candidateDeadline,
                    operations: operations)
            } catch let error as SSHError {
                if error == .cancelled { throw error }
                if error == .timedOut {
                    lastError = error
                    try checkProgress(until: deadline, now: operations.now())
                    continue
                }
                lastError = error
            }
        }
        throw lastError
    }

    private static func connect(
        to address: SocketAddress,
        until deadline: ContinuousClock.Instant,
        operations: Operations
    ) async throws -> Int32 {
        let descriptor = operations.makeSocket(address.family, address.type, address.protocol)
        guard descriptor >= 0 else { throw SSHError.connectionFailed }
        var ownsDescriptor = true
        defer {
            if ownsDescriptor { operations.closeSocket(descriptor) }
        }

        guard operations.setNonBlocking(descriptor) else {
            throw SSHError.connectionFailed
        }

        switch operations.beginConnection(descriptor, address) {
        case .connected:
            break
        case .inProgress:
            try await operations.waitUntilWritable(descriptor, deadline)
            guard operations.connectionSucceeded(descriptor) else {
                throw SSHError.connectionFailed
            }
        case .failed:
            throw SSHError.connectionFailed
        }

        ownsDescriptor = false
        return descriptor
    }

    private static func checkProgress(
        until deadline: ContinuousClock.Instant,
        now: ContinuousClock.Instant
    ) throws {
        if Task.isCancelled { throw SSHError.cancelled }
        if now >= deadline { throw SSHError.timedOut }
    }
}

struct SocketAddress: Sendable, Equatable {
    let family: Int32
    let type: Int32
    let `protocol`: Int32
    let bytes: Data
}
