fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        build_macos();
    }
    tauri_build::build()
}

/// Compiles the Objective-C half of the macOS backend and links the frameworks it uses.
fn build_macos() {
    let sources = ["../macos/host/decode.m", "../macos/host/camera.m"];
    for path in sources.iter().chain(&["../macos/host/plugcam_mac.h"]) {
        println!("cargo:rerun-if-changed={path}");
    }
    cc::Build::new()
        .files(sources)
        .flag("-fobjc-arc")
        .flag("-fmodules")
        .flag("-mmacosx-version-min=13.0")
        .warnings(true)
        .flag("-Wno-unused-parameter")
        .compile("plugcam_mac");
    for framework in [
        "Foundation",
        "CoreFoundation",
        "CoreMedia",
        "CoreMediaIO",
        "CoreVideo",
        "VideoToolbox",
        "IOSurface",
        "Accelerate",
        "SystemExtensions",
        "AppKit",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
