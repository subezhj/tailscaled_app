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
/// **Scope**: this slice implements `ping()` only (via `uhp.capabilities`, a
/// parameterless self-describing call). Every other `Transport` method
/// inherits the protocol's honest "unavailable" defaults — a luvus Host
/// connects and pings, and the Console surfaces that the backend's full
/// method set is not wired up yet instead of fabricating responses from
/// guessed field shapes. Mapping the rest is a per-method exercise against
/// luvus's published UHP schema (the same way the herdr methods were mapped
/// from `herdr api schema`), and lives entirely in this file.
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

    // MARK: - Honest "not wired up yet" for the remaining required methods

    /// UHP's event stream exists but this build has not mapped the wire
    /// shapes yet; a luvus Host must not claim a live Console feed it cannot
    /// deliver.
    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws
        -> HerdrEventStream
    {
        throw TransportError.channelFailed(
            detail: "luvus event streaming is not wired up yet.")
    }

    func attachTerminal(_ request: TerminalAttachRequest) async throws
        -> TerminalAttachSession
    {
        throw TransportError.channelFailed(
            detail: "luvus terminal attach is not wired up yet.")
    }

    func sendAgentKeys(_ params: AgentSendKeysParams) async throws {
        throw TransportError.channelFailed(
            detail: "luvus agent key control is not wired up yet.")
    }

    func closePane(_ params: PaneTarget) async throws {
        throw TransportError.channelFailed(
            detail: "luvus pane control is not wired up yet.")
    }

    func renameAgent(_ params: AgentRenameParams) async throws {
        throw TransportError.channelFailed(
            detail: "luvus agent rename is not wired up yet.")
    }

    func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
        throw TransportError.channelFailed(
            detail: "luvus workspace rename is not wired up yet.")
    }

    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        throw TransportError.channelFailed(
            detail: "luvus agent launches are not wired up yet.")
    }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec
    ) async throws -> Agent {
        throw TransportError.channelFailed(
            detail: "luvus worktree launches are not wired up yet.")
    }

    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        throw TransportError.channelFailed(
            detail: "luvus workspace launches are not wired up yet.")
    }

    func listAgents() async throws -> [Agent] {
        throw TransportError.channelFailed(
            detail: "luvus agent listing is not wired up yet.")
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        throw TransportError.channelFailed(
            detail: "luvus session snapshot is not wired up yet.")
    }

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        throw TransportError.channelFailed(
            detail: "luvus pane reads are not wired up yet.")
    }

    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
        throw TransportError.channelFailed(
            detail: "luvus agent reads are not wired up yet.")
    }

    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        throw TransportError.channelFailed(
            detail: "luvus prompting is not wired up yet.")
    }
}
