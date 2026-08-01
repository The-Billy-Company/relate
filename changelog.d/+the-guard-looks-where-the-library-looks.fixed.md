The Rust integration suite failed all five of its tests in a clean checkout,
and the engine it could not find was sitting in this repository's own
`zig-out/bin`.

The precondition that replaced the old silent early-return was right to fail
loud, but it looked for the binary itself - a bare `Command::new("relate")`,
which is a `PATH` lookup and nothing else. Everything it then went on to test
resolves through `irregex::runtime::shell`, which walks the checkout first. So
the guard and the code under test were asking different questions, and on a
machine with no globally installed `relate` the guard answered no while the
library would have answered yes. A test whose whole point is to drive the real
engine was refusing to drive an engine that was right there.

It routes through `binary_named` now - the same ladder the library uses, which
also means the guard's `--schema` probe runs the exact binary the tests will
drive rather than a second one that happened to be installed. Five tests, five
passes, no `relate` on `PATH`.

The Go suite got the same treatment from the other direction: seven of its eight
tests opened with a `requireEngine` helper that skipped when discovery came back
empty. That is the shape that lets a package report `ok` having exercised
nothing. A `TestMain` resolves the engine once and fails the package if it
cannot, so the seven assert rather than guard, and the helper is gone.
