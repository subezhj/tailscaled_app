import XCTest
@testable import HeelerSSH

/// Pins the split-tunnel policy: which hosts ride the tailnet SOCKS5 proxy and
/// which dial directly. The proxy can only dial tailnet destinations, so
/// misclassifying a LAN/public host poisons every direct SSH connection.
final class TailnetTargetTests: XCTestCase {

    func testMagicDNSNamesAreTailnet() {
        XCTAssertTrue(TailnetTarget.isTailnet("nas.tailnet.ts.net"))
        XCTAssertTrue(TailnetTarget.isTailnet("host.ts.net"))
        XCTAssertTrue(TailnetTarget.isTailnet("my-machine.tail0719.ts.net"))
    }

    func testTailnetIPv4Range() {
        // 100.64.0.0/10: second octet 64…127
        XCTAssertTrue(TailnetTarget.isTailnet("100.64.0.1"))
        XCTAssertTrue(TailnetTarget.isTailnet("100.101.102.103"))
        XCTAssertTrue(TailnetTarget.isTailnet("100.127.255.254"))
        // Outside the range must NOT be treated as tailnet.
        XCTAssertFalse(TailnetTarget.isTailnet("100.63.0.1"))
        XCTAssertFalse(TailnetTarget.isTailnet("100.128.0.1"))
        XCTAssertFalse(TailnetTarget.isTailnet("192.168.1.10"))
        XCTAssertFalse(TailnetTarget.isTailnet("10.0.0.1"))
        XCTAssertFalse(TailnetTarget.isTailnet("8.8.8.8"))
    }

    func testTailnetIPv6Prefix() {
        XCTAssertTrue(TailnetTarget.isTailnet("fd7a:115c:a1e0::1"))
        XCTAssertFalse(TailnetTarget.isTailnet("2001:4860:4860::8888"))
    }

    func testLanAndPublicHostsAreDirect() {
        XCTAssertFalse(TailnetTarget.isTailnet("192.168.1.5"))
        XCTAssertFalse(TailnetTarget.isTailnet("desktop.local"))
        XCTAssertFalse(TailnetTarget.isTailnet("github.com"))
        XCTAssertFalse(TailnetTarget.isTailnet(""))
    }

    func testPlainHostnameWithoutTSNetIsDirect() {
        // Heeler allows entering a bare hostname; without the .ts.net suffix
        // (or a tailnet IP) it must dial directly.
        XCTAssertFalse(TailnetTarget.isTailnet("linuxbox"))
    }
}