//! Generates foreign-language bindings from the compiled `leaf-ffi`
//! library. Invoked by the `Makefile`; not shipped.

fn main() {
    uniffi::uniffi_bindgen_main()
}
