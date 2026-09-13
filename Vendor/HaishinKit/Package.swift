// swift-tools-version:6.0
import PackageDescription

// Only the two products Nanight uses, from upstream 2.2.5. See PATCHES.md.
let package = Package(
    name: "HaishinKit",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "HaishinKit", targets: ["HaishinKit"]),
        .library(name: "RTMPHaishinKit", targets: ["RTMPHaishinKit"])
    ],
    dependencies: [.package(url: "https://github.com/shogo4405/Logboard.git", exact: "2.6.0")],
    targets: [
        .target(name: "HaishinKit", dependencies: ["Logboard"], path: "HaishinKit/Sources", swiftSettings: [.enableUpcomingFeature("ExistentialAny")]),
        .target(name: "RTMPHaishinKit", dependencies: ["HaishinKit"], path: "RTMPHaishinKit/Sources", swiftSettings: [.enableUpcomingFeature("ExistentialAny")])
    ],
    swiftLanguageModes: [.v6, .v5]
)
