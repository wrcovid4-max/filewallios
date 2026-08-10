// swift-tools-version:5.7
// FileWallKit — crypto, storage, models and sync for FileWall.
//
// Deliberately platform-multi: the crypto suite must build and test on macOS so
// the round-trip / tamper / boundary tests run on a laptop without booting a
// simulator. iOS 16 / watchOS 9 are the shipping deployment targets; macOS 13
// exists only to host the test runner (it has the same CryptoKit surface).
import PackageDescription

let package = Package(
    name: "FileWallKit",
    platforms: [
        .iOS(.v16),
        .watchOS(.v9),
        // macOS 13 == Ventura: first release whose CryptoKit matches the iOS 16
        // surface we depend on (HKDF, AES.GCM, SecureEnclave.P256). Test-only.
        .macOS(.v13)
    ],
    products: [
        .library(name: "FileWallKit", targets: ["FileWallKit"])
    ],
    dependencies: [
        // No third-party dependencies. Constraint, not an accident: a file vault
        // should have an auditable, minimal dependency surface.
    ],
    targets: [
        .target(
            name: "FileWallKit",
            dependencies: []
        ),
        .testTarget(
            name: "FileWallKitTests",
            dependencies: ["FileWallKit"]
        )
    ]
)
