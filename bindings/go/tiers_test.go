package relate

import (
	"testing"

	"github.com/The-Billy-Company/irregex/bindings/go/analytic"
	"github.com/The-Billy-Company/irregex/bindings/go/runtime"
)

// TestTiersAgree is the cross-tier oracle: whichever tiers this machine has must
// answer a verb with the same rows. A declinature is a fact about speed, so a
// difference here would mean one tier is lying.
//
// The ladder under test is irregex's, not relate's, and this test used to live
// beside it. It moved because of who it needs on disk rather than what it
// proves: judging a kinship verb across tiers requires the real `relate`
// binary, and irregex is a public package while relate is not. A public
// package whose suite cannot run without a clone of a private one is a suite
// the public cannot run, so the test follows its subject's *binary* rather than
// its code. What stayed behind is the same ladder exercised through gist's
// `rank`, which is public and proves the cold tier spawns, frames, and decodes.
// What only relate can supply is this: two tiers, one kinship answer, no
// divergence.
func TestTiersAgree(t *testing.T) {
	c := planted(t)
	q := runtime.Query{
		Op:     analytic.OpDups,
		Params: analytic.Kinship{MaxDistance: ptr(0.6), Top: 10, NoIndex: true},
		Roots:  c.roots,
		Dir:    c.dir,
	}

	// The one skip here, and deliberately not the kind TestMain abolished. That
	// kind asked the filesystem whether a binary happened to be lying around;
	// this one asks how this very test binary was compiled. The default build is
	// pure Go, because the in-process analytic tier is opt-in behind
	// `-tags irgx_ffi` so a `go get` consumer never tries to link a libirgx that
	// cannot exist in the module cache. A cross-tier oracle with one tier
	// present has nothing to compare, and no amount of building or installing
	// changes that — only rebuilding this test binary with the tag does.
	warm := runtime.Probe()
	if !warm.Analytic {
		t.Skipf("this test binary has no in-process analytic tier to compare the cold one against; rebuild with `-tags irgx_ffi` (cgo=%v, err=%v)", warm.CGO, warm.Err)
	}
	native := render(t, q)
	if len(native) == 0 {
		t.Fatal("the fixture corpus produced no duplicate pair, so this oracle proves nothing")
	}
	t.Setenv("IRGX_NO_FFI", "1")
	cold := render(t, q)
	if len(native) != len(cold) {
		t.Fatalf("tiers disagree on row count: native %d, cold %d\nnative=%v\ncold=%v", len(native), len(cold), native, cold)
	}
	for i := range native {
		if native[i] != cold[i] {
			t.Errorf("row %d: native %s, cold %s", i, native[i], cold[i])
		}
	}
}

// render runs a query through the ladder and renders its rows, so two tiers can
// be compared as text rather than as decoded structs — a difference in any field
// shows up, including ones this test does not know to name.
func render(t *testing.T, q runtime.Query) []string {
	t.Helper()
	rows, err := runtime.Run(t.Context(), q)
	if err != nil {
		t.Fatalf("run %s: %v", q.Op, err)
	}
	defer rows.Close()
	found, err := rows.Collect()
	if err != nil {
		t.Fatalf("collect %s: %v", q.Op, err)
	}
	out := make([]string, 0, len(found))
	for _, row := range found {
		out = append(out, row.String())
	}
	return out
}
