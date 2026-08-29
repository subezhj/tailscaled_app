import Foundation
import Observation

/// Whether the terminal should use local ghostty scrollback (instant, no
/// network) instead of sending remote escape sequences when herdr's TUI is in
/// alternate-screen mode.
///
/// Remote scroll (the default) sends scroll sequences to herdr, which then
/// re-renders the previous TUI frame — this is a full network round-trip
/// (often 600+ ms over tailnet DERP). The benefit is that the scrollback
/// shows the remote content. Local scroll uses ghostty's built-in
/// `scroll_page_lines` action, which is instant but shows whatever ghostty
/// has in its local buffer — in alternate-screen mode that may be empty or
/// limited, so the trade-off is smooth scrolling vs. visible scrollback.
@MainActor
@Observable
final class TerminalLocalScrollSettings {
    private nonisolated static let defaultsKey = "terminal-local-scroll-enabled"

    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether local (instant) scrollback is preferred over remote.
    /// Default false (remote scroll, full scrollback content).
    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.defaultsKey) }
        set { defaults.set(newValue, forKey: Self.defaultsKey) }
    }

    /// Nonisolated read for the UIKit terminal view.
    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }
}