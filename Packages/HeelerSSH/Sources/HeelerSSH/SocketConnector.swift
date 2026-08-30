import Darwin
import Dispatch
import Foundation

public enum SocketConnector {
    /// Optional SOCKS5 proxy (embedded userspace Tailscale node). When set,
    /// connections are dialed through the proxy instead of directly — the
    /// proxy resolves hostnames (MagicDNS) and rides the tailnet. This is how
    /// Heeler reaches tailnet hosts without registering a system VPN, so it
    /// coexists with an always-on proxy app (e.g. LOON).
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
            makeSocket: { socket($0, $1, $2) })
    }

    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant,
        resolver: any SocketAddressResolving,
        makeSocket: @escaping @Sendable (Int32, Int32, Int32) -> Int32
    ) async throws -> Int32 {
        guard !endpoint.host.isEmpty, endpoint.port > 0 else {
            throw SSHError.invalidEndpoint
        }

        try checkProgress(until: deadline)
        let addresses = try await resolver.resolve(endpoint, until: deadline)
        var lastError: SSHError = .connectionFailed
        for address in addresses {
            do {
                try checkProgress(until: deadline)
                return try await connect(
                    to: address,
                    until: deadline,
                    makeSocket: makeSocket)
            } catch let error as SSHError {
                if error == .cancelled || error == .timedOut {
                    throw error
                }
                lastError = error
            }
        }
        throw lastError
    }

    private static func connect(
        to address: SocketAddress,
        until deadline: ContinuousClock.Instant,
        makeSocket: @escaping @Sendable (Int32, Int32, Int32) -> Int32
    ) async throws -> Int32 {
        let descriptor = makeSocket(address.family, address.type, address.protocol)
        guard descriptor >= 0 else { throw SSHError.connectionFailed }
        var ownsDescriptor = true
        defer {
            if ownsDescriptor { Darwin.close(descriptor) }
        }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SSHError.connectionFailed
        }

        let result = address.bytes.withUnsafeBytes { bytes -> Int32 in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return Darwin.connect(
                descriptor,
                baseAddress.assumingMemoryBound(to: sockaddr.self),
                socklen_t(bytes.count))
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw SSHError.connectionFailed }
            try await SocketReadiness.wait(
                descriptor: descriptor,
                directions: .write,
                until: deadline)

            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard
                getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                socketError == 0
            else {
                throw SSHError.connectionFailed
            }
        }

        ownsDescriptor = false
        return descriptor
    }

    private static func checkProgress(
        until deadline: ContinuousClock.Instant
    ) throws {
        if Task.isCancelled { throw SSHError.cancelled }
        if ContinuousClock.now >= deadline { throw SSHError.timedOut }
    }
}

struct SocketAddress: Sendable, Equatable {
    let family: Int32
    let type: Int32
    let `protocol`: Int32
    let bytes: Data
}
