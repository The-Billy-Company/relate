#!/usr/bin/env bash
# codex-scale race driver — the full at-scale proof in one command.
#
# 1. snapshots a deterministic real-source corpus (sorted-path concat of the
#    corpus's text files) into .local/codex-bench/corpus.bin,
# 2. runs the codex-scale harness (build/count/find/restore across slices),
# 3. sizes identical slices with gzip/bzip2/zstd/xz for the space table.
#
# Usage: bench/bounds/codex/race.sh [sizes-mb-csv]   (default 1,4,16,64,128)
# Results: $CODEX_OUT/{scale.jsonl,compressors.jsonl}   (default .local/codex-bench)
# Env:   CODEX_OUT=DIR    output dir (the certificate points this at its own dir)
#        CODEX_BIN=PATH   run a prebuilt codex-scale instead of `zig build codex-scale`
#                         (the certificate builds it once via `zig build lab`)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# The vendored resolver rather than a hand-counted climb: it also honors
# GIST_CORPUS_ROOT, so this snapshot follows the same tree every other lane in
# the mint measures instead of always being this checkout.
# shellcheck source=../../apparatus/roots.sh
source "${HERE}/../../apparatus/roots.sh"
# `set -e` already aborts the script on a nonzero return; invoking this
# separately from an `|| exit` (rather than in one line) keeps errexit live
# for the call, per shellcheck SC2310.
gist_resolve_roots "${HERE}"
OUT="${CODEX_OUT:-${KERNEL}/.local/codex-bench}"
SIZES="${1:-1,4,16,64,128}"
mkdir -p "${OUT}"

if [[ ! -f "${OUT}/corpus.bin" ]]; then
  echo "── snapshotting corpus (deterministic sorted-path concat) ──"
  python3 - "${CORPUS}" "${OUT}/corpus.bin" << 'PY'
import os
import sys
from pathlib import Path

corpus, out = Path(sys.argv[1]), Path(sys.argv[2])
CAP = 192 << 20
# Corpus scope: $GIST_ROOTS override (product env — same name the CLIs read),
# else this package's source trees, else the whole checkout.
ROOTS = os.environ.get("GIST_ROOTS", "").replace(":", " ").replace(",", " ").split() or [
    "src", "bench", "research"]
ROOTS = [r for r in ROOTS if (corpus / r).is_dir()] or ["."]
EXTS = {".zig", ".py", ".go", ".ts", ".tsx", ".rs", ".swift", ".sql", ".sh",
        ".md", ".toml", ".proto", ".ex", ".exs", ".css", ".yaml", ".yml", ".json"}
SKIP = {".git", ".local", "node_modules", "target", "dist", "dist-types", "build",
        ".build", "out", ".next", "coverage", ".venv", "venv", "__pycache__",
        ".zig-cache", "zig-out", "vendor", ".swiftpm", "Pods", "DerivedData",
        ".turbo", ".pnpm-store", "derived-out"}

total = files = 0
with out.open("wb") as fh:
    for root in ROOTS:
        base = corpus / root
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*")):
            if total >= CAP:
                break
            # Skip tokens are judged against the path INSIDE the corpus, never the
            # absolute one. A materialized corpus lives under `.local/corpus/<id>`,
            # so matching on absolute parts skipped every file in it and handed
            # Layer F a zero-byte snapshot that still looked like a successful walk.
            if not p.is_file() or p.suffix not in EXTS:
                continue
            if SKIP.intersection(p.relative_to(corpus).parts):
                continue
            try:
                data = p.read_bytes()
            except OSError:
                continue
            fh.write(data)
            fh.write(b"\n")
            total += len(data) + 1
            files += 1
print(f"corpus.bin: {total / (1 << 20):.1f}MB from {files} files")
PY
fi

echo "── codex-scale (build/count/find/restore, oracle-verified) ──"
if [[ -n "${CODEX_BIN:-}" && -x "${CODEX_BIN}" ]]; then
  "${CODEX_BIN}" "${OUT}/corpus.bin" --sizes-mb "${SIZES}" > "${OUT}/scale.jsonl"
else
  (cd "${KERNEL}" && zig build codex-scale -- "${OUT}/corpus.bin" --sizes-mb "${SIZES}") \
    > "${OUT}/scale.jsonl"
fi

echo "── compressor baselines on identical slices ──"
: > "${OUT}/compressors.jsonl"
IFS=',' read -ra MBS <<< "${SIZES}"
for mb in "${MBS[@]}"; do
  bytes=$((mb * 1024 * 1024))
  corpus_bytes=$(stat -f%z "${OUT}/corpus.bin" 2> /dev/null || stat -c%s "${OUT}/corpus.bin" 2> /dev/null || echo 0)
  [[ "${corpus_bytes}" -ge "${bytes}" ]] || continue
  slice="${OUT}/.slice.bin"
  head -c "${bytes}" "${OUT}/corpus.bin" > "${slice}"
  gz=$(gzip -9 -c "${slice}" | wc -c | tr -d ' ')
  zs=$(zstd -19 -q -c "${slice}" | wc -c | tr -d ' ')
  xz_b=$(xz -9 -c "${slice}" | wc -c | tr -d ' ')
  bz="null"
  command -v bzip2 > /dev/null && bz=$(bzip2 -9 -c "${slice}" | wc -c | tr -d ' ')
  echo "{\"raw_bytes\":${bytes},\"gzip9\":${gz},\"bzip2\":${bz},\"zstd19\":${zs},\"xz9\":${xz_b}}" \
    | tee -a "${OUT}/compressors.jsonl"
  rm -f "${slice}"
done
echo "done → ${OUT}"
