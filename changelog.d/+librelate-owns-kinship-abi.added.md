`librelate` + `include/relate.h` ship `relate_run` for the kinship, retrieval,
and multi-pattern-sweep verbs that used to hide behind `gist_run`. The
in-process `patterns` / `pattern_counts` sweep moved with them. A host that
only wants compression-search links this library (plus `libgist` for the warm
engine and `libirgx` for the row cursor) and never sees search-product
symbols.
