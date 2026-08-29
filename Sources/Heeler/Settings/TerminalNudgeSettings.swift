import Foundation
import Observation

/// Whether the Attach terminal sends a shrink-then-restore resize "nudge" on
/// foreground return.
///
/// The nudge exists because herdr's TUI (ratatui) only repaints when the
/// terminal size actually changes; a return to the app can otherwise leave a
/// stale frame on screen. The cost is a visible small→large reflow each time,
/// which some users find distracting. Shared via UserDefaults so the toggle in
/// Settings and the read in `AttachTerminalStore.didBecomeActive` can never
/// disagree.
@MainActor
@Observable
final class TerminalNudgeSettings {
    private nonisolated static let defaultsKey = "terminal-refresh-nudge-enabled"

    /// The single source of truth for whether nudging is on. Kept as a plain
    /// UserDefaults read so the terminal store can consult it without owning a
    /// reference to the settings object (the store lives deep in the console
    /// and is not worth threading one through).
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the resize nudge is enabled. Default true (matches upstream).
    var isEnabled: Bool {
        get {
            defaults.object(forKey: Self.defaultsKey) == nil
                ? true
                : defaults.bool(forKey: Self.defaultsKey)
        }
        set {
            defaults.set(newValue, forKey: Self.defaultsKey)
        }
    }

    /// Nonisolated read for the terminal store.
    nonisolated static func nudgeEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Self.defaultsKey) == nil
            ? true
            : defaults.bool(forKey: Self.defaultsKey)
    }
}
