The shared artifact home moved from `.local/gist-verify/` to `.gist/`, and
relate's docs and contract now name the new path. `.local` was the monorepo's
machine-local scratch convention; outside it the directory means nothing, and
`gist-verify` read like a verification harness rather than where the index,
kinship atlas, and codex shelf actually live. `.gist` names itself the way
`.git`, `.ruff_cache`, and `.mypy_cache` do, and it reads correctly against the
`GIST_DIR` override that was always the real knob.

This orphans whatever you already built. Nothing migrates and nothing is
deleted; the old directory just stops being consulted, so the first query after
this lands answers live instead of warm. Regenerating is cheap - `gist index` is
about 3 seconds and `relate index` about 4 on a full tree - and if you would
rather not, `GIST_DIR=.local/gist-verify` pins the old location and everything
keeps reading out of it.

`contract/kinship.toml` declares the atlas and fragment artifacts at the new
path, and `.gist/` is gitignored here alongside it.
