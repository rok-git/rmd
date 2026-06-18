// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "rmd",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "rmd", targets: ["rmd"])
    ],
    targets: [
        .executableTarget(name: "rmd")
    ]
)
