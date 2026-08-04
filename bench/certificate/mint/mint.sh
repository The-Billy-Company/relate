#!/usr/bin/env bash
# mint.sh — relate's Dominance-and-Fit Certificate: Layers F, G, and K.
#
# THIS PACKAGE CERTIFIES WHAT IT BUILDS. relate is compression-as-search, and the
# three layers here are the three claims only a running `relate` can make — none
# of them is "faster at the same query", because none of them IS the same query:
#
#   F  codex self-index — a corpus compressed, and still searchable and
#      decodable from the compressed form, priced against gzip/bzip2/zstd/xz
#   G  retrieval by description length — fail-closed on four claims, the first
#      of which is the boundary itself: every paraphrase query must return ZERO
#      hits under exact `gist -F`. That is not a caveat, it is the reason relate
#      exists, and it is PROVEN here rather than asserted
#   K  multi-pattern simultaneous matching — one walk, N patterns, exact
#      per-pattern attribution, against Hyperscan/Vectorscan
#
# Layer A and the CLI surface (H, I) are minted by `gist`; the engine's bounds
# (B, B′, C, D, E, J, L) by `irregex`. This mint neither drives nor waits on
# them: each package publishes its own bundle, over its own corpus, with its own
# ledger. The roster this script must satisfy is `guard/profile.py`, and the
# completeness gate at the end reads it rather than a second list kept by hand.
#
# Usage:  bash bench/certificate/mint/mint.sh
#         CERT_PUBLISH_DIR=bench/certificate/artifact \
#           bash bench/certificate/mint/mint.sh        (mint + publish)
#
# Env:  CERT_CORPUS_ID    which declared corpus this measures; must name a row in
#                         `bench/certificate/corpus.toml`, whose `fetch` recipe
#                         the floor runs if that tree isn't already here
#                         (default: ecosystem-v1)
#       GIST_CORPUS_ROOT  measure a tree already on disk instead of fetching one;
#                         its roots must match what the charter declares
#       CODEX_SIZES       Layer F slice sizes in MB (default 1,4,16,64,128)
#       CERT_ALLOW_DIRTY  1 to mint from an uncommitted tree (local refresh)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# All three layers here are claims about a POPULATION — what repeats, what is
# near what, what a codebook can price — so the corpus is not a backdrop, it is
# half the claim. The self checkout is 172 files of mostly one language, where a
# kinship result is decided by which two files happen to be large. The ecosystem
# tree is nine languages carrying real vendored twins and real forked prose:
# duplication relate did not plant, which is the only kind that grades it.
#
# Exported before the floor is sourced — the floor reads it to decide which tree
# to measure, and refuses the run if that tree is not the one this bundle claims.
export CERT_CORPUS_ID="${CERT_CORPUS_ID:-ecosystem-v1}"

# The vendored measurement floor: roots, corpus scope, binary staging, and the
# hyperfine/oracle helpers. Identical bytes in all four packages, so a timing
# here and a timing in `gist` were measured the same way.
# shellcheck source=../../apparatus/field.sh
source "${HERE}/../../apparatus/field.sh"
need_hyperfine

RUNS="${RUNS:-20}"
WARMUP="${WARMUP:-3}"
CERT="${OUT}/CERTIFICATE.md"
WORK="${COMPETE_DIR}/certify"
mkdir -p "${OUT}" "${WORK}"

# Resolved once, not per splice: the machine and toolchain a mint reports must be
# the same two strings in every layer of one bundle.
ARCH="$(uname -m)"
ZIG_VERSION="$(zig version)"

die() {
  echo "certificate aborted: $*" >&2
  exit 1
}

# Refuse to mint a certificate whose machine.git_commit could not equal a clean
# HEAD — unless CERT_ALLOW_DIRTY=1 (local refresh / coworking trees).
git -C "${KERNEL}" rev-parse --verify HEAD > /dev/null 2>&1 || die "cannot resolve git HEAD"
dirty="$(git -C "${KERNEL}" status --porcelain 2> /dev/null || true)"
if [[ -n "${dirty}" && "${CERT_ALLOW_DIRTY:-0}" != "1" ]]; then
  echo "certificate aborted: worktree is dirty — commit or isolate changes before certifying" >&2
  echo "(local refresh: CERT_ALLOW_DIRTY=1 bash bench/certificate/mint/mint.sh)" >&2
  git -C "${KERNEL}" status --porcelain >&2
  exit 1
fi

# Seed the document. `gist` gets its preamble from `gist-bench certify`, which
# rewrites the whole file; this package has no such writer, and every reporter
# below SPLICES — it replaces its own section and appends when absent. Rewritten
# every mint on purpose: a certificate is the bytes of one run.
cat > "${CERT}" << 'EOF'
# relate — Dominance-and-Fit Certificate

Compression as search. Each layer below certifies a question exact pattern
matching cannot express, so none of them is a speed claim about the same query —
Layer G opens by proving its own queries return **zero** hits under `gist -F`,
which is what makes the rest of it a different question rather than a slower
answer to the same one.

Minted by `bench/certificate/mint/mint.sh`. Every number is spliced by a reporter
that reads a committed artifact in this bundle; nothing here is typed by hand.
The machine, the tool identities, and the corpus that produced it are
`machine.json`, `tool-versions.txt`, and `corpus-manifest.tsv` beside this file.

Layer A (dominance over the field) and the CLI surface belong to `gist`; the
engine's bounds to `irregex`. A package certifies what it builds.
EOF

echo "building relate + staging the product binaries…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast) || die "zig build failed"
# Layer G's boundary claim is measured BY exact search, so the gist face has to
# be staged beside relate's — a boundary nobody checked is an assertion.
compete_install_gist_bin || die "could not stage the product binaries"
[[ -x "${RELATE_BIN}" ]] || die "no relate binary staged at ${RELATE_BIN}"

# ── Layer F — the codex self-index ───────────────────────────────────────────
# The race snapshots its own deterministic corpus and prices identical slices
# against the general-purpose compressors, so the space table is a comparison
# rather than a claim about one number.
echo "certifying the codex self-index (Layer F)…"
CODEX_OUT="${WORK}/codex" bash "${KERNEL}/bench/bounds/codex/race.sh" \
  "${CODEX_SIZES:-1,4,16,64,128}" || die "Layer F (codex race) failed"
python3 "${HERE}/../report/codex.py" \
  --certificate "${CERT}" \
  --scale "${WORK}/codex/scale.jsonl" \
  --compressors "${WORK}/codex/compressors.jsonl" \
  --csv "${OUT}/codex.csv" \
  --machine "${ARCH}" --zig "${ZIG_VERSION}" || die "Layer F splice failed"

# ── Layer G — retrieval by description length ────────────────────────────────
# Fail-closed on all four claims; the reporter aborts the mint on any violation,
# so a spliced Layer G is itself the receipt that the contract held.
echo "certifying retrieval quality (Layer G, fail-closed)…"
bash "${HERE}/relate.sh" || die "Layer G (relate contract) failed"

# ── Layer K — multi-pattern simultaneous matching ────────────────────────────
# Vectorscan is optional: absent, the race still prices gist's own tiers against
# N independent searches and the reporter renders the rival column as unavailable
# rather than inventing one.
echo "racing multi-pattern matching (Layer K)…"
MULTIPATTERN_OUT="${WORK}/multipattern" \
  bash "${KERNEL}/bench/dominance/races/multipattern.sh" || die "Layer K race failed"
python3 "${HERE}/../report/multipattern.py" \
  --perbyte "${WORK}/multipattern/perbyte.tsv" \
  --raw "${WORK}/multipattern/raw" \
  --meta "${WORK}/multipattern/meta.json" \
  --certificate "${CERT}" \
  --csv "${OUT}/multipattern.csv" || die "Layer K splice failed"

# ── provenance — the three artifacts that make a number re-derivable ─────────
# --root is the CORPUS (paths.list is relative to it), --source-root the checkout
# whose HEAD built the binaries. They differ whenever the mint runs against a
# corpus snapshot, and hashing the manifest against the wrong one silently
# produces rows for files nothing measured.
echo "emitting reproducibility metadata…"
[[ -f "${PATHS_LIST}" ]] || (cd "${CORPUS}" && "${GIST_BIN}" index > /dev/null) \
  || die "could not persist the corpus file list"
pins=(--tool "relate=${RELATE_BIN}" --tool "gist=${GIST_BIN}")
for t in zig hyperfine xz zstd; do
  if tool_bin="$(command -v "${t}" 2> /dev/null)"; then pins+=(--tool "${t}=${tool_bin}"); fi
done
[[ "${CERT_ALLOW_DIRTY:-0}" = "1" ]] && pins+=(--allow-dirty)
python3 "${KERNEL}/bench/apparatus/provenance.py" \
  --out "${OUT}" --root "${CORPUS}" --source-root "${KERNEL}" \
  --corpus-id "${CERT_CORPUS_ID}" \
  --roots "${ROOTS[*]}" --paths-list "${PATHS_LIST}" \
  --runs "${RUNS}" --warmup "${WARMUP}" \
  "${pins[@]}" || die "provenance emit failed"

# Structural completeness only — a bundle is judged on its bytes, never on the
# tree that produced it.
python3 "${HERE}/../guard/artifacts.py" --artifacts-dir "${OUT}" --artifacts || exit 1

# Publish a committed snapshot when asked (CERT_PUBLISH_DIR is package-relative).
if [[ -n "${CERT_PUBLISH_DIR:-}" ]]; then
  pub="${KERNEL}/${CERT_PUBLISH_DIR}"
  mkdir -p "${pub}"
  cp -f "${CERT}" "${OUT}/machine.json" "${OUT}/tool-versions.txt" \
    "${OUT}/corpus-manifest.tsv" "${pub}/"
  # Driven from `profile.py`, so a new layer publishes its receipt without a
  # second list to keep in step.
  sidecar_list="$(python3 "${HERE}/../guard/profile.py" sidecars)" || exit 1
  mapfile -t sidecars <<< "${sidecar_list}"
  for side in "${sidecars[@]}"; do
    [[ -f "${OUT}/${side}" ]] && cp -f "${OUT}/${side}" "${pub}/"
  done
  # --public-safe is the difference between a mint and a PUBLISH: entering git
  # means a stranger must be able to fetch this corpus and re-derive the number,
  # and it means no private path rides along in a manifest row.
  python3 "${HERE}/../guard/artifacts.py" --artifacts-dir "${pub}" --artifacts --public-safe \
    || exit 1
  echo "published reproducible certificate → ${pub}"
  python3 "${HERE}/../ledger/ledger.py" record --bundle "${pub}" || exit 1
fi
