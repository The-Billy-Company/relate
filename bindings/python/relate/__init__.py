"""relate — compression as search.

What resembles what, and what would explain this text. Kinship, retrieval, and
the multi-pattern sweep — nothing here is exact search, and nothing here is the
composed blast/provenance face.

    import relate

    for kin in relate.similar("services/backend/api/main.go", min_grade="strong"):
        print(kin.unit, kin.grade)
    reading_set = relate.pack("how does wallet crediting settle").paths
"""

from __future__ import annotations

from irregex.contract import Channel, Grade, grade_of
from irregex.contract import grades as grade
from irregex.runtime import shell as engine
from irregex.runtime.errors import (
    GistError,
    GistNotFoundError,
    RowDecodeError,
    SchemaDriftError,
    SearchFailedError,
)

from . import corpus, kinship, retrieval, sweep
from .corpus import Kin, Region
from .kinship import (
    Family,
    Lonely,
    Neighbor,
    Pair,
    distinct,
    families,
    pairs,
    similar,
)
from .lifecycle import (
    Artifact,
    AtlasStatus,
    IndexState,
    atlas_index,
    atlas_status,
)
from .retrieval import Packed, Phrase, Pick, Quotation, Recalled, pack, quote, recall
from .sweep import PatternCount, PatternHit, pattern_counts, patterns

__all__ = [
    "Artifact",
    "AtlasStatus",
    "Channel",
    "Family",
    "GistError",
    "GistNotFoundError",
    "Grade",
    "IndexState",
    "Kin",
    "Lonely",
    "Neighbor",
    "Packed",
    "Pair",
    "PatternCount",
    "PatternHit",
    "Phrase",
    "Pick",
    "Quotation",
    "Recalled",
    "Region",
    "RowDecodeError",
    "SchemaDriftError",
    "SearchFailedError",
    "atlas_index",
    "atlas_status",
    "binary",
    "corpus",
    "distinct",
    "engine",
    "families",
    "grade",
    "grade_of",
    "kinship",
    "pack",
    "pairs",
    "pattern_counts",
    "patterns",
    "quote",
    "recall",
    "retrieval",
    "similar",
    "sweep",
]


def binary() -> str:
    """Absolute path to the resolved `relate` binary."""
    return engine.relate_binary()
