fn main() {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap();

    // Compile the ObjC shim.
    let mut build = cc::Build::new();
    build
        .file("src/shim.m")
        .flag("-xobjective-c")
        .flag("-fobjc-arc")
        .include("src")
        .include("vendor/ghostty/include")
        .compile("shade_shim");

    // Link libghostty (rebuilt static archive; see tools/fix-lib.sh).
    println!("cargo:rustc-link-search=native={}/build", manifest);
    println!("cargo:rustc-link-lib=static=ghostty-fixed");

    for framework in [
        "AppKit",
        "Carbon",
        "Metal",
        "MetalKit",
        "CoreText",
        "CoreVideo",
        "QuartzCore",
        "CoreServices",
        "CoreFoundation",
        "Foundation",
        "IOKit",
        "Security",
    ] {
        println!("cargo:rustc-link-framework={}", framework);
    }
    println!("cargo:rustc-link-lib=dylib=objc");
    println!("cargo:rustc-link-lib=dylib=c++");
    println!("cargo:rustc-link-lib=dylib=z");
    println!("cargo:rustc-link-lib=dylib=dispatch");

    println!("cargo:rerun-if-changed=src/shim.m");
    println!("cargo:rerun-if-changed=src/shade.h");
    println!("cargo:rerun-if-changed=src/main.rs");
    println!("cargo:rerun-if-changed=src/ffi.rs");
}
