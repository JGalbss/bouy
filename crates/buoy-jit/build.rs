//! The VM provides the `enif_*` symbols when it loads the library, so the linker must leave
//! them undefined on macOS. Linux allows undefined symbols in a shared library already.
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-cdylib-link-arg=-undefined");
        println!("cargo:rustc-cdylib-link-arg=dynamic_lookup");
    }
}
