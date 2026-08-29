import Foundation
import AVFoundation
import UIKit
import Observation

/// Background audio keepalive.
///
/// iOS aggressively suspends apps shortly after they leave the foreground,
/// which freezes SSH sockets and makes the next foreground return pay a full
/// reconnect ("the terminal shudders"). Playing inaudible audio with the
/// `audio` background mode keeps the process alive in the background, so the
/// Host connections stay warm and return to the app is instant.
///
/// The audio is a silent PCM tone looped forever at near-zero volume; the
/// route is silenced to output nothing, so it cannot be heard. This is the
/// same technique proxy/VPN apps use. It is opt-in (off by default) because
/// it has a real battery cost and can keep the app running when the user
/// might expect it to be idle.
///
/// Apple's rules: `UIBackgroundModes: [audio]` must be declared in Info.plist
/// (added in project.yml), and the session must actually be playing audio for
/// the background mode to apply — a stopped player is immediately suspended.
@MainActor
@Observable
final class AudioSessionKeeper {
    private(set) var isActive = false

    /// Persisted preference (default off).
    private static let defaultsKey = "keepAliveAudioEnabled"
    private let defaults: UserDefaults

    private var player: AVAudioPlayer?
    private var silenceFileURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the keepalive should be on (persisted), independent of whether
    /// it is currently playing.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.defaultsKey) }
        set {
            defaults.set(newValue, forKey: Self.defaultsKey)
            if newValue {
                start()
            } else {
                stop()
            }
        }
    }

    /// Starts (or restarts) the silent loop. No-op when already playing.
    func start() {
        guard !isActive else { return }
        do {
            try configureAudioSession()
            let url = try silentAudioURL()
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1 // loop forever
            player.volume = 0.01      // effectively inaudible
            player.isMeteringEnabled = false
            player.prepareToPlay()
            guard player.play() else {
                self.player = nil
                return
            }
            self.player = player
            isActive = true
        } catch {
            isActive = false
        }
    }

    /// Stops the silent loop and returns the audio session to inactive.
    func stop() {
        player?.stop()
        player = nil
        isActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Notify on foreground return in case the system dropped the audio
    /// session while we were away; restarting is cheap and idempotent.
    func didBecomeActive() {
        guard isEnabled, !isActive else { return }
        start()
    }

    // MARK: - Audio session

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .playback keeps the process alive in the background even when the
        // screen is off, and a silent player is inaudible. mixWithOthers lets
        // the user's music keep playing at full volume — we add a silent
        // stream to the mix, we do not take the audio route over. No
        // duckOthers: ducking would lower the user's music, and the whole
        // point of this keepalive is that it is inaudible and unobtrusive.
        try session.setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers])
        try session.setActive(true)
    }

    // MARK: - Silent audio

    /// A tiny (1s) 44.1 kHz mono 16-bit silent WAV, generated once and cached
    /// in Caches. AVAudioPlayer needs a file URL.
    private func silentAudioURL() throws -> URL {
        if let silenceFileURL { return silenceFileURL }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent("heeler-silence.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            let data = makeSilentWAV(durationSeconds: 1.0)
            try data.write(to: url)
        }
        silenceFileURL = url
        return url
    }

    /// Builds a valid WAV file of pure silence.
    private func makeSilentWAV(durationSeconds: Double) -> Data {
        let sampleRate: UInt32 = 44100
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(Double(sampleRate) * durationSeconds) * UInt32(channels) * UInt32(bitsPerSample) / 8

        var data = Data()
        func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
        func appendU32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { append(Array($0)) } }
        func appendU16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { append(Array($0)) } }

        // RIFF header
        append(Array("RIFF".utf8))
        appendU32(36 + dataSize)
        append(Array("WAVE".utf8))
        // fmt chunk
        append(Array("fmt ".utf8))
        appendU32(16)
        appendU16(1)                       // PCM
        appendU16(channels)
        appendU32(sampleRate)
        appendU32(byteRate)
        appendU16(blockAlign)
        appendU16(bitsPerSample)
        // data chunk
        append(Array("data".utf8))
        appendU32(dataSize)
        append([UInt8](repeating: 0, count: Int(dataSize)))

        return data
    }
}
