import XCTest
@testable import Heeler

final class ClaudeTranscriptTests: XCTestCase {
    /// A realistic claude session payload: user prompt, assistant reply with
    /// thinking + text + tool_use, then a user row carrying the tool_result.
    private var sampleJSONL: String {
        """
        {"account":{"id":"acct","organization_id":"org"},"project":{"id":"p1","name":"-home-sube-github-tailscaled-app"},"git_branch":"main","git_commit":"abc123","sessionId":"7df8ab79","cwd":"/home/sube/github/tailscaled_app","type":"user","message":{"role":"user","content":"fix the scroll bug"},"uuid":"u1","timestamp":"2026-09-08T20:00:00.000Z"}
        {"isSidechain":false,"parentUuid":"u1","type":"assistant","message":{"id":"m2","type":"message","role":"assistant","model":"claude-opus-4-1-20250805","content":[{"type":"thinking","thinking":"The user reports scroll broken in terminal."},{"type":"text","text":"I'll look at the scroll handling."},{"type":"tool_use","id":"toolu_01","name":"Read","input":{"file_path":"Sources/Heeler/Terminal/TerminalScreenView.swift"}}],"usage":{"input_tokens":1200,"output_tokens":350,"cache_read_input_tokens":500}},"uuid":"a1","timestamp":"2026-09-08T20:00:05.000Z","cwd":"/home/sube/github/tailscaled_app","version":"2.0.0"}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"<file-content>scrollTouch is broken</file-content>"}]},"uuid":"u2","timestamp":"2026-09-08T20:00:06.000Z"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Found it: remove the local-scroll branch."}]},"uuid":"a2","timestamp":"2026-09-08T20:00:09.000Z"}
        {"type":"user","message":{"role":"user","content":"the scroll fix works, thanks"},"uuid":"u3","timestamp":"2026-09-08T20:00:12.000Z"}
        {"type":"system","subtype":"session-end","uuid":"sys1","timestamp":"2026-09-08T20:01:00.000Z"}
        """
    }

    func testExtractPayloadFindsSessionPath() throws {
        let framed = "__HEELER_CHAT_START__/home/sube/.claude/projects/x/y.jsonl\n"
            + sampleJSONL + "\n__HEELER_CHAT_END__\n"
        let payload = try XCTUnwrap(
            ClaudeTranscript.extractPayload(from: Data(framed.utf8)))
        XCTAssertEqual(
            payload.sessionPath,
            "/home/sube/.claude/projects/x/y.jsonl")
        XCTAssertTrue(payload.data.contains(",".data(using: .utf8)!))
    }

    func testExtractPayloadNilWithoutSession() {
        XCTAssertNil(ClaudeTranscript.extractPayload(from: Data("no markers".utf8)))
    }

    func testParsesMessagesNewestFirst() throws {
        let messages = ClaudeTranscript.parse(
            Data(sampleJSONL.utf8), sessionPath: "/x/y.jsonl")
        // user, assistant(thinking+text+tool), user(tool_result folded),
        // assistant(text), user(text) → 4 bubbles + system dropped
        XCTAssertEqual(messages.count, 4)

        // Newest first: last user bubble first.
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].blocks.first, .text("the scroll fix works, thanks"))

        // Second: assistant text-only reply.
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].blocks, [.text("Found it: remove the local-scroll branch.")])

        // Third: assistant with thinking + text + paired tool call.
        let toolMessage = messages[2]
        XCTAssertEqual(toolMessage.role, .assistant)
        XCTAssertEqual(toolMessage.blocks.count, 3)
        guard case .thinking(let t) = toolMessage.blocks[0] else {
            return XCTFail("expected thinking first")
        }
        XCTAssertEqual(t, "The user reports scroll broken in terminal.")
        guard case .tool(let call) = toolMessage.blocks[2] else {
            return XCTFail("expected tool block")
        }
        XCTAssertEqual(call.name, "Read")
        XCTAssertEqual(call.id, "toolu_01")
        // Tool result from the later user row must be folded in.
        XCTAssertEqual(call.isPending, false)
        XCTAssertEqual(call.result, "<file-content>scrollTouch is broken</file-content>")
        XCTAssertEqual(call.input?["file_path"]?.stringValue,
            "Sources/Heeler/Terminal/TerminalScreenView.swift")
        // Usage surfaced.
        XCTAssertEqual(toolMessage.usage?.inputTokens, 1200)
        XCTAssertEqual(toolMessage.usage?.outputTokens, 350)

        // Fourth: the original user prompt.
        XCTAssertEqual(messages[3].role, .user)
        XCTAssertEqual(messages[3].blocks.first, .text("fix the scroll bug"))

        // Timestamps parsed.
        XCTAssertNotNil(messages[0].timestamp)
    }

    func testToolResultRowDoesNotCreateBubble() {
        let messages = ClaudeTranscript.parse(
            Data(sampleJSONL.utf8), sessionPath: "/x/y.jsonl")
        let bubbleCount = messages.count
        // The tool_result-only user row must not add a bubble.
        XCTAssertEqual(bubbleCount, 4)
    }

    func testEmptyPayloadYieldsNoMessages() {
        XCTAssertTrue(ClaudeTranscript.parse(Data(), sessionPath: "/x").isEmpty)
    }

    func testRawStringContentAssistant() {
        let payload = """
        {"type":"assistant","message":{"role":"assistant","content":"plain text reply"},"uuid":"a","timestamp":"2026-09-08T20:00:00.000Z"}
        """
        let messages = ClaudeTranscript.parse(Data(payload.utf8), sessionPath: "/x")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].blocks, [.text("plain text reply")])
    }
}