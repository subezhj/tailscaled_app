import SwiftUI
import AuthenticationServices
import UIKit

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
    private let presentationContext = AuthPresentationContext()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
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

            Section("Status") {
                LabeledContent("State", value: stateText)
                if let ip = ipv4Text {
                    LabeledContent("Tailnet IP", value: ip)
                }
                if let name = controller.tailnetName, !name.isEmpty {
                    LabeledContent("Node", value: name)
                }
                if controller.pendingLoginURL != nil {
                    Button("Log In to Tailscale") {
                        presentLogin()
                    }
                }
            }

            if case .failed(let message) = controller.state {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } header: {
                    Text("Error")
                }
            }

            Section {
                Button(role: .destructive) {
                    controller.stop()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .disabled(!controller.isActive)
            }
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
        }
        .onChange(of: controller.pendingLoginURL) {
            if controller.pendingLoginURL != nil {
                presentLogin()
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
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
