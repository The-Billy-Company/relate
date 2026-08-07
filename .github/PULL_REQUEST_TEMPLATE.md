<!--
Thanks for sending this. Delete any section that does not apply rather than
writing "n/a" in all of them - a short, honest PR body beats a filled-in form.
CONTRIBUTING.md has the long version of everything below.
-->

## What changed

<!-- One or two sentences in the voice of the change. What is different now? -->

## Why

<!-- The problem, not the patch. If there is an issue, link it. -->

## What proves it

<!--
The question review asks first. Name the test, the gate, the fixture, or the
corpus - and what it would have done before this change. "Existing tests pass"
is not proof that a new behaviour is right.

Touching the atlas, the shelf, the freshness fold, or the keep? The check that
matters is that the warm answer is byte-identical to `--no-index` on a real
tree.

Changing what an answer MEANS - a metric, a band, a floor, a ranking? Show it
on a corpus. A distance moving is a claim about kinship, and the way to make it
reviewable is to name what got better and what got worse.
-->

## Surface

<!--
Adding a verb? The surface has two kinship questions - one probe (`similar`) and
the corpus against itself (`echoes`) - and four earlier verbs turned out to be
corners of those, reached by a flag. Argue that this is a genuinely new
question, or make it an axis.

Retiring a spelling? It exits 2 naming its replacement; it does not become an
unknown-command error.
-->

## What it costs

<!--
Allocation, syscalls, a wider public surface, a slower cold path, a larger
persisted artifact. If the answer is genuinely nothing, say so - that is an
answer.
-->

## What it replaces

<!--
If a newer path supersedes an older one, the older one should be gone in this
same PR. Two spellings of the same thing is how a codebase grows two spellings
of the same bug.
-->

---

- [ ] `zig build test` passes, and `zig fmt .` leaves the tree clean
- [ ] A news fragment is in `changelog.d/` (`+<slug>.<type>.md`), unless this is
      comment-only, format-only, or genuinely invisible
- [ ] No gate was made to skip, soften, or self-satisfy in order to go green
- [ ] A change to the vocabulary - a channel, a grade band, a verb, a retired
      spelling - moved `contract/kinship.toml` with it
- [ ] `charter.zone` is updated in this PR if a new import edge was
      needed
- [ ] Anything borrowed from a paper or another tool is cited in
      `research/relate/PRIOR_ART.md` and at the call site
