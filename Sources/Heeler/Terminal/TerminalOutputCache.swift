import Foundation

/// Ring buffer of the raw terminal output bytes for one Attach session.
///
/// The problem: herdr's TUI runs in alternate-screen mode, so ghostty's own
/// scrollback for that screen is empty — scrolling has to ask the *remote*
/// herdr for previous frames, one network round-trip (hundreds of ms over a
/// tailnet/DERP path) per gesture. This cache keeps the raw bytes locally so
/// the UI can reconstruct history without touching the network.
///
/// It stores plain bytes plus newline-anchored line indexes, so the UI can
/// extract "the last N lines" cheaply. Data older than `capacityBytes` is
/// dropped (FIFO). Not Sendable: confined to the main actor with the session.
@MainActor
final class TerminalOutputCache {
    /// Maximum bytes retained. 4 MiB holds a few thousand terminal frames —
    /// enough to page back through a session without the file size becoming a
    /// problem.
    static let defaultCapacityBytes = 4 * 1024 * 1024

    private let capacityBytes: Int
    /// Raw byte history, most recent at the end.
    private var buffer = Data()
    /// Byte offsets of each line start (index into `buffer`). The first entry
    /// is always 0.
    private var lineStarts: [Int] = []

    init(capacityBytes: Int = TerminalOutputCache.defaultCapacityBytes) {
        self.capacityBytes = capacityBytes
    }

    /// Appends output bytes and maintains the line index, trimming old data
    /// once over capacity.
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        // Index line starts so the UI can cheaply grab the last N lines.
        let bytes = [UInt8](data)
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            lineStarts.append(buffer.count - bytes.count + index + 1)
        }
        trimIfNeeded()
    }

    /// The last `count` lines as raw bytes, or nil when fewer lines exist.
    /// Lines are newline-terminated; a trailing partial line is included when
    /// it is the newest data (it belongs to the current frame).
    func lastLines(_ count: Int) -> Data? {
        guard count > 0, !lineStarts.isEmpty || !buffer.isEmpty else { return nil }
        let available = lineStarts.count
        // +1 so a trailing partial line (no trailing \n yet) is included.
        let linesToTake = min(count, available + 1)
        let startOffset: Int
        if linesToTake <= available {
            startOffset = lineStarts[available - linesToTake]
        } else {
            startOffset = 0
        }
        guard startOffset < buffer.count else { return nil }
        return buffer.subdata(in: startOffset..<buffer.count)
    }

    /// Total lines currently retained.
    var lineCount: Int {
        lineStarts.count
    }

    /// Whether the cache holds any data at all.
    var isEmpty: Bool {
        buffer.isEmpty
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        lineStarts.removeAll(keepingCapacity: true)
    }

    // MARK: - Trimming

    private func trimIfNeeded() {
        guard buffer.count > capacityBytes else { return }
        // Drop whole lines from the front until under capacity. Keep at least
        // the most recent line so the cursor position stays coherent.
        while buffer.count > capacityBytes, lineStarts.count > 1 {
            let first = lineStarts[0]
            let second = lineStarts[1]
            buffer.removeSubrange(0..<second)
            let dropped = second - first
            lineStarts.removeFirst()
            lineStarts = lineStarts.map { $0 - dropped }
            lineStarts[0] = 0
        }
        // Pathological: a single line longer than capacity. Keep a tail of it.
        if buffer.count > capacityBytes {
            let keep = buffer.suffix(capacityBytes)
            buffer = keep
            lineStarts = [0]
        }
    }
}
