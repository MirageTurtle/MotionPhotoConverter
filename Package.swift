// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "MotionPhotoConverter",
    defaultLocalization: "Base",
    platforms: [.macOS(.v10_15)],
    targets: [
        .target(
            name: "LivePhoto",
            path: "LivePhoto",
            exclude: ["Sample Code", "README.md"]
        ),
        .executableTarget(
            name: "MotionPhotoConverter",
            dependencies: ["LivePhoto"],
            path: "Sources/MotionPhotoConverter"
        )
    ]
)
