# relate - code similarity search for Python

Find near-duplicate files, clone families, and where a pasted snippet came
from. No embeddings, no model, no vector database; the whole thing is
compression. If one file describes another cheaply, they are related, and that
catches the renamed-variable copies a byte diff walks straight past.

Where [`gist`](https://github.com/The-Billy-Company/gist) answers _"where is
this exact pattern?"_, relate answers the set-shaped questions beside it: what
is this thing like, what repeats in here, which files explain this text
together, and where did this text come from.

```bash
pip install relate-search
```

The distribution is `relate-search`; the import stays `relate`. The bare name
on PyPI belongs to an unrelated author, so this is the same split bs4, PIL, and
cv2 already ship.

This package is the bindings, not the engine: every verb answers by running the
`relate` binary, so that has to be on `PATH` (or `$RELATE_BIN`). Without it the
first call raises `GistNotFoundError` rather than failing quietly.

## Two questions, not ten verbs

`similar` is the neighbor verb: one probe, one ranked answer. `echoes` is the
repetition verb: no probe, the corpus against itself. Everything else is a flag
on one of those.

```python
import relate

# What is near THIS one? The probe's shape picks the pricing: a path scores
# kinship over files, `path#L120` scores the function containing that line,
# and bare text scores recall.
for kin in relate.similar("src/server/api/main.go", min_grade="strong"):
    print(kin.unit, kin.grade, kin.score)

# What repeats among ALL of them? Families are the shape you act on - the
# whole fixture farm, the helper pasted into six files - not raw pairs.
for family in relate.families(channel="copies", min_size=3):
    print(family.repeated_lines, family.members)
```

Every row is graded (`identical` / `strong` / `moderate` / `weak` / `none`)
against that channel's calibrated bands, so an answer made only of background
says so instead of looking like a find. Ask for a floor with `min_grade` rather
than filtering after the fact.

## Retrieval and provenance

```python
# The anti-redundant reading set: each pick priced by what it adds BEYOND the
# picks before it, so a near-duplicate of an earlier pick never makes the cut.
packed = relate.pack("how does Acme crediting settle", top=6)
print(packed.paths, packed.coverage, packed.foreign)

# Where did this text come from? Rewrites it as corpus quotations, priced in
# bits and attributed per phrase.
quoted = relate.quote("const fd = std.posix.openat(std.posix.AT.FDCWD, path")
for phrase in quoted.phrases:
    print(phrase.source, phrase.text)

# N patterns, one attributed walk, instead of N cold searches.
for hit in relate.patterns(["AcmeService", "acme_check", "acme_grant"]):
    print(hit.pattern, hit.path)
```

## Narrowing by an exact filter

`similar`, `families`, and `pack` all take `matching`, which narrows the
population to units an exact pattern admitted _first_. "Among the files that
mention `AcmeService`, which are forks of each other?" is one call, not a
pipe, and the noise floor becomes the matching set instead of the whole corpus.

```python
relate.families(matching=["AcmeService"], channel="copies")
```

## What it needs

The `relate` binary on `PATH` (or `$RELATE_BIN`), which
[the repository](https://github.com/The-Billy-Company/relate) builds with
`zig build`. Warm answers want an atlas:

```python
relate.atlas_index(shelf=True)   # kinship + fragment atlas, plus the codex shelf
print(relate.atlas_status())
```

A warm answer is byte-identical to a cold rebuild; the atlas folds in only the
files that changed since it was anchored. A missing or corrupt atlas degrades
to a live build automatically, so warm is an optimization tier and never a
dependency. `quote` is the one verb that needs the shelf, and says so when it
is missing.

## The rest of the family

| Package | Question |
|---|---|
| [`gist-search`](https://pypi.org/project/gist-search/) | where is this exact pattern? |
| **`relate-search`** | what resembles this, and what repeats? |
| [`blast-search`](https://pypi.org/project/blast-search/) | what breaks if I change this symbol? |
| [`irregex`](https://pypi.org/project/irregex/) | the linear-time regex engine underneath all three |

## Development

```bash
uv sync --group dev
uv run pytest
```

Depends on the sibling `irregex` binding (path source for local checkouts;
PyPI `irregex` for a published wheel). Behavioral tests also pull `gist-search`
as a dev oracle for independent exact-search checks.
