// swift-tools-version: 6.0

import PackageDescription

// Wraps the TailscaleKit.xcframework produced by the libtailscale submodule
// (ThirdParty/libtailscale) so the app can depend on it via SPM, mirroring how
// HeelerSSH wraps its checked-in libssh2/OpenSSL XCFrameworks.
//
// The XCFramework is NOT checked into git — it is built by `make framework`
// (or the CI ipa workflow) from the submodule's `swift/` tree via
// `make ios-fat`, which compiles the Go engine (`go build -buildmode=c-archive`)
// and wraps it with the Swift `TailscaleKit` bindings. The build output is
// copied here to `Artifacts/TailscaleKit.xcframework` before the app build.
let package = Package(
    name: "TailscaleKit",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "TailscaleKit", targets: ["TailscaleKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "TailscaleKit",
            path: "Artifacts/TailscaleKit.xcframework"
        ),
    ]
)
