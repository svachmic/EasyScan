// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EasyScan",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EasyScan",
            path: "Sources/EasyScan",
            linkerSettings: [
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("PDFKit"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
