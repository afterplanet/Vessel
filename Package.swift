// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vessel",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")],
    targets: [
        .target(name: "CSGP4", path: "Sources/CSGP4",
                publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-O2", "-w"])]),
        // fsphil's SSDV library: pictures sent as data packets.
        .target(name: "CSSDV", path: "Sources/CSSDV",
                exclude: ["LICENSE.ssdv"],
                publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-O2", "-w"])]),
        .target(name: "CFT8", path: "Sources/CFT8",
                exclude: ["LICENSE"],
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("."), .define("HAVE_STPCPY"), .unsafeFlags(["-O2", "-w"])]),
        // Google's Draco mesh decoder, trimmed to decoding. NASA's models are compressed with it.
        .target(name: "CDraco", path: "Sources/CDraco",
                exclude: ["LICENSE.draco"],
                publicHeadersPath: "include",
                cxxSettings: [.headerSearchPath("."), .unsafeFlags(["-O2", "-w"])]),
        .executableTarget(
            name: "Vessel",
            dependencies: ["CSGP4", "CFT8", "CDraco", .product(name: "Yams", package: "Yams"), "CSSDV"],
            path: "Sources/Vessel",
            exclude: [],
            resources: [.copy("Resources")],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .testTarget(name: "VesselTests", dependencies: ["Vessel"], path: "Tests/VesselTests"),
    ],
    cxxLanguageStandard: .cxx17
)
