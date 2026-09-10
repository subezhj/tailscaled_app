import Foundation

/// One tailnet peer's connection health, decoded from the embedded node's
/// `statusJSON`. UI reads this to answer two questions:
/// - Is the peer reachable at all? (`online` + fresh handshake)
/// - Is traffic riding a DERP relay (slow, and only about the *path*, not a
///   failure) or a direct P2P connection (fast)?
///
/// Decoded in `TailnetNodeController`; kept here so views and stores can
/// consume the shape without touching TailscaleKit types (standing repo rule:
/// UI depends on app abstractions, never on library types).
struct TailnetPeerHealth: Equatable, Sendable {
    let online: Bool
    /// Non-nil when traffic to this peer is relayed through a DERP node
    /// ("derp-123" style id). nil means a direct P2P path (or unknown).
    let relay: String?
    /// Last successful WireGuard handshake; nil when never established.
    let lastHandshake: Date?

    /// Direct P2P path (the fast case). `relay == nil` is the observable
    /// signal tailscale itself uses for "direct".
    var isRelayed: Bool { relay != nil }

    /// Reachable and freshly handshaken. A long-stale handshake on an
    /// online peer means the path died without a state transition — the
    /// health monitor's re-dial trigger.
    var isHealthy: Bool {
        online && handshakeIsFresh
    }

    private var handshakeIsFresh: Bool {
        guard let lastHandshake else { return false }
        return Date().timeIntervalSince(lastHandshake) < Self.staleHandshakeWindow
    }

    /// A peer with no recent handshake is treated as stale even when the
    /// status still reports it online; this is the window.
    static let staleHandshakeWindow: TimeInterval = 90
}
