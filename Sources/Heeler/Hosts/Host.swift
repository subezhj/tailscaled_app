import Foundation

/// A user-added Host (CONTEXT.md): connection coordinates, how to
/// authenticate, and which herdr session to reach. Never carries a secret —
/// the password lives in the Keychain keyed by `id`, the device key in
/// `DeviceKeyStore`.
struct Host: Identifiable, Codable, Hashable, Sendable {
    /// How the app authenticates against this Host. OpenSSH key import is
    /// deliberately absent (out of scope per spec #20).
    enum AuthMethod: String, Codable, Sendable {
        case deviceKey
        case password
    }

    let id: UUID
    /// Optional display label; blank falls back to `user@address`.
    var name: String
    var address: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    /// Persisted session selection; onboarding discovers available sessions,
    /// while this field remains editable for older herdr versions. Blank
    /// means the default herdr session.
    var sessionName: String
    /// Optional Jump Host this Host is reached through. Blank means a direct
    /// connection; when set, `address`/`port` are resolved from the Jump Host
    /// and normally point at a loopback port held open by a reverse tunnel.
    var jumpAddress: String
    var jumpPort: Int
    /// Account on the Jump Host. Blank reuses `username`, which is the common
    /// case only when both machines share an account name.
    var jumpUsername: String
    /// When true the Host is hidden from the console and cannot be connected.
    /// The record (and its saved password) is kept so it can be re-enabled.
    var isDisabled: Bool
    /// Which agent-control backend this Host runs: herdr (the default, its
    /// JSON API over a remote Unix socket) or luvus (its UHP protocol over
    /// `luvus uhp proxy`). Absent on Hosts saved before this field: herdr.
    var backend: Backend

    /// The agent-control backend a Host speaks.
    enum Backend: String, Codable, Sendable, CaseIterable, Identifiable {
        case herdr
        case luvus

        var id: Self { self }

        /// Settings picker label.
        var title: String {
            switch self {
            case .herdr: "herdr"
            case .luvus: "luvus"
            }
        }

        /// One-line description for the Host form.
        var detail: String {
            switch self {
            case .herdr:
                "herdr's JSON API over SSH to its Unix socket"
            case .luvus:
                "luvus's UHP protocol over SSH (`luvus uhp proxy`)"
            }
        }
    }

    /// `socatPath` is deliberately absent: Hosts serialized before ADR 0011
    /// still carry it on disk, and leaving it out of the keys both ignores it
    /// on decode and drops it on the Host's next save.
    private enum CodingKeys: String, CodingKey {
        case id, name, address, port, username, authMethod, sessionName
        case jumpAddress, jumpPort, jumpUsername, isDisabled, backend
    }

    /// Whether this Host is reached through a Jump Host.
    var usesJumpHost: Bool {
        !jumpAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The Jump Host account, falling back to the Host's own username.
    var resolvedJumpUsername: String {
        let trimmed = jumpUsername.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? username : trimmed
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        address: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .deviceKey,
        sessionName: String = "",
        jumpAddress: String = "",
        jumpPort: Int = 22,
        jumpUsername: String = "",
        isDisabled: Bool = false,
        backend: Backend = .herdr
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.sessionName = sessionName
        self.jumpAddress = jumpAddress
        self.jumpPort = jumpPort
        self.jumpUsername = jumpUsername
        self.isDisabled = isDisabled
        self.backend = backend
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName) ?? ""
        // Absent in Hosts saved before jump-host support; a blank address
        // decodes as the direct connection those Hosts already had.
        jumpAddress = try container.decodeIfPresent(String.self, forKey: .jumpAddress) ?? ""
        jumpPort = try container.decodeIfPresent(Int.self, forKey: .jumpPort) ?? 22
        jumpUsername = try container.decodeIfPresent(String.self, forKey: .jumpUsername) ?? ""
        // Absent in Hosts saved before disable support: enabled by default.
        isDisabled = try container.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
        // Absent in Hosts saved before backend support: herdr.
        backend = try container.decodeIfPresent(Backend.self, forKey: .backend) ?? .herdr

        let trimmedSessionName = sessionName.trimmingCharacters(in: .whitespaces)
        guard trimmedSessionName.isEmpty || HerdrSessionName.isValid(trimmedSessionName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionName, in: container, debugDescription: "Invalid herdr session name")
        }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(username)@\(address)" : trimmed
    }

    /// The herdr socket this Host's session name points at.
    var socketLocation: HerdrSocketLocation {
        let trimmed = sessionName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? .defaultSession : .namedSession(trimmed)
    }
}
