Docs, doc comments, and test fixtures stopped citing the private monorepo this
was split out of. A reader who lands here cannot resolve `WalletService`,
`services/backend/api/main.go`, `libs/kernels/…`, or an internal decision-record
number, so every one of those was an example that only worked if you already had
the tree it came from.

The type name in the `--matching` examples is `SessionStore` now, which
exercises exactly the same signals; elided paths read `lib/…/scan.py`; the
markup-weaving test asks its question with neutral `web/app/…` paths, since only
the extension was ever load-bearing there; and the license boilerplate a
retrieval test uses to prove zero-bit fingerprints names a fictional company
rather than a real one. The decision-record citations in the changelog are gone,
replaced by what was decided where the sentence needed it, because a bare
`ADR-367` points at a document nobody outside can read.

Nothing under `bench/` changed except path plumbing. The benchmark queries are
chosen against a specific corpus, and swapping a high-match pattern for a
neutral one would quietly turn a measured race into a zero-match one.
