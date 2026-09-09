import Foundation

/// A parsed claude-code session transcript, rendered as phone-native chat
/// instead of the TUI. The data source is the agent's own session JSONL
/// (`~/.claude/projects/<slug>/<session>.jsonl`), read over SSH exec — the
/// same files the TUI is backed by, so the two views never drift.
enum ClaudeTranscript {
    /// One chat bubble (or tool activity) in the transcript.
    struct Message: Identifiable, Equatable, Sendable {
        enum Role: String, Sendable {
            case user
            case assistant
            case system
        }

        /// A block inside a message. claude content blocks are heterogeneous;
        /// only the ones we render as chat are kept, and tool traffic is
        /// paired (tool_use + its tool_result) into a single card.
        enum Block: Equatable, Sendable {
            case text(String)
            case thinking(String)
            case tool(ToolCall)
            /// Attachments (images) the user dropped into the conversation.
            /// The JSONL stores a local file reference; we render a note
            /// rather than shipping the bytes over exec.
            case attachment(String)
            case unknown(String)
        }

        struct ToolCall: Equatable, Sendable {
            let id: String
            let name: String
            /// Parsed JSON of the call's arguments; rendered inline when
            /// small, summarized otherwise.
            let input: JSONValue?
            /// Result text from the paired tool_result row, if any.
            let result: String?
            /// Whether the tool call is still in flight (no result yet).
            var isPending: Bool { result == nil }
        }

        struct Usage: Equatable, Sendable {
            let inputTokens: Int
            let outputTokens: Int
            let cacheReadTokens: Int
        }

        let id: String
        let role: Role
        let blocks: [Block]
        let timestamp: Date?
        let cwd: String?
        let usage: Usage?
    }

    /// The exec command that locates the most recently modified claude
    /// session file and emits its tail between markers. One round trip, no
    /// shell interpolation of host content (the file name travels inside the
    /// marker line, not in the script body). POSIX `ls -t` keeps the probe
    /// identical on Linux and macOS Hosts.
    ///
    /// Markers mirror `SkillProbe`'s framing so login-shell noise cannot
    /// leak into the parsed transcript.
    static let startMarker = "__HEELER_CHAT_START__"
    static let endMarker = "__HEELER_CHAT_END__"
    /// Tail window: enough lines for a working session without flooding a
    /// slow tailnet/DERP channel. 400 lines covers a long agent turn.
    static let tailLines = 400
    /// Cap on a single attachment row's carried text so a huge file cannot
    /// flood the channel.
    static let maximumBytesPerBlock = 64 * 1024

    /// Latest claude session across every project. Project-scoping by cwd is
    /// a later refinement; the most recently touched session is the right
    /// answer for "what is my agent doing right now" in the common single-
    /// project case.
    static func latestSessionCommand() -> String {
        let glob = "$HOME/.claude/projects/*/*.jsonl"
        return "/bin/sh -c '"
            + "f=$(ls -t \(glob) 2>/dev/null | head -1); "
            + "[ -n \"$f\" ] || exit 0; "
            + "printf \"\(startMarker)%s\\n\" \"$f\"; "
            + "tail -n \(tailLines) \"$f\"; "
            + "printf \"\\n\(endMarker)\\n\""
            + "' herdr-chat-read"
    }

    /// Splits the raw exec output into (sessionPath, tailData) using the
    /// markers; nil when the probe found no session at all.
    static func extractPayload(from output: Data) -> (sessionPath: String, data: Data)? {
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        guard let start = text.range(of: startMarker),
            let end = text.range(of: endMarker, options: .backwards),
            start.upperBound < end.lowerBound
        else {
            return nil
        }
        // The session path rides on the marker line itself: from the marker's
        // end to the next newline. The payload is everything between that
        // newline and the closing marker. Both ranges index the original
        // `text`, so no Substring-relative index math is involved.
        let lineEnd = text[start.upperBound...].firstIndex(of: "\n")
            ?? text.index(before: end.lowerBound)
        let headerLine = text[start.upperBound..<lineEnd]
        let payload = text[lineEnd..<end.lowerBound]
        return (String(headerLine), Data(payload.utf8))
    }

    /// Parses the JSONL payload into messages, newest-first for chat
    /// rendering. Non-user/assistant rows (mode, system, attachment,
    /// ai-title…) are metadata, not conversation, and are dropped — except
    /// tool_result rows, which are consumed by the preceding assistant
    /// tool_use and never surface standalone.
    static func parse(_ data: Data, sessionPath: String) -> [Message] {
        let rows = data.split(separator: 0x0A).compactMap { line -> [String: Any]? in
            guard !line.isEmpty,
                let obj = try? JSONSerialization.jsonObject(
                    with: Data(line), options: [.fragmentsAllowed])
            else { return nil }
            return obj as? [String: Any]
        }

        var messages: [Message] = []
        // tool_use id → index of its Message in `messages`, so a later
        // tool_result row can attach to it.
        var pendingTools: [String: (msgIndex: Int, blockIndex: Int)] = [:]

        for row in rows {
            guard let type = row["type"] as? String else { continue }
            let message = row["message"] as? [String: Any]
            let uuid = row["uuid"] as? String
                ?? (message?["id"] as? String)
                ?? UUID().uuidString
            let timestamp = Self.parseTimestamp(row["timestamp"] as? String)

            if type == "user" {
                // A user row carrying tool_result content is not a new
                // bubble; fold each result into its matching tool_use.
                if let content = message?["content"] as? [[String: Any]] {
                    var hadToolResult = false
                    for block in content {
                        guard let blockType = block["type"] as? String,
                            blockType == "tool_result"
                        else { continue }
                        hadToolResult = true
                        guard let toolUseID = block["tool_use_id"] as? String,
                            let slot = pendingTools[toolUseID]
                        else { continue }
                        messages[slot.msgIndex].blocks[slot.blockIndex] =
                            .tool(
                                ToolCall(
                                    id: toolUseID,
                                    name: Self.toolName(
                                        in: messages[slot.msgIndex]
                                            .blocks[slot.blockIndex]),
                                    input: Self.toolInput(
                                        in: messages[slot.msgIndex]
                                            .blocks[slot.blockIndex]),
                                    result: Self.toolResultText(block)))
                        pendingTools[toolUseID] = nil
                    }
                    if hadToolResult { continue }
                }
                // Plain user bubble.
                messages.append(
                    Self.message(
                        id: uuid,
                        role: .user,
                        row: row,
                        message: message,
                        timestamp: timestamp))
                continue
            }

            if type == "assistant" {
                var blocks: [Block] = []
                var usage: Usage?
                if let u = message?["usage"] as? [String: Any] {
                    usage = Usage(
                        inputTokens: (u["input_tokens"] as? Int) ?? 0,
                        outputTokens: (u["output_tokens"] as? Int) ?? 0,
                        cacheReadTokens: (u["cache_read_input_tokens"] as? Int) ?? 0)
                }
                let content = message?["content"]
                if let blocksArray = content as? [[String: Any]] {
                    for block in blocksArray {
                        guard let blockType = block["type"] as? String else {
                            continue
                        }
                        switch blockType {
                        case "text":
                            if let t = block["text"] as? String {
                                blocks.append(.text(t))
                            }
                        case "thinking":
                            if let t = block["thinking"] as? String {
                                blocks.append(.thinking(t))
                            }
                        case "tool_use":
                            let toolID = block["id"] as? String
                                ?? UUID().uuidString
                            let name = block["name"] as? String ?? "tool"
                            let input = Self.jsonValue(block["input"])
                            blocks.append(.tool(
                                ToolCall(
                                    id: toolID, name: name,
                                    input: input, result: nil)))
                            if let toolID = block["id"] as? String {
                                pendingTools[toolID] = (
                                    messages.count, blocks.count - 1)
                            }
                        default:
                            blocks.append(.unknown(
                                "\(blockType) (\(Self.describe(block)))"))
                        }
                    }
                } else if let text = content as? String {
                    blocks.append(.text(text))
                }
                let msg = Message(
                    id: uuid, role: .assistant, blocks: blocks,
                    timestamp: timestamp,
                    cwd: row["cwd"] as? String, usage: usage)
                messages.append(msg)
                continue
            }

            if type == "attachment" {
                // claude's `attachment` rows are internal metadata — agent
                // listing deltas, skill listings, token reminders — not user
                // files. User-dropped images arrive as `user` rows with an
                // `image` content block instead, so attachments are dropped
                // entirely rather than rendered as a fake bubble.
                continue
            }
        }
        return messages.reversed()
    }

    /// Rows whose text is claude's own internal chatter, not the user's
    /// words: slash-command echoes (`<command-name>`), local-command
    /// caveats, and permission banners. claude itself frames them in angle
    /// brackets; anything matching the known prefixes is invisible in the
    /// chat (the actions still happened on the Host).
    private static let invisibleUserPrefixes = [
        "<local-command-caveat>",
        "<local-command-stdout>",
        "<command-name>",
        "<command-message>",
        "<permission>",
        "<error>",
    ]

    private static func isInvisible(_ text: String) -> Bool {
        invisibleUserPrefixes.contains { text.hasPrefix($0) }
    }

    private static func message(
        id: String,
        role: Message.Role,
        row: [String: Any],
        message: [String: Any]?,
        timestamp: Date?
    ) -> Message {
        let content = message?["content"]
        var blocks: [Block] = []
        if let text = content as? String, !text.isEmpty {
            if !isInvisible(text) {
                blocks.append(.text(text))
            }
        } else if let array = content as? [[String: Any]] {
            for block in array {
                guard let blockType = block["type"] as? String else { continue }
                switch blockType {
                case "text":
                    if let t = block["text"] as? String,
                        !isInvisible(t)
                    {
                        blocks.append(.text(t))
                    }
                case "image":
                    // A user-dropped image. The JSONL carries source
                    // metadata, not the bytes; render a note instead of
                    // shipping the file over exec.
                    let mediaType = block["media_type"] as? String ?? "image"
                    blocks.append(.attachment(mediaType))
                case "tool_result": break // folded into assistant tool_use
                default:
                    blocks.append(.unknown(
                        "\(blockType) (\(Self.describe(block)))"))
                }
            }
        }
        return Message(
            id: id, role: role, blocks: blocks, timestamp: timestamp,
            cwd: row["cwd"] as? String, usage: nil)
    }

    // MARK: - Block helpers

    private static func toolName(in block: Block) -> String {
        if case .tool(let call) = block { return call.name }
        return "tool"
    }

    private static func toolInput(in block: Block) -> JSONValue? {
        if case .tool(let call) = block { return call.input }
        return nil
    }

    private static func toolResultText(_ block: [String: Any]) -> String? {
        let content = block["content"]
        if let text = content as? String { return Self.trimmed(text) }
        if let array = content as? [[String: Any]] {
            var parts: [String] = []
            for item in array {
                if let t = item["text"] as? String {
                    parts.append(t)
                } else if let t = item["content"] as? String {
                    parts.append(t)
                }
            }
            return parts.isEmpty ? nil : Self.trimmed(parts.joined(separator: "\n"))
        }
        return nil
    }

    private static func jsonValue(_ value: Any?) -> JSONValue? {
        guard let value else { return nil }
        if let v = value as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, sub) in v { out[k] = jsonValue(sub) }
            return .object(out)
        }
        if let v = value as? [Any] {
            return .array(v.compactMap { jsonValue($0) })
        }
        if let v = value as? String { return .string(v) }
        if let v = value as? Double { return .number(v) }
        if let v = value as? Bool { return .bool(v) }
        if value is NSNull { return .null }
        return nil
    }

    private static func describe(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
            let text = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return String(text.prefix(120))
    }

    private static func trimmed(_ text: String) -> String {
        let max = maximumBytesPerBlock
        guard text.count > max else { return text }
        return String(text.prefix(max)) + "…"
    }

    private static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
