import Foundation

/// A static catalog of common agent slash commands, merged with the remote
/// skills so `/`-triggered suggestions are useful even before (or without)
/// any skill files on the Host.
///
/// These are presented as ordinary `AgentSkill`s (scope `.global`, prefix
/// `/`), so they flow through the existing suggestion UI, the skills picker,
/// and the tools keyboard unchanged. The descriptions are shown as the
/// suggestion's subtitle. Because they are global-scope, they never
/// conflict with a project skill of the same name — the project one wins
/// during display (project skills sort first).
enum BuiltinCommandCatalog {
    /// The commands offered for an agent kind, in display order.
    static func commands(for kind: String) -> [AgentSkill] {
        switch kind.lowercased() {
        case "herdr":
            herdrCommands
        case "claude":
            claudeCommands
        case "codex":
            codexCommands
        default:
            // Unknown kinds still get the cross-agent basics.
            commonCommands
        }
    }

    /// Commands meaningful for any agent: a few no-arg conveniences.
    static let commonCommands: [AgentSkill] = [
        AgentSkill(
            scope: .global, name: "status", description: "Show the agent's current state",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "help", description: "List available commands",
            commandPrefix: "/", path: ""),
    ]

    /// herdr's own management surface (herdr CLI / TUI slash commands).
    static let herdrCommands: [AgentSkill] = [
        AgentSkill(
            scope: .global, name: "agents", description: "List agents and their panes",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "workspaces", description: "List workspaces",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "sessions", description: "List herdr sessions",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "status", description: "Show herdr runtime status",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "new", description: "Start a new agent",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "attach", description: "Attach to an existing agent",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "settings", description: "Open herdr settings",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "help", description: "List herdr commands",
            commandPrefix: "/", path: ""),
    ]

    /// Claude Code's slash commands.
    static let claudeCommands: [AgentSkill] = [
        AgentSkill(
            scope: .global, name: "compact", description: "Compact the conversation history",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "clear", description: "Clear the conversation",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "model", description: "Switch the model in use",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "cost", description: "Show the session's token cost",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "config", description: "Open configuration",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "review", description: "Review the current diff",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "help", description: "List Claude Code commands",
            commandPrefix: "/", path: ""),
    ]

    /// OpenAI Codex CLI's slash commands.
    static let codexCommands: [AgentSkill] = [
        AgentSkill(
            scope: .global, name: "help", description: "List Codex commands",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "compact", description: "Compact the session",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "reset", description: "Reset the session",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "cost", description: "Show usage and cost",
            commandPrefix: "/", path: ""),
        AgentSkill(
            scope: .global, name: "status", description: "Show session status",
            commandPrefix: "/", path: ""),
    ]
}
