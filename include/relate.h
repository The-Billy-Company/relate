/* relate — the compression-kinship product's C ABI.
 *
 * Kinship, retrieval, and the multi-pattern sweep producer (relate_run).
 * Everything this header does not itself declare comes from libirgx via
 * <irgx.h>: status codes, the fault pull, pattern-semantics bits, the warm
 * engine and its cancel token, and the row cursor (irgx_rows_*). Link
 * librelate and libirgx — kinship has no dependency on search.
 *
 * relate_run returns an irgx_rows * walked by the four irgx_rows_*
 * symbols. That is deliberate: gist_run, relate_run, and blast_run all hand
 * back the same cursor, and all three take the same engine. */
#ifndef RELATE_H
#define RELATE_H

#include <irgx.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Verb op codes for relate_run — same numeric values as the ecosystem-wide
 * verb table in irregex/contract/analytic.toml. A host that already stored the numbers
 * keeps them; only the library that answers them has moved. */
#define RELATE_OP_SIMILAR 1u
#define RELATE_OP_DUPS 2u
#define RELATE_OP_CLUSTERS 3u
#define RELATE_OP_ECHOES 4u
#define RELATE_OP_CONCEPTS 5u
#define RELATE_OP_FRAGMENTS 6u
#define RELATE_OP_DISTINCT 7u
#define RELATE_OP_RECALL 8u
#define RELATE_OP_PACK 9u
#define RELATE_OP_QUOTE 10u
#define RELATE_OP_PATTERNS 11u
#define RELATE_OP_PATTERN_COUNTS 12u

/* Analytic params flags. The presence bits exist because 0.0 is a MEANINGFUL
 * threshold (max_distance 0.0 = byte-identical only), so "unset" cannot be
 * spelled as zero the way an integer budget can. Same layout as every other
 * producer in the ecosystem — the numbers are shared on purpose. */
#define RELATE_AN_MAX_DISTANCE (1u << 0) /* params.max_distance is present  */
#define RELATE_AN_MIN_ECHO (1u << 1)     /* params.min_echo is present      */
#define RELATE_AN_NO_INDEX (1u << 2)     /* force the live build, skip warm */
#define RELATE_AN_FIXED (1u << 3)        /* -F for the verb's patterns      */
#define RELATE_AN_IGNORE_CASE (1u << 4)  /* -i for the verb's patterns      */
#define RELATE_AN_BY_PATTERN (1u << 6)   /* sweep: tally per pattern        */
#define RELATE_AN_BY_FILE (1u << 7)      /* sweep: tally per file           */
#define RELATE_AN_DISTINCT (1u << 8)     /* kinship: the un-echoed polarity */

/* The three params families this library's verbs use. Each opens with
 * struct_size — append-only, so an unknown size fails closed with
 * IRGX_INVALID. `top` 0 = unbounded. */

/* similar · dups · clusters · echoes · concepts · fragments · distinct.
 * `target` NULL = the corpus-wide sweep (dups/clusters/echoes/concepts). */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const uint8_t *target;
  size_t target_len;
  uint32_t channel; /* IRGX_CHANNEL_* */
  uint32_t unit;    /* IRGX_UNIT_*    */
  double max_distance;
  double min_echo;
  uint32_t min_grade; /* IRGX_GRADE_*: withhold anything weaker */
  uint32_t min_size;
  uint32_t min_lines;
  uint32_t top;
} relate_kinship_params;

/* recall · pack · quote — free text priced against the corpus. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const uint8_t *query;
  size_t query_len;
  uint32_t top;
  uint32_t reserved;
} relate_retrieval_params;

/* patterns · pattern_counts — N patterns, one walk, exact attribution. */
typedef struct {
  uint32_t struct_size;
  uint32_t flags;
  const irgx_text *patterns;
  size_t npatterns;
  const uint8_t *under; /* optional glob scope; NULL = the whole corpus */
  size_t under_len;
  uint32_t top;
  uint32_t reserved;
} relate_sweep_params;

/* Run one relate verb and materialize a row cursor; writes it to *out.
 * `op` is a RELATE_OP_* code and `params` MUST be its declared family — a
 * mismatched or wrongly-sized struct is IRGX_INVALID. `cancel` is optional
 * (NULL = none) and is the same token the exact plane uses.
 *
 * Returns IRGX_OK, or a negative fail-closed status. IRGX_STALE means
 * this tier declines and the caller should answer through the subprocess
 * fallback — it is NOT a failure.
 *
 * The cursor is an irgx_rows *: walk it with irgx_rows_next /
 * _next_batch / _stats and free it with irgx_rows_close from libirgx. */
int32_t relate_run(irgx_engine *engine, uint32_t op, const void *params,
                   irgx_cancel *cancel, irgx_rows **out);

#ifdef __cplusplus
}
#endif

#endif /* RELATE_H */
