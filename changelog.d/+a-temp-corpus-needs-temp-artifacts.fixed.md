The Go kinship suite built its corpus in a temp directory but let the **artifact home** come from the ambient environment, so a developer with `GIST_DIR` exported had every one of these tests answering out of some other tree's atlas. That reads as `recall found nothing for text lifted out of the corpus itself` — a failing assertion about kinship — rather than as a misconfigured run.

The fixture now gives each corpus its own artifact home. A temp corpus is only hermetic if its artifacts are too; the suite passes with `GIST_DIR` set and unset alike, instead of requiring the caller to remember to unset it.

Module floor lowered to `go 1.24` alongside irregex: the `new(0.6)` sugar that had forced `go 1.26.3` was test-only.
