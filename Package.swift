// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "osaurus-reminders",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "osaurus-reminders", type: .dynamic, targets: ["osaurus_reminders"])
    ],
    dependencies: [
        .package(url: "https://github.com/osaurus-ai/osaurus-plugin-sdk.git", exact: "1.0.0")
    ],
    targets: [
        .target(
            name: "osaurus_reminders",
            dependencies: [
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk")
            ],
            path: "Sources/osaurus_reminders"
        ),
        .testTarget(
            name: "osaurus_remindersTests",
            dependencies: [
                "osaurus_reminders",
                .product(name: "OsaurusPluginKit", package: "osaurus-plugin-sdk"),
            ],
            path: "Tests/osaurus_remindersTests"
        )
    ]
)