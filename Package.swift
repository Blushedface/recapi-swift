// swift-tools-version:6.0
// The recapi client for Swift: Foundation only (URLSession, JSONEncoder), so
// it adds no dependency to an app. Builds on Linux and Apple platforms.
import Foundation
import PackageDescription

// The served zip and the registry copy ship the library without its tests
// (they read the repository's spec/): a test target without sources fails.
let hasTests = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests/RecapiTests")

let package = Package(
    name: "Recapi",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8)],
    products: [.library(name: "Recapi", targets: ["Recapi"])],
    targets: [.target(name: "Recapi")]
        + (hasTests ? [.testTarget(name: "RecapiTests", dependencies: ["Recapi"])] : [])
)
