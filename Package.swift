// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DAX",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "DAX", targets: ["DAX"])],
    targets: [
        .executableTarget(name: "DAX", resources: [.copy("Resources")])
    ]
)
