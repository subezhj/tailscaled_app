import XCTest
import Foundation
import Darwin
@testable import HeelerSSH

/// Verifies the SOCKS5 client against a minimal in-process SOCKS5 server.
/// No Tailscale node involved — this pins the wire protocol (RFC 1928) that
/// the embedded libtailscale node speaks on its local proxy port.
final class SOCKS5ConnectorTests: XCTestCase {

    /// Minimal SOCKS5 server: greeting exchange (optionally auth), CONNECT,
    /// then echoes bytes. Runs on a thread; accepts exactly one connection.
    private final class MiniSocksServer: @unchecked Sendable {
        let listenerFD: Int32
        let port: UInt16
        let requiredUser: String?
        let requiredPass: String?

        init(requiredUser: String? = nil, requiredPass: String? = nil) throws {
            self.requiredUser = requiredUser
            self.requiredPass = requiredPass
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0 // ephemeral
            addr.sin_addr.s_addr = INADDR_LOOPBACK
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            listen(fd, 1)
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = getsockname(fd, $0, &len)
                }
            }
            self.listenerFD = fd
            self.port = UInt16(addr.sin_port.bigEndian)
        }

        /// Accepts one connection, performs a full SOCKS5 handshake, then echoes
        /// everything received back until EOF. Runs synchronously; call in a Task.
        func serveOnce(echoEcho: Bool = true) {
            let clientFD = accept(listenerFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { close(clientFD) }

            // Greeting
            var buf = [UInt8](repeating: 0, count: 2)
            guard recv(clientFD, &buf, 2, 0) == 2 else { return }
            guard buf[0] == 5 else { return }
            if let user = requiredUser {
                // Server offers only username/password auth.
                guard buf[1] == 2 else { return }
                var authReply: [UInt8] = [5, 2]
                authReply.withUnsafeBytes { _ = send(clientFD, $0.baseAddress!, 2, 0) }
                // Auth: ver, ulen, user, plen, pass
                var ver: UInt8 = 0
                guard recv(clientFD, &ver, 1, 0) == 1, ver == 1 else { return }
                var ulen: UInt8 = 0
                guard recv(clientFD, &ulen, 1, 0) == 1 else { return }
                var u = [UInt8](repeating: 0, count: Int(ulen))
                guard recvExact(clientFD, &u, Int(ulen)) else { return }
                var plen: UInt8 = 0
                guard recv(clientFD, &plen, 1, 0) == 1 else { return }
                var p = [UInt8](repeating: 0, count: Int(plen))
                guard recvExact(clientFD, &p, Int(plen)) else { return }
                let userOK = String(decoding: u, as: UTF8.self) == user
                let passOK = String(decoding: p, as: UTF8.self) == (requiredPass ?? "")
                var status: [UInt8] = [1, userOK && passOK ? 0 : 1]
                status.withUnsafeBytes { _ = send(clientFD, $0.baseAddress!, 2, 0) }
                guard userOK && passOK else { return }
            } else {
                guard buf[1] == 1 else { return }
                var greetingReply: [UInt8] = [5, 0]
                greetingReply.withUnsafeBytes { _ = send(clientFD, $0.baseAddress!, 2, 0) }
            }

            // Request: version, cmd, rsv, atyp(3=domain), len, host, port(2)
            var hdr = [UInt8](repeating: 0, count: 4)
            guard recvExact(clientFD, &hdr, 4) else { return }
            let namelen = Int(hdr[3])
            var name = [UInt8](repeating: 0, count: namelen)
            guard recvExact(clientFD, &name, namelen) else { return }
            var portBytes = [UInt8](repeating: 0, count: 2)
            guard recvExact(clientFD, &portBytes, 2) else { return }

            // Reply: version, 0(success), rsv, atyp(1=IPv4), 4 zeros, port 0
            var reply = [UInt8](repeating: 0, count: 10)
            reply[0] = 5
            reply[3] = 1
            reply.withUnsafeBytes { _ = send(clientFD, $0.baseAddress!, 10, 0) }

            // Echo loop
            if echoEcho {
                var b: UInt8 = 0
                while recv(clientFD, &b, 1, 0) == 1 {
                    _ = send(clientFD, &b, 1, 0)
                }
            } else {
                // Drain
                var b: UInt8 = 0
                while recv(clientFD, &b, 1, 0) == 1 {}
            }
        }

        private func recvExact(_ fd: Int32, _ buf: inout [UInt8], _ count: Int) -> Bool {
            var off = 0
            while off < count {
                let n = recv(fd, &buf[off], count - off, 0)
                if n <= 0 { return false }
                off += n
            }
            return true
        }

        func closeServer() { close(listenerFD) }
    }

    func testSOCKS5EchoRoundTrip() async throws {
        let server = try MiniSocksServer()
        defer { server.closeServer() }

        let serveTask = Task.detached { server.serveOnce() }

        let proxy = SOCKS5Connector.ProxyEndpoint(host: "127.0.0.1", port: server.port)
        let fd = try await SOCKS5Connector.connect(
            via: proxy,
            to: "tailnet-host.example.ts.net",
            targetPort: 22,
            until: ContinuousClock.now.advanced(by: .seconds(5)))

        // Turn blocking for plain read/write.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        let payload = Array("ping".utf8)
        payload.withUnsafeBytes { _ = Darwin.send(fd, $0.baseAddress!, payload.count, 0) }
        var echo = [UInt8](repeating: 0, count: 4)
        let got = Darwin.recv(fd, &echo, 4, 0)
        XCTAssertEqual(got, 4)
        XCTAssertEqual(String(decoding: echo, as: UTF8.self), "ping")

        Darwin.close(fd)
        await serveTask.value
    }

    func testSOCKS5AuthRoundTrip() async throws {
        // Mirrors libtailscale's loopback proxy: it demands user/pass auth.
        let server = try MiniSocksServer(requiredUser: "ts-user", requiredPass: "ts-pass")
        defer { server.closeServer() }

        let serveTask = Task.detached { server.serveOnce() }

        let proxy = SOCKS5Connector.ProxyEndpoint(
            host: "127.0.0.1",
            port: server.port,
            username: "ts-user",
            password: "ts-pass")
        let fd = try await SOCKS5Connector.connect(
            via: proxy,
            to: "nas.tailnet.ts.net",
            targetPort: 22,
            until: ContinuousClock.now.advanced(by: .seconds(5)))

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        let payload = Array("pong".utf8)
        payload.withUnsafeBytes { _ = Darwin.send(fd, $0.baseAddress!, payload.count, 0) }
        var echo = [UInt8](repeating: 0, count: 4)
        let got = Darwin.recv(fd, &echo, 4, 0)
        XCTAssertEqual(got, 4)
        XCTAssertEqual(String(decoding: echo, as: UTF8.self), "pong")

        Darwin.close(fd)
        await serveTask.value
    }
}
