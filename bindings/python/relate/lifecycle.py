"""Relate's persisted artifacts — atlas, fragments, and the codex shelf.

Warmth is an optimization, never a dependency: a missing or stale artifact
degrades to a live answer with identical bytes. This module is how a program
sees that tier — especially before verbs that *require* the shelf
(`retrieval.quote`, blast's `provenance`).
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING

from irgx.runtime.errors import SearchFailedError

if TYPE_CHECKING:
    import os

    from irgx.runtime.shell import Output


class IndexState(StrEnum):
    """Availability state in the versioned status schema."""

    READY = "ready"
    UNAVAILABLE = "unavailable"


@dataclass(frozen=True, slots=True)
class Artifact:
    """One persisted compression artifact. `stale_files` is not damage — a warm answer folds changed files back in from live bytes and stays byte-identical to a cold rebuild, so staleness costs time, never correctness."""

    state: IndexState
    files: int = 0
    fragments: int = 0
    bytes: int = 0
    stale_files: int = 0
    built_unix_ns: int | None = None

    @property
    def ready(self) -> bool:
        """Whether this artifact can accelerate a query at all."""
        return self.state is IndexState.READY

    @property
    def staleness(self) -> float | None:
        """Share of the snapshotted corpus that changed since the anchor, in [0, 1]."""
        return self.stale_files / self.files if self.files else None

    @property
    def age_seconds(self) -> float | None:
        """Wall-clock seconds since this artifact was built, or `None` when never built."""
        if self.built_unix_ns is None:
            return None
        return max(0.0, time.time() - self.built_unix_ns / 1e9)


@dataclass(frozen=True, slots=True)
class AtlasStatus:
    """What relate's three artifacts can accelerate right now."""

    schema_version: int
    atlas: Artifact
    fragments: Artifact
    shelf: Artifact

    @property
    def ready(self) -> bool:
        """Whether kinship queries can run warm — the tier most verbs use."""
        return self.atlas.ready

    @property
    def can_quote(self) -> bool:
        """Whether `retrieval.quote` and blast `provenance` have their shelf."""
        return self.shelf.ready


def parse_atlas_status(report: str) -> AtlasStatus:
    """Decode relate's versioned status JSON."""
    payload = json.loads(report)
    return AtlasStatus(
        schema_version=int(payload.get("schema_version", 1)),
        atlas=_artifact(payload.get("atlas")),
        fragments=_artifact(payload.get("frag")),
        shelf=_artifact(payload.get("shelf")),
    )


def _artifact(section: object) -> Artifact:
    """Decode one artifact section, defaulting an absent one to `unavailable`."""
    if not isinstance(section, dict):
        return Artifact(IndexState.UNAVAILABLE)
    return Artifact(
        state=IndexState(section.get("state", "unavailable")),
        files=_count(section, "files"),
        fragments=_count(section, "fragments"),
        bytes=_count(section, "bytes"),
        stale_files=_count(section, "stale_files"),
        built_unix_ns=_count(section, "built_unix_ns") or None,
    )


def _count(section: dict[str, object], key: str) -> int:
    """One count field — absent or JSON `null` reads as zero."""
    value = section.get(key)
    return int(value) if isinstance(value, int | float) else 0


def atlas_status(
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = 60.0,
) -> AtlasStatus:
    """Inspect relate's persisted artifacts without building anything.

    `relate status` exits 1 when the atlas is missing — that is a report, not a
    failure, so this returns an `unavailable` artifact rather than raising.
    """
    out = _relate(["status", "--json"], cwd=cwd, timeout=timeout, ok_codes=(0, 1))
    return parse_atlas_status(out.stdout)


def atlas_index(
    *,
    shelf: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = 900.0,
) -> AtlasStatus:
    """Build and publish relate's kinship atlas, then report what is ready."""
    _relate(["index", *(["--shelf"] if shelf else [])], cwd=cwd, timeout=timeout)
    return atlas_status(cwd=cwd, timeout=60.0)


def _relate(
    argv: list[str],
    *,
    cwd: str | os.PathLike[str] | None,
    timeout: float,
    ok_codes: tuple[int, ...] = (0,),
) -> Output:
    """Invoke the `relate` binary via the shared substrate shell."""
    from irgx.runtime.shell import run_verb

    return run_verb("relate", argv, cwd=cwd, timeout=timeout, ok_codes=ok_codes)


# Re-export for callers that only need the failure type beside lifecycle.
__all__ = [
    "Artifact",
    "AtlasStatus",
    "IndexState",
    "SearchFailedError",
    "atlas_index",
    "atlas_status",
    "parse_atlas_status",
]
