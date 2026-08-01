Four docs cited `.local/spikes/…` dossiers from the private monorepo this was
split out of. Two of those dossiers no longer exist anywhere, so the citations
were pointing at evidence nobody can read - including us.

Where the citation was only provenance, it is gone and the sentence stands on
its own: `bench/bounds/codex/README.md` says the codex graduated from an early
rung-1 prototype without naming a directory you cannot open. Where the citation
carried a verdict - the compression-versus-embeddings KILL in
`research/relate/PRIOR_ART.md`, `research/relate/TESTING.md`, and
`bench/conformance/relate/README.md` - the verdict stays and the docs now say
plainly that its write-up never shipped here, so the numbers behind it are not
in this repo. What is in the repo is `bench/conformance/relate/knn.zig`, the
harness that produced them; the race re-runs against a labeled manifest.

No measurement, benchmark value, or claim was invented to fill the gap. A
summary of a spike nobody can still read would be fiction with a citation
stapled to it, which is worse than an honest gap. `.local/` stays this repo's
scratch convention; only the vanished-spike citations changed.
