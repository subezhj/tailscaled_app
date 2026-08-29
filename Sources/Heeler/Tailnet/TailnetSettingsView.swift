import SwiftUI
import AuthenticationServices
import UIKit
import HeelerSSH

/// Provides the presentation anchor for `ASWebAuthenticationSession` on iOS.
/// `ASWebAuthenticationPresentationContextProviding` is a class-bound
/// (`NSObjectProtocol`) protocol, so a SwiftUI `struct` view cannot conform
/// to it directly — this small `NSObject` bridges that.
final class AuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let key = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            return key
        }
        return ASPresentationAnchor()
    }
}

/// Tailnet setting surface: start/stop the embedded userspace Tailscale node,
/// show connection state, and explain why there is no system VPN involved.
///
/// The node is deliberately **not** a `NEPacketTunnelProvider`: it runs in
/// userspace and exposes a loopback SOCKS5 proxy, so it coexists with whatever
/// system VPN the user already runs (e.g. a proxy app like LOON). Only tailnet
/// traffic rides the node; everything else stays put.
struct TailnetSettingsView: View {
    @ObservedObject var controller: TailnetNodeController
    @State private var authSession: ASWebAuthenticationSession?
    @State private var showAuthKeyPrompt = false
    @State private var authKeyInput = ""
    @State private var dialReport: SocketConnector.DialReport?
    @State private var forceDirect = false
    private let presentationContext = AuthPresentationContext()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            tailnetSection
            loginSection
            statusSection
            routingSection
            if case .failed(let message) = controller.state {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } header: {
                    Text("Error")
                }
            }
            disconnectSection
        }
        .navigationTitle("Tailnet")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Start the node lazily: creating the node (and therefore the
            // app's join of the tailnet) only happens when the user enters
            // this screen or SSH needs it.
            controller.start()
            // If a login URL is already pending (fresh node, no auth), pop
            // the browser session automatically.
            if controller.pendingLoginURL != nil {
                presentLogin()
            }
            refreshDialReport()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshDialReport()
        }
        .onChange(of: controller.pendingLoginURL) {
            if controller.pendingLoginURL != nil {
                presentLogin()
            }
        }
        .alert("Use Auth Key", isPresented: $showAuthKeyPrompt) {
            TextField("tskey-…", text: $authKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Connect", action: submitAuthKey)
            Button("Cancel", role: .cancel) { authKeyInput = "" }
        } message: {
            Text(
                "Paste a tailscale auth key (tskey-…) from the admin console. "
                    + "The node reconnects with this key.")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var tailnetSection: some View {
        Section {
            Toggle("Tailnet Access", isOn: tailnetBinding)
        } header: {
            Text("Embedded Tailscale")
        } footer: {
            Text(
                "Runs a userspace Tailscale node — no system VPN is created, "
                    + "so it coexists with your existing VPN/proxy app. SSH "
                    + "connections to tailnet hosts ride this node.")
        }
    }

    private var loginSection: some View {
        Section {
            Button {
                requestLogin()
            } label: {
                Label("Log In with Browser", systemImage: "globe")
            }

            Button {
                showAuthKeyPrompt = true
            } label: {
                Label("Use Auth Key…", systemImage: "key")
            }
        } footer: {
            Text(
                "Browser login opens Tailscale in a web sheet and you sign in "
                    + "there. An auth key (tskey-…) from your tailnet admin "
                    + "console skips the browser.")
        }
    }

    private var statusSection: some View {
        Section("Status") {
            if controller.isVerified {
                Label {
                    Text("Verified")
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            } else {
                Label {
                    Text("Not verified")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            LabeledContent("State", value: stateText)
            if let ip = ipv4Text {
                LabeledContent("Tailnet IP", value: ip)
            }
            if let name = controller.tailnetName, !name.isEmpty {
                LabeledContent("Node", value: name)
            }
            LabeledContent(
                "SSH Route",
                value: controller.isSocksProxyActive ? "Tailnet via proxy" : "Direct")
        }
    }

    /// Diagnostics: whether recent SSH connections rode the tailnet proxy and
    /// whether they succeeded. Helps answer "did my SSH go through Tailscale?"
    private var routingSection: some View {
        Section {
            Toggle("Force Direct (bypass Tailscale)", isOn: forceDirectBinding)
            if let report = dialReport {
                LabeledContent("Last: Host", value: report.host)
                LabeledContent(
                    "Last: Path",
                    value: report.viaProxy ? "Tailscale proxy" : "Direct")
                LabeledContent(
                    "Last: Result",
                    value: report.failed ? "Failed" : "OK")
            } else {
                Text("No SSH connection yet.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("SSH Routing")
        } footer: {
            Text(
                "Tailnet destinations (100.x, *.ts.net) ride the embedded node's "
                    + "SOCKS5 proxy; everything else connects directly. Force Direct "
                    + "bypasses the proxy for diagnosis.")
        }
    }

    private var forceDirectBinding: Binding<Bool> {
        Binding(
            get: { forceDirect || SocketConnector.forceDirect },
            set: { enabled in
                forceDirect = enabled
                SocketConnector.forceDirect = enabled
            })
    }

    private var disconnectSection: some View {
        Section {
            Button(role: .destructive) {
                controller.stop()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .disabled(!controller.isActive)
        }
    }

    private func requestLogin() {
        // Ask the node to surface a BrowseToURL; the bus delivers it and
        // onAppear/onChange pop the browser sheet.
        controller.start()
        controller.requestLogin()
    }

    /// Pull the latest routing diagnostics from the SSH layer (set on every
    /// connection attempt by SocketConnector).
    private func refreshDialReport() {
        dialReport = SocketConnector.lastDialReport
        forceDirect = SocketConnector.forceDirect
    }

    private func submitAuthKey() {
        let key = authKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        authKeyInput = ""
        guard !key.isEmpty else { return }
        // The auth key must be set before the node starts, so restart the
        // node with the key.
        controller.stop()
        controller.start(authKey: key)
    }

    private func presentLogin() {
        guard let url = controller.pendingLoginURL, authSession == nil else { return }
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "ipnauth",
            completionHandler: { _, _ in
                // Tailscale completes login out-of-band through the control
                // plane; this callback is just the session closing.
                Task { @MainActor in
                    self.controller.loginSessionEnded()
                    self.authSession = nil
                }
            })
        session.presentationContextProvider = presentationContext
        session.prefersEphemeralWebBrowserSession = true
        authSession = session
        session.start()
    }

    private var tailnetBinding: Binding<Bool> {
        Binding(
            get: { controller.isActive },
            set: { enabled in
                if enabled {
                    controller.start()
                    controller.requestLogin()
                } else {
                    controller.stop()
                }
            })
    }

    private var stateText: String {
        switch controller.state {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .needsLogin: "Needs login"
        case .running: "Connected"
        case .failed: "Failed"
        }
    }

    private var ipv4Text: String? {
        if case .running(let ip) = controller.state { return ip }
        return nil
    }
}
