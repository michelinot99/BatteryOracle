// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BatteryOracle",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "BatteryOracle", path: "Sources/BatteryOracle")]
)
