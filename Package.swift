// swift-tools-version:6.0
// Build the app with ./build.sh (wraps `swift build` into DesktopCat.app).
// Run the tests with `swift test`.
import PackageDescription

let package = Package(
    name: "DesktopCat",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-updating from GitHub releases (https://sparkle-project.org).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(name: "DesktopCat", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources/DesktopCat",
                          // Run straight from .build too (Sparkle.framework sits next to the binary there).
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]),
        .testTarget(name: "DesktopCatTests", dependencies: ["DesktopCat"], path: "Tests/DesktopCatTests"),
    ],
    swiftLanguageModes: [.v5]
)
