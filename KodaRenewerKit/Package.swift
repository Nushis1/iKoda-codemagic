// swift-tools-version: 6.2
import PackageDescription

// Swift side of KodaRenewer (the Rust core in ../KodaRenewer). The XCFramework below is built by
// KodaRenewer/build-rust.sh, which copies it here before Xcode runs; it is not in git. Only iPhone
// builds link it: Mac Catalyst has no slice, and the Swift code falls back with #if canImport.
// SwiftPM has a condition type for dependencies and another for linker settings.
let phoneDependency: TargetDependencyCondition? = .when(platforms: [.iOS])
let phoneSetting: BuildSettingCondition? = .when(platforms: [.iOS])

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
            dependencies: [.target(name: "KodaRenewer", condition: phoneDependency)],
            linkerSettings: [
                // What the Rust code (rustls, reqwest, the crypto) reaches for in the system.
                .linkedFramework("Security", phoneSetting),
                .linkedFramework("SystemConfiguration", phoneSetting),
                .linkedFramework("CoreFoundation", phoneSetting),
                .linkedLibrary("resolv", phoneSetting),
                .linkedLibrary("iconv", phoneSetting),
                .linkedLibrary("c++", phoneSetting),
            ]
        ),
    ]
)
