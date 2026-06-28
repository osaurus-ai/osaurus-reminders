// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "osaurus-reminders",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "osaurus-reminders", type: .dynamic, targets: ["osaurus_reminders"])
    ],
    targets: [
        .target(
            name: "osaurus_reminders",
            path: "Sources/osaurus_reminders"
        ),
        .testTarget(
            name: "osaurus_remindersTests",
            dependencies: ["osaurus_reminders"],
            path: "Tests/osaurus_remindersTests"
        )
    ]
)