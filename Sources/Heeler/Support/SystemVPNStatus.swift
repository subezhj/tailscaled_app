import Foundation
import Darwin

/// Detects whether a system VPN tunnel is currently active.
///
/// LOON, Surge, Shadowrocket, and friends present as an `NEPacketTunnelProvider`
/// system VPN, which shows up in the interface list as one or more `utun`
/// interfaces. The embedded Tailscale node does **not** create one (it is a
/// userspace node, not a system tunnel), so a `utun` presence reliably means a
/// *third-party* VPN/proxy app is running — the most common reason a tailnet
/// SSH dial rides the wrong path or the control plane cannot be reached.
///
/// This is a heuristic (a real VPN and a fake "VPN" both create `utun`), so the
/// UI presents it as guidance ("a VPN appears to be active") rather than a
/// fact, and never blocks on it.
enum SystemVPNStatus {
    /// True when at least one `utun` interface exists. Cheap enough to call
    /// on demand from the UI; the interface list scan is a few syscalls.
    static func isActive() -> Bool {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else {
            return false
        }
        defer { freeifaddrs(addressList) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            let name = entry.pointee.ifa_name
            if let name, String(cString: name).hasPrefix("utun") {
                return true
            }
            current = entry.pointee.ifa_next
        }
        return false
    }
}
