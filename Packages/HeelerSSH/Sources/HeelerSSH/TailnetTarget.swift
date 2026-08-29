import Foundation

/// Decides whether a host is a Tailscale tailnet destination that should ride
/// the embedded node's SOCKS5 proxy, or an ordinary host to dial directly.
///
/// This is the split-tunnel policy aperture uses: the tsnet loopback proxy can
/// only dial tailnet destinations (`100.64.0.0/10`, MagicDNS `*.ts.net`), so
/// routing EVERY connection through it breaks non-tailnet hosts (the failure
/// mode reported as `connectionFailed` when a user enters a LAN IP while the
/// proxy is active). Tailnet destinations go through the proxy (which resolves
/// MagicDNS names); everything else — LAN IPs, public IPs — dials directly.
enum TailnetTarget {
    /// True if `host` (as entered in a Host's address field) is a tailnet
    /// destination.
    static func isTailnet(_ host: String) -> Bool {
        if host.hasSuffix(".ts.net") { return true }
        if isTailnetIPv4(host) { return true }
        if isTailnetIPv6(host) { return true }
        return false
    }

    /// Tailscale v4 addresses live in the CGNAT range 100.64.0.0/10:
    /// first octet 100, second octet 64…127.
    private static func isTailnetIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4,
              let a = UInt8(parts[0]),
              let b = UInt8(parts[1]) else { return false }
        return a == 100 && b >= 64 && b <= 127
    }

    /// Tailscale v6 addresses use the ULA prefix fd7a:115c:a1e0::/48.
    private static func isTailnetIPv6(_ value: String) -> Bool {
        value.lowercased().hasPrefix("fd7a:115c:a1e0")
    }
}