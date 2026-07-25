// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sashimi",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17)
    ],
    products: [
        .library(
            name: "SashimiShared",
            targets: ["SashimiShared"]
        ),
        .library(
            name: "Sashimi",
            targets: ["Sashimi"]
        ),
        .library(
            name: "SashimiMobile",
            targets: ["SashimiMobile"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/kean/Nuke.git", from: "12.0.0"),
    ],
    targets: [
        // Nuke is deliberately absent here: every import lives in
        // SashimiMobile/. project.yml already attaches it to that target only,
        // so declaring it on Shared and tvOS just pulled an unused dependency
        // into two more build graphs.
        .target(
            name: "SashimiShared",
            path: "Shared"
        ),
        .target(
            name: "Sashimi",
            dependencies: [
                "SashimiShared"
            ],
            path: "Sashimi"
        ),
        .target(
            name: "SashimiMobile",
            dependencies: [
                "SashimiShared",
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke"),
            ],
            path: "SashimiMobile"
        ),
    ]
)
