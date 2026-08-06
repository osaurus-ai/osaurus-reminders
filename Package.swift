// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "osaurus-reminders",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "osaurus-reminders", type: .dynamic, targets: ["osaurus_reminders"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git",
            revision: "21b4e133b365ff73c25d4a9db60d207c1888a6ab"
        )
    ],
    targets: [
        .target(
            name: "osaurus_reminders",
            dependencies: [
                .product(name: "OsaurusPluginABI", package: "osaurus-plugin-sdk"),
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
            ],
            path: "Sources/osaurus_reminders"
        ),
        .testTarget(
            name: "osaurus_remindersTests",
            dependencies: [
                "osaurus_reminders",
                .product(name: "OsaurusPluginABI", package: "osaurus-plugin-sdk"),
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
                .product(name: "OsaurusPluginTestSupport", package: "osaurus-plugin-sdk"),
            ],
            path: "Tests/osaurus_remindersTests"
        )
    ]
)