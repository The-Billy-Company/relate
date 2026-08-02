// Standalone Go module — intentionally NOT in any parent workspace.
//
// Default build is pure Go and answers through the installed `relate` binary.
// The in-process tier is opt-in (`-tags irgx_ffi`) and links `librelate`
// plus `libirgx` from this checkout's zig-out/.
//
// Contract + runtime come from the irregex module; this module is kinship,
// retrieval, and sweep only.
module github.com/The-Billy-Company/relate/bindings/go

go 1.24

toolchain go1.26.5

require github.com/The-Billy-Company/irregex/bindings/go v0.0.0

replace github.com/The-Billy-Company/irregex/bindings/go => ../../../irregex/bindings/go
