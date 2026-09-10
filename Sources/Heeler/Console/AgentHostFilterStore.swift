import Foundation
import Observation

/// Per-Host Agent visibility for the Console. A Host can be disabled from
/// the Agent list: its Agents disappear from the sidebar and from the
/// terminal switcher's chip strip, and the Host's tab renders greyed out.
///
/// Decoupled by design (merge-friendly): this store knows nothing about
/// ConsoleStore, EventsSession, or any transport type. The Console reads it
/// to filter its inputs; the switcher reads it to filter its chips; Settings
/// writes it. Default is every Host enabled, so existing installs and
/// freshly added Hosts behave exactly as before until the user opts out.
@MainActor
@Observable
final class AgentHostFilterStore {
    private static let disabledHostsDefaultsKey = "console-list.disabled-hosts"

    /// Hosts the user has disabled. Everything else is enabled; a Host not
    /// in the catalog is implicitly enabled.
    private(set) var disabledHostIDs: Set<Host.ID>
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        disabledHostIDs = Set(
            (defaults.stringArray(forKey: Self.disabledHostsDefaultsKey) ?? [])
                .compactMap(UUID.init(uuidString:)))
    }

    /// Whether this Host's Agents should appear in the Console.
    func isEnabled(_ hostID: Host.ID) -> Bool {
        !disabledHostIDs.contains(hostID)
    }

    func setEnabled(_ enabled: Bool, for hostID: Host.ID) {
        let changed: Bool
        if enabled {
            changed = disabledHostIDs.remove(hostID) != nil
        } else {
            changed = disabledHostIDs.insert(hostID).inserted
        }
        guard changed else { return }
        defaults.set(
            disabledHostIDs.map(\.uuidString).sorted(),
            forKey: Self.disabledHostsDefaultsKey)
    }

    func toggle(_ hostID: Host.ID) {
        setEnabled(isEnabled(hostID) ? false : true, for: hostID)
    }

    /// Hosts filtered to those currently enabled (catalog order preserved).
    func enabledHosts(from hosts: [Host]) -> [Host] {
        hosts.filter { isEnabled($0.id) }
    }

    /// Agents filtered to those on enabled Hosts, preserving the input order
    /// (which is ConsoleStore's already-sorted sequence).
    func enabledAgents(from agents: [ConsoleAgent]) -> [ConsoleAgent] {
        guard !disabledHostIDs.isEmpty else { return agents }
        return agents.filter { isEnabled($0.hostID) }
    }
}