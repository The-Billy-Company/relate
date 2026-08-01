#!/usr/bin/env bash
# codex-scale race driver — the full at-scale proof in one command.
#
# 1. snapshots a deterministic real-source corpus (sorted-path concat of the
#    repo's text files) into .local/codex-bench/corpus.bin,
# 2. runs the codex-scale harness (build/count/find/restore across slices),
# 3. sizes identical slices with gzip/bzip2/zstd/xz for the space table.
#
# Usage: bench/codex/race.sh [sizes-mb-csv]   (default 1,4,16,64,128)
# Results: $CODEX_OUT/{scale.jsonl,compressors.jsonl}   (default .local/codex-bench)
# Env:   CODEX_OUT=DIR    output dir (the certificate points this at its own dir)
#        CODEX_BIN=PATH   run a prebuilt codex-scale instead of `zig build codex-scale`
#                         (the certificate builds it once via `zig build lab`)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# bench/bounds/codex → package root (three hops). Formerly climbed into a
# parent monorepo; this package is the repo.
REPO="$(cd "${HERE}/../../.." && pwd)"
KERNEL="${REPO}"
OUT="${CODEX_OUT:-${REPO}/.local/codex-bench}"
SIZES="${1:-1,4,16,64,128}"
mkdir -p "${OUT}"

if [[ ! -f "${OUT}/corpus.bin" ]]; then
  echo "── snapshotting corpus (deterministic sorted-path concat) ──"
  python3 - "${REPO}" "${OUT}/corpus.bin" << 'PY'
import os
import sys
from pathlib import Path

repo, out = Path(sys.argv[1]), Path(sys.argv[2])
CAP = 192 << 20
# Corpus scope: $GIST_ROOTS override (product env — same name the CLIs read),
# else this package's source trees, else the whole checkout.
ROOTS = os.environ.get("GIST_ROOTS", "").replace(":", " ").replace(",", " ").split() or [
    "src", "bench", "research"]
ROOTS = [r for r in ROOTS if (repo / r).is_dir()] or ["."]
EXTS = {".zig", ".py", ".go", ".ts", ".tsx", ".rs", ".swift", ".sql", ".sh",
        ".md", ".toml", ".proto", ".ex", ".exs", ".css", ".yaml", ".yml", ".json"}
SKIP = {".git", ".local", "node_modules", "target", "dist", "dist-types", "build",
        ".build", "out", ".next", "coverage", ".venv", "venv", "__pycache__",
        ".zig-cache", "zig-out", "vendor", ".swiftpm", "Pods", "DerivedData",
        ".turbo", ".pnpm-store", "graphify-out"}

total = files = 0
with out.open("wb") as fh:
    for root in ROOTS:
        base = repo / root
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*")):
            if total >= CAP:
                break
            if not p.is_file() or p.suffix not in EXTS or any(s in p.parts for s in SKIP):
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
