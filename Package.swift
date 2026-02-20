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
        .target(
            name: "SashimiShared",
            dependencies: [
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke"),
            ],
            path: "Shared"
        ),
        .target(
            name: "Sashimi",
            dependencies: [
                "SashimiShared",
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke"),
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
