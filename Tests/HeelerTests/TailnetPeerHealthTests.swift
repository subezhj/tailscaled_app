import XCTest
@testable import Heeler

final class TailnetPeerHealthTests: XCTestCase {
    /// Builds a raw Tailscale status JSON and decodes it through the same
    /// path the controller uses, then runs `peerHealth(from:)`.
    private func health(fromJSON json: String) throws -> [String: TailnetPeerHealth] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        let status = try JSONDecoder().decode(TailscaleKit.Ipn.Status.self, from: data)
        return TailnetNodeController.peerHealth(from: status)
    }

    private let directPeerJSON = """
    {
      "Peer": {
        "nodeA": {
          "ID": "nodeA",
          "HostName": "macbook",
          "DNSName": "macbook.tailnet123.ts.net.",
          "TailscaleIPs": ["100.64.0.1"],
          "Online": true,
          "Relay": null,
          "LastHandshake": "2026-09-10T12:00:00.000Z"
        },
        "nodeB": {
          "ID": "nodeB",
          "HostName": "server",
          "DNSName": "server.tailnet123.ts.net.",
          "TailscaleIPs": ["100.64.0.2"],
          "Online": true,
          "Relay": "derp-7",
          "LastHandshake": "2026-09-10T12:00:00.000Z"
        },
        "nodeC": {
          "ID": "nodeC",
          "HostName": "deadbox",
          "DNSName": "deadbox.tailnet123.ts.net.",
          "TailscaleIPs": ["100.64.0.3"],
          "Online": false,
          "Relay": null,
          "LastHandshake": "0001-01-01T00:00:00Z"
        }
      }
    }
    """

    func testDirectPeerIsNotRelayed() throws {
        let health = try health(fromJSON: directPeerJSON)
        let peer = try XCTUnwrap(health["100.64.0.1"])
        XCTAssertFalse(peer.isRelayed)
        XCTAssertTrue(peer.isHealthy)
    }

    func testRelayedPeerIsRelayedAndHealthy() throws {
        let health = try health(fromJSON: directPeerJSON)
        let peer = try XCTUnwrap(health["100.64.0.2"])
        XCTAssertTrue(peer.isRelayed)
        XCTAssertEqual(peer.relay, "derp-7")
        XCTAssertTrue(peer.isHealthy)
    }

    func testOfflinePeerIsUnhealthy() throws {
        let health = try health(fromJSON: directPeerJSON)
        let peer = try XCTUnwrap(health["100.64.0.3"])
        XCTAssertNil(peer.relay) // offline, no path
        XCTAssertFalse(peer.isHealthy)
        XCTAssertFalse(peer.isRelayed)
    }

    func testMagicDNSShortNameAndFullNameResolveToSamePeer() throws {
        let health = try health(fromJSON: directPeerJSON)
        // Short name (no trailing dot, lowercase) and the IP find the same peer.
        let byShortName = try XCTUnwrap(health["macbook"])
        let byIP = try XCTUnwrap(health["100.64.0.1"])
        XCTAssertEqual(byShortName, byIP)
        // Host configured as *.ts.net with trailing dot also resolves.
        let byFQDN = try XCTUnwrap(health["macbook.tailnet123.ts.net."])
        XCTAssertEqual(byFQDN, byIP)
    }

    func testStaleHandshakeIsUnhealthyEvenWhenOnline() throws {
        let stalePeerJSON = """
        {
          "Peer": {
            "nodeA": {
              "ID": "nodeA",
              "HostName": "macbook",
              "DNSName": "macbook.tailnet123.ts.net.",
              "TailscaleIPs": ["100.64.0.1"],
              "Online": true,
              "Relay": null,
              "LastHandshake": "2026-01-01T00:00:00.000Z"
            }
          }
        }
        """
        let health = try health(fromJSON: stalePeerJSON)
        let peer = try XCTUnwrap(health["100.64.0.1"])
        XCTAssertTrue(peer.online)
        XCTAssertFalse(peer.isHealthy, "stale handshake must read unhealthy")
    }

    func testEmptyStatusYieldsEmptyHealth() throws {
        let health = try health(fromJSON: "{}")
        XCTAssertTrue(health.isEmpty)
    }

    func testGoZeroHandshakeBecomesNil() throws {
        let zeroHandshakeJSON = """
        {
          "Peer": {
            "nodeA": {
              "ID": "nodeA",
              "HostName": "macbook",
              "DNSName": "macbook.tailnet123.ts.net.",
              "TailscaleIPs": ["100.64.0.1"],
              "Online": true,
              "Relay": null,
              "LastHandshake": "0001-01-01T00:00:00Z"
            }
          }
        }
        """
        let health = try health(fromJSON: zeroHandshakeJSON)
        let peer = try XCTUnwrap(health["100.64.0.1"])
        XCTAssertNil(peer.lastHandshake)
        XCTAssertFalse(peer.isHealthy)
    }
}
