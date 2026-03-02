// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "SwiftyGif",
    platforms: [
        .iOS(.v13), .macOS(.v10_15),
    ],
    products: [
        .library(name: "SwiftyGif", targets: ["SwiftyGif"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftyGif",
            dependencies: [],
            path: "SwiftyGif",
            resources: [
                .copy("PrivacyInfo.xcprivacy")
            ]),
    ]
)
