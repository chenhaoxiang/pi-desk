// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PiDesk", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "PiDesk", targets: ["PiDeskApp"]),
    .executable(name: "PiDeskPeerCheck", targets: ["PiDeskPeerCheck"]),
  ],
  targets: [
    .target(name: "PiDeskCore"),
    .target(name: "PiDeskTransport", dependencies: ["PiDeskCore"]),
    .executableTarget(name: "PiDeskApp", dependencies: ["PiDeskCore", "PiDeskTransport"]),
    .executableTarget(name: "PiDeskPeerCheck"),
    .executableTarget(
      name: "PiDeskCoreTests", dependencies: ["PiDeskCore"], path: "Tests/PiDeskCoreTests"),
    .executableTarget(
      name: "PiDeskTransportTests", dependencies: ["PiDeskTransport"],
      path: "Tests/PiDeskTransportTests"),
  ], swiftLanguageModes: [.v5]
)
