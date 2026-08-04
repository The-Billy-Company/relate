#!/usr/bin/env python3
"""What **relate** certifies — the one file in `guard/` that is not vendored.

Every other module here is byte-identical across the four packages and holds the
*method*: what makes a bundle reproducible, what a ledger drift looks like, when
a release may be cut. This file holds the *claim*, and it is relate's alone.

relate is compression-as-search. Its certificate cannot borrow a single number
from gist's, because it does not answer gist's question: `similar` and `echoes`
retrieve by *description length*, and the class of queries they serve is one
exact search provably returns nothing for. So the layers here certify a
retrieval contract and the boundary that defines its territory:

    F  the codex self-index — searchable, sub-entropy, decodable, with count
       latency independent of corpus size
    G  the retrieval contract — fail-closed on the boundary (every paraphrase
       query finds zero hits under exact search), recall@1, anti-redundant pack,
       and sub-trigram recall
    K  multi-pattern simultaneous matching, against Hyperscan/Vectorscan

The engine bounds (B–E, J, L) belong to `irregex` and the product-surface layers
(A, H, I) to `gist`, on the rule the bench charters state: **a package certifies
what it builds.** A claim measurable by linking the engine belongs upstream; a
claim needing a running product binary belongs to whichever package can execute
it. Those layers are not missing — they are published by their owners, over
their own corpora, with their own ledgers.

No headline number is scraped yet. A ledger headline is a promise that the
number appears in the same shape in every future mint, and Layer G's claims are
pass/fail invariants rather than a ratio anyone would trend. Until the mint
stabilizes what it prints, the ledger tracks which layers shipped — which is the
drop it exists to catch — and nothing it would have to guess at.

Shell reads the roster from this file rather than re-deriving it::

    python3 bench/certificate/guard/profile.py headers
    python3 bench/certificate/guard/profile.py sidecars
"""

from __future__ import annotations

import sys

from charter import Charter, Layer, main

#: Tools that appear as a timed column somewhere in the bundle. `gist` is here
#: because Layer G's boundary claim is measured BY exact search: the proof that a
#: paraphrase query is outside regex's reach is `gist -F` returning zero hits.
BENCH_TOOLS = frozenset({"relate", "gist", "hyperscan", "vectorscan", "xz", "zstd"})
#: Tools that build or drive the measurement but are never themselves timed.
SUPPORT_TOOLS = frozenset({"zig", "hyperfine"})


CHARTER = Charter(
    package="relate",
    # The ecosystem's artifact home (`assay/brand.zig`), not a per-package one:
    # relate writes its codex shelf and its layer receipts through the engine's
    # own `home.outDir()`, and a gate that looked somewhere else would judge an
    # empty directory. Separate checkouts already make it a per-package `.gist`.
    artifact_dir=".gist",
    roster=(
        Layer(
            "F",
            "Layer F — codex self-index",
            "## Layer F — codex self-index (compressed, searchable, decodable)",
            "codex.csv",
        ),
        Layer(
            "G",
            "Layer G — relate",
            "## Layer G — relate (retrieval by description length, not pattern)",
            "relate.csv",
        ),
        Layer(
            "K",
            "Layer K — multi-pattern",
            "## Layer K — multi-pattern simultaneous matching (vs Hyperscan/Vectorscan)",
            "multipattern.csv",
        ),
    ),
    required_files=(
        "CERTIFICATE.md",
        "machine.json",
        "tool-versions.txt",
        "corpus-manifest.tsv",
    ),
    required_machine_keys=(
        "cpu_model",
        "cpu_count",
        "ram_bytes",
        "os",
        "kernel",
        "filesystem",
        "corpus_id",
        "corpus_file_count",
        "corpus_total_bytes",
        "runs",
        "warmup",
        "roots",
    ),
    required_tools=("zig", "relate", "gist"),
    support_tools=SUPPORT_TOOLS,
    bench_tools=BENCH_TOOLS,
)


if __name__ == "__main__":
    raise SystemExit(main(CHARTER, sys.argv))
