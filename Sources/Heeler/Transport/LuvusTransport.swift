import Foundation

/// A Transport whose Host runs **luvus** (the Rust agent console) instead of
/// herdr. Both speak the same NDJSON wire envelope
/// (`{"id","method","params"}` → `{"id","result"}`/`{"id","error"}`), and
/// luvus exposes its UHP methods over `luvus uhp proxy`: an exec channel
/// whose stdin carries one request line and whose stdout returns one
/// response line. That is exactly `SSHConnection.executeResponseLine`, so
/// this transport reuses the Heeler SSH connection (jump hosts, host-key
/// TOFU, authentication) and only swaps the request transport.
///
/// **Scope**: this first slice implements `ping()` only (via
/// `uhp.capabilities`, a parameterless self-describing call). The remaining
/// `Transport` methods inherit the protocol's honest "unavailable" defaults —
/// a luvus Host connects and pings, and the Console surfaces that the
/// backend's full method set is not wired up yet instead of fabricating
/// responses from guessed field shapes. Mapping the rest is a per-method
/// exercise against luvus's published UHP schema (the same way the herdr
/// methods were mapped from `herdr api schema`), and lives entirely in this
/// file.
///
/// Kept deliberately thin and decoupled: upstream merges that touch
/// `HeelerSSHTransport` or `Transport` do not collide with this file.
struct LuvusTransport: Transport {
    private let ssh: HeelerSSHTransport

    init(ssh: HeelerSSHTransport) {
        self.ssh = ssh
    }

    var isConnected: Bool {
        get async { await ssh.isConnected }
    }

    func close() async throws {
        try await ssh.close()
    }

    // MARK: - UHP methods

    /// UHP's `uhp.capabilities` doubles as ping: it returns the live method
    /// catalog the endpoint may call. The app's ping contract is "the server
    /// answered and speaks our protocol"; decoding the capability envelope
    /// proves exactly that.
    func ping() async throws -> ServerInfo {
        struct Capabilities: Decodable, Sendable {
            let version: String?
        }
        let caps = try await ssh.performLuvusRequest(
            method: "uhp.capabilities",
            params: HerdrWire.EmptyParams(),
            decoding: Capabilities.self)
        return ServerInfo(
            version: caps.version ?? "luvus",
            protocolVersion: 1)
    }
}