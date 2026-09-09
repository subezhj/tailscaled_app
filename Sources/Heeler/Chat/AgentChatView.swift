import SwiftUI

/// Phone-native conversation view for an agent. Reads the Host's claude
/// session transcript (see `ChatTranscriptStore`) and renders it as chat
/// bubbles instead of the raw TUI — Moshi-style. The underlying agent keeps
/// running; this is a view over the same session, not a separate connection.
struct AgentChatView: View {
    @State private var store: ChatTranscriptStore
    private let agent: ConsoleAgent
    private let console: ConsoleStore
    private let onSend: (String) -> Void
    private let theme: TerminalThemeOption
    private let colorScheme: ColorScheme

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        onSend: @escaping (String) -> Void,
        theme: TerminalThemeOption,
        colorScheme: ColorScheme
    ) {
        self.agent = agent
        self.console = console
        self.onSend = onSend
        self.theme = theme
        self.colorScheme = colorScheme
        _store = State(
            initialValue: ChatTranscriptStore.make(
                hostID: agent.hostID, console: console))
    }

    var body: some View {
        VStack(spacing: 0) {
            transcriptList
            Divider()
            composer
        }
        .task { store.loadIfNeeded() }
        // Reload when the agent changes status — the tail moved.
        .onChange(of: agent.agent.status) { _, _ in
            store.reload(force: true)
        }
        .background(chatBackground)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var chatBackground: Color {
        theme.surfaceBackground(for: colorScheme)
    }

    private var palette: TerminalThemePalette {
        theme.palette(for: colorScheme)
    }

    // MARK: - Transcript

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    switch store.phase {
                    case .idle, .loading:
                        ProgressView().padding(.top, 48)
                    case .failed(let message):
                        failedState(message)
                    case .loaded:
                        if store.messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(store.messages) { message in
                                ChatBubbleRow(
                                    message: message,
                                    theme: theme,
                                    colorScheme: colorScheme)
                                .id(message.id)
                            }
                            loadMoreSpacer(proxy)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { store.reload(force: true) }
        }
    }

    private func loadMoreSpacer(_ proxy: ScrollViewProxy) -> some View {
        Color.clear
            .frame(height: 1)
            .id("__bottom__")
            .onAppear {
                // Scroll to the newest message once content lands.
                if let last = store.messages.first {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Couldn't load the conversation")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { store.reload(force: true) }
                .buttonStyle(.bordered)
        }
        .padding(.top, 48)
        .padding(.horizontal, 24)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No conversation yet")
                .font(.headline)
            Text("Start typing below to talk to this agent.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 48)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(agent.agent.name ?? agent.agent.kind)", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(composerFieldBackground))
                .onSubmit { submit() }

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(composerBarBackground)
    }

    private var composerFieldBackground: Color {
        palette.background.opacity(0.4)
    }

    private var composerBarBackground: Color {
        theme.surfaceBackground(for: colorScheme)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onSend(text)
        // Optimistic: reload shortly after sending so the echoed prompt and
        // the agent's first activity appear without waiting for a status
        // change that may not arrive for a while.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            store.reload(force: true)
        }
    }
}

// MARK: - Bubble row

/// One chat bubble: user text on the right, assistant text/thinking/tools on
/// the left, with per-message usage (tokens) when present.
private struct ChatBubbleRow: View {
    let message: ClaudeTranscript.Message
    let theme: TerminalThemeOption
    let colorScheme: ColorScheme

    @State private var isThinkingExpanded = false
    @State private var isToolExpanded = false

    private var isUser: Bool { message.role == .user }
    private var palette: TerminalThemePalette {
        theme.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ClaudeTranscript.Message.Block) -> some View {
        switch block {
        case .text(let text):
            bubble(Text(text), isUser: isUser)
        case .thinking(let text):
            thinkingView(text)
        case .tool(let call):
            toolView(call)
        case .attachment(let media):
            attachmentView(media)
        case .unknown(let note):
            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func bubble(_ content: Text, isUser: Bool) -> some View {
        content
            .textSelection(.enabled)
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(bubbleColor(isUser: isUser)))
            .foregroundStyle(bubbleTextColor(isUser: isUser))
            .frame(
                maxWidth: .infinity,
                alignment: isUser ? .trailing : .leading)
    }

    private func bubbleColor(isUser: Bool) -> Color {
        if isUser {
            return palette.accent
        }
        return palette.background
            .opacity(isDarkChrome ? 1 : 0.55)
    }

    private var isDarkChrome: Bool {
        theme.chromeColorScheme(for: colorScheme) == .dark
    }

    private func bubbleTextColor(isUser: Bool) -> Color {
        if isUser {
            // Accent bubble on top of the theme's background; white text
            // stays legible for the curated dark accents, and the palette
            // foreground reads on the light ones.
            return isDarkChrome ? .white : palette.foreground
        }
        return palette.foreground
    }

    private func thinkingView(_ text: String) -> some View {
        DisclosureGroup(isExpanded: $isThinkingExpanded) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            Label("Thinking", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(palette.background.opacity(0.35)))
    }

    private func toolView(_ call: ClaudeTranscript.Message.ToolCall) -> some View {
        DisclosureGroup(isExpanded: $isToolExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let input = call.input, let summary = Self.toolSummary(input) {
                    Text(summary)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if let result = call.result {
                    Text(result)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                } else if call.isPending {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption)
                Text(call.name)
                    .font(.caption.weight(.medium))
                if call.isPending {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
        }
        .padding(8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(palette.background.opacity(0.35)))
    }

    private func attachmentView(_ media: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            Text("Image (\(media))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(palette.background.opacity(0.35)))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let usage = message.usage, usage.inputTokens > 0 {
                Label(
                    "\(usage.inputTokens) in · \(usage.outputTokens) out",
                    systemImage: "arrow.left.arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let timestamp = message.timestamp {
                Text(timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }

    static func toolSummary(_ input: JSONValue) -> String? {
        // Common single-field tools: {command: "..."} / {file_path: "..."}.
        for key in ["command", "file_path", "path", "pattern", "query"] {
            if let value = input[key]?.stringValue {
                return "\(key): \(value)"
            }
        }
        return nil
    }
}
