The substrate this library links is now `libirgx`, and the status codes its
header quotes are `IRGX_*`. Nothing about relate's own surface moved: the
artifact is still `librelate`, the header is still `include/relate.h`, and
`relate_run` and the `RELATE_OP_*` codes are untouched. What changed is the
spelling of the engine underneath - a C caller now writes `-lrelate -lirgx`
against `<irgx.h>` and reads `IRGX_OK` / `IRGX_STALE` / `IRGX_INVALID` back,
instead of including one name and linking another. The cgo tier's `LDFLAGS`,
the build graph's `artifact("irgx")` lookup, and the packaging test that stages
both libraries into one directory all follow the file to its new name; the Zig
package is still `@import("irregex")` and the engine's repo, crate, and module
path are all still `irregex`, because those name the project rather than the
thing you type. This lands before v1.0.0 on purpose - v1 freezes the linker
name the same way it freezes the symbol prefix, so this was the last free
window.
