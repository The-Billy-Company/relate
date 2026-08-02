`librelate.a` resolves its substrate symbols through libirgx rather than
redefining them, so a static consumer links the pair - and the install prefix
only ever held one half of it. `libirgx.so` was installed, `libirgx.a` was not,
so anyone following the archive path had to go find the engine's archive in
another checkout and hope it was built for the same target.

It installs now, taken off the dependency graph as a named lazy path rather
than copied from a sibling `zig-out`, so it is the right target and the right
optimize mode by construction.

The ELF `librelate.a` also stops registering a second build artifact named
`relate`. The dylib already owns that name, and a duplicate makes a dependent's
`dep.artifact("relate")` ambiguous enough to panic the build runner - in the
DEPENDENT, never here, and only on the arm macOS does not take. Both arms
install the archive as a file now, the way the macOS arm already did for its
own alignment reasons.
