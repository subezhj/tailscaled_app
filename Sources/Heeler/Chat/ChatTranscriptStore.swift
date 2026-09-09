import Foundation
import Observation

/// Loads and parses the Host's claude session transcript for the Chat view.
/// Data flows over the same exec channel as the skills probe, so this store
/// works on any transport that has a real Host process environment.
@MainActor
@Observable
final class ChatTranscriptStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var messages: [ClaudeTranscript.Message] = []
    private(set) var sessionPath: String?
    /// Monotonic counter bumped on every successful reload so the UI can
    /// re-run its scroll-to-bottom exactly when new content lands.
    private(set) var generation = 0

    private let load: () async throws -> Data
    private var loadTask: Task<Void, Never>?

    init(load: @escaping () async throws -> Data) {
        self.load = load
    }

    /// Convenience for production: wire straight to a transport via the
    /// Console store's host projection.
    @MainActor
    static func make(hostID: Host.ID, console: ConsoleStore) -> ChatTranscriptStore {
        ChatTranscriptStore { [console, hostID] in
            try await console.readClaudeTranscript(on: hostID)
        }
    }

    func loadIfNeeded(force: Bool = false) {
        guard phase == .idle || force else { return }
        reload(force: force)
    }

    func reload(force: Bool = false) {
        guard loadTask == nil else {
            if force { loadTask?.cancel(); loadTask = nil }
            else { return }
        }
        phase = .loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.load()
                guard let payload = ClaudeTranscript.extractPayload(from: output) else {
                    self.phase = .loaded
                    self.messages = []
                    self.sessionPath = nil
                    self.generation += 1
                    return
                }
                let parsed = ClaudeTranscript.parse(payload.data, sessionPath: payload.sessionPath)
                guard !Task.isCancelled else { return }
                self.sessionPath = payload.sessionPath
                self.messages = parsed
                self.generation += 1
                self.phase = .loaded
            } catch is CancellationError {
                // leave phase alone; a newer reload owns the store
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
            self.loadTask = nil
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }
}
