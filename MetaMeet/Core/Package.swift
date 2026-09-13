// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MeetingCore", platforms: [.iOS(.v17), .macOS(.v13)], products: [.library(name: "MeetingCore", targets: ["MeetingCore"])], targets: [.target(name: "MeetingCore"), .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"])])
