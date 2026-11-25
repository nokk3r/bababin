// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bababin",
    defaultLocalization: "ru",
    platforms: [
        .macOS("15.0")
    ],
    targets: [
        .executableTarget(
            name: "Bababin",
            path: "Sources/Bababin",
            exclude: [
                "Localization/Localizable.xcstrings",
            ],
            resources: [
                .copy("Bundled/LICENSE.txt"),
                .copy("Bundled/CHANGELOG.md"),
                .copy("Bundled/CHANGELOG.en.md"),
                .process("Localization/en.lproj"),
                .process("Localization/ru.lproj"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "BababinTests",
            dependencies: ["Bababin"]
        )
    ]
)
