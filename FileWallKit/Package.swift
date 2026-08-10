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
        // macOS 12 (Monterey) is the test host floor — it is the lowest macOS
        // that Xcode 14.2 runs on (12.5+), and it already has everything the
        // crypto/storage suites need: async `NSManagedObjectContext.perform`,
        // async/await, HKDF, AES.GCM and SecureEnclave.P256. `swift test` cannot
        // RUN a target whose deployment target is newer than the host OS, so this
        // must not be raised above the oldest Mac we expect to build on.
        .macOS(.v12)
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
