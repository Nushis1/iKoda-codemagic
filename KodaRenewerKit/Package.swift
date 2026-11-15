// swift-tools-version: 6.2
import PackageDescription

// Swift side of KodaRenewer (the Rust core in ../KodaRenewer). The XCFramework below is built by
// KodaRenewer/build-rust.sh, which copies it here before Xcode runs; it is not in git. Only iPhone
// builds link it: Mac Catalyst has no slice, and the Swift code falls back with #if canImport.
let phone: BuildSettingCondition = .when(platforms: [.iOS])

let package = Package(
    name: "KodaRenewerKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "KodaRenewerKit", targets: ["KodaRenewerKit"]),
    ],
    targets: [
        .binaryTarget(name: "KodaRenewer", path: "KodaRenewer.xcframework"),
        .target(
            name: "KodaRenewerKit",
            dependencies: [.target(name: "KodaRenewer", condition: phone)],
            linkerSettings: [
                // What the Rust code (rustls, reqwest, the crypto) reaches for in the system.
                .linkedFramework("Security", phone),
                .linkedFramework("SystemConfiguration", phone),
                .linkedFramework("CoreFoundation", phone),
                .linkedLibrary("resolv", phone),
                .linkedLibrary("iconv", phone),
                .linkedLibrary("c++", phone),
            ]
        ),
    ]
)
