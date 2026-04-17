// swift-tools-version: 5.7
import PackageDescription

// OpenCV static libraries (fully self-contained, no Homebrew needed at runtime)
let opencvStaticLibs: [LinkerSetting] = [
    .unsafeFlags(["-L", "lib", "-L", "lib_static"]),
    .linkedLibrary("gylogsync_bridge"),
    // OpenCV static libs (order matters for dependency resolution)
    .unsafeFlags([
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libopencv_optflow.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libopencv_ximgproc.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libopencv_video.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libopencv_calib3d.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libopencv_features2d.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libopencv_flann.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libopencv_imgproc.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libopencv_core.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libade.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libkleidicv.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libkleidicv_hal.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libkleidicv_thread.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libittnotify.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libtbb.a",
        "-Xlinker", "-force_load", "-Xlinker", "lib_static/libtegra_hal.a",
    ]),
    .linkedLibrary("c++"),
    .linkedLibrary("z"),  // zlib (macOS built-in)
    // macOS frameworks needed by gyroflow-core + OpenCV
    .linkedFramework("OpenCL"),
    .linkedFramework("Metal"),
    .linkedFramework("CoreVideo"),
    .linkedFramework("IOKit"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("Accelerate"),
    .linkedFramework("CoreGraphics"),
]

let package = Package(
    name: "GyLogSync",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "GyLogSync", targets: ["GyLogSync"]),
        .executable(name: "GyLogSyncTest", targets: ["GyLogSyncTest"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "GyLogSync",
            dependencies: ["CGyroflowBridge"],
            path: "Sources/GyLogSync",
            linkerSettings: opencvStaticLibs
        ),
        .executableTarget(
            name: "GyLogSyncTest",
            dependencies: [],
            path: "Sources/GyLogSyncTest"
        ),
        .executableTarget(
            name: "GyroflowSyncHelper",
            dependencies: ["CGyroflowBridge"],
            path: "Sources/GyroflowSyncHelper",
            linkerSettings: opencvStaticLibs
        ),
        .systemLibrary(
            name: "CGyroflowBridge",
            path: "Sources/CGyroflowBridge"
        )
    ]
)
