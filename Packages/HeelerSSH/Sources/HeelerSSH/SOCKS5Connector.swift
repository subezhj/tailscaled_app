import Darwin
import Dispatch
import Foundation

/// Routes a TCP connection through a SOCKS5 proxy (RFC 1928).
///
/// Heeler normally dials SSH hosts directly. When the app runs an embedded
/// userspace Tailscale node (libtailscale), tailnet-only traffic should flow
/// through that node's local SOCKS5 proxy — DNS resolution happens
/// proxy-side (MagicDNS names like `nas.tailnet.ts.net` resolve inside the
/// node) and the TCP stream rides the tailnet. Everything else stays direct,
/// so the system VPN (e.g. a proxy app like LOON) is never disturbed.
///
/// This type only implements what an SSH dial needs: CONNECT with domain-name
/// addressing (no auth). It deliberately mirrors the minimal surface aperture
/// relies on, and is independently testable without a Tailscale node.
public enum SOCKS5Connector {
    public enum SOCKS5Error: Error, Equatable {
        case badResponse
        case unsupportedMethod
        case connectionRefused
        case unreachable
        case timeout
    }

    /// A resolved SOCKS5 proxy endpoint (host + port on a reachable loopback).
    public struct ProxyEndpoint: Sendable, Equatable {
        public let host: String
        public let port: UInt16
        /// Username/password pair (RFC 1929). The embedded userspace Tailscale
        /// node's loopback proxy requires these (libtailscale issues a
        /// per-instance credential); an open proxy uses nil.
        public let username: String?
        public let password: String?

        public init(host: String, port: UInt16, username: String? = nil, password: String? = nil) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    /// Opens a TCP connection to `targetHost:targetPort` via `proxy`.
    ///
    /// - Returns: a connected, blocking socket descriptor owned by the caller.
    /// - Note: the returned descriptor is blocking (the read/write loop that
    ///   libssh2 runs on it is synchronous). The proxy handshake itself is
    ///   performed with a non-blocking socket + readiness waits.
    static func connect(
        via proxy: ProxyEndpoint,
        to targetHost: String,
        targetPort: UInt16,
        until deadline: ContinuousClock.Instant
    ) async throws -> Int32 {
        // 1. Open the TCP connection to the SOCKS5 proxy. This must NOT go
        //    through `SocketConnector.connect(to:)` — it would re-enter the
        //    SOCKS5 path (stack overflow). Direct dial only.
        let proxyEndpoint = SSHEndpoint(host: proxy.host, port: proxy.port)
        let descriptor = try await SocketConnector.connectDirect(to: proxyEndpoint, until: deadline)

        // 2. Non-blocking so we can honor the deadline while handshaking.
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            throw SOCKS5Error.badResponse
        }

        do {
            // 3. Greeting: version, methods, [no-auth | user-pass].
            let methods: [UInt8] = (proxy.username != nil) ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]
            try await send(bytes: methods, descriptor: descriptor, until: deadline)
            let methodReply = try await recvExact(count: 2, descriptor: descriptor, until: deadline)
            guard methodReply[0] == 0x05 else { throw SOCKS5Error.badResponse }
            if methodReply[1] == 0x02 {
                // RFC 1929 username/password auth.
                guard let user = proxy.username, let pass = proxy.password else {
                    throw SOCKS5Error.unsupportedMethod
                }
                let userBytes = Array(user.utf8)
                let passBytes = Array(pass.utf8)
                guard userBytes.count <= 255, passBytes.count <= 255 else {
                    throw SOCKS5Error.badResponse
                }
                var auth: [UInt8] = [0x01]
                auth.append(UInt8(userBytes.count))
                auth.append(contentsOf: userBytes)
                auth.append(UInt8(passBytes.count))
                auth.append(contentsOf: passBytes)
                try await send(bytes: auth, descriptor: descriptor, until: deadline)
                let authReply = try await recvExact(count: 2, descriptor: descriptor, until: deadline)
                guard authReply[0] == 0x01, authReply[1] == 0x00 else {
                    throw SOCKS5Error.connectionRefused
                }
            } else if methodReply[1] != 0x00 {
                throw SOCKS5Error.unsupportedMethod
            }

            // 4. CONNECT request with domain-name addressing.
            var request: [UInt8] = [0x05, 0x01, 0x00, 0x03]
            let hostBytes = Array(targetHost.utf8)
            guard hostBytes.count <= 255 else { throw SOCKS5Error.badResponse }
            request.append(UInt8(hostBytes.count))
            request.append(contentsOf: hostBytes)
            request.append(UInt8((targetPort >> 8) & 0xff))
            request.append(UInt8(targetPort & 0xff))
            try await send(bytes: request, descriptor: descriptor, until: deadline)

            // 5. Reply: version, status, reserved, atyp, then address + port.
            let header = try await recvExact(count: 4, descriptor: descriptor, until: deadline)
            guard header[0] == 0x05 else { throw SOCKS5Error.badResponse }
            switch header[1] {
            case 0x00: break // success
            case 0x01: throw SOCKS5Error.connectionRefused
            case 0x04: throw SOCKS5Error.unreachable
            case 0x05: throw SOCKS5Error.connectionRefused
            default: throw SOCKS5Error.connectionRefused
            }
            let atyp = header[3]
            switch atyp {
            case 0x01: _ = try await recvExact(count: 4, descriptor: descriptor, until: deadline)
            case 0x03:
                let lenBytes = try await recvExact(count: 1, descriptor: descriptor, until: deadline)
                _ = try await recvExact(count: Int(lenBytes[0]), descriptor: descriptor, until: deadline)
            case 0x04: _ = try await recvExact(count: 16, descriptor: descriptor, until: deadline)
            default: throw SOCKS5Error.badResponse
            }
            _ = try await recvExact(count: 2, descriptor: descriptor, until: deadline)

            // 6. Hand the (non-blocking) descriptor to the caller; the SSH
            //    runtime flips it back to blocking as needed.
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    // MARK: - Raw I/O (non-blocking)

    private static func send(
        bytes: [UInt8],
        descriptor: Int32,
        until deadline: ContinuousClock.Instant
    ) async throws {
        try checkCancelled(until: deadline)
        var offset = 0
        while offset < bytes.count {
            try await SocketReadiness.wait(
                descriptor: descriptor,
                directions: .write,
                until: deadline)
            let sent = bytes.withUnsafeBytes { buffer -> Int in
                Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent < 0 {
                if errno == EINTR { continue }
                throw SOCKS5Error.badResponse
            }
            offset += sent
        }
    }

    private static func recvExact(
        count: Int,
        descriptor: Int32,
        until deadline: ContinuousClock.Instant
    ) async throws -> [UInt8] {
        try checkCancelled(until: deadline)
        var result = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            try await SocketReadiness.wait(
                descriptor: descriptor,
                directions: .read,
                until: deadline)
            let got = Darwin.recv(
                descriptor,
                result.withUnsafeMutableBytes { $0.baseAddress!.advanced(by: offset) },
                count - offset,
                0)
            if got < 0 {
                if errno == EINTR { continue }
                throw SOCKS5Error.badResponse
            }
            if got == 0 { throw SOCKS5Error.badResponse }
            offset += got
        }
        return result
    }

    private static func checkCancelled(until deadline: ContinuousClock.Instant) throws {
        if Task.isCancelled { throw SSHError.cancelled }
        if ContinuousClock.now >= deadline { throw SSHError.timedOut }
    }
}
