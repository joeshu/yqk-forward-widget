/* HostPerfAttemptLedger.h — bounded playback-attempt accounting (pure C).
 *
 * T01 (PERF-07): the accounting core behind HostPerfMetrics. It is
 * deliberately free of Apple-framework dependencies so the same production
 * code can be executed by the Python suite on Linux (gcc) and by the macOS
 * CI (clang):
 * Tests/test_perf_metrics_attempt_accounting.py compiles this file together
 * with Tests/native_perf_ledger_tests.c and runs scripted scenarios with a
 * fake monotonic clock.
 *
 * Model (one user intent = one session; one try = one attempt):
 * - begin() starts an attempt with session/attempt/generation identity,
 *   engine, source revision, user action, expects-video and prewarm flags,
 *   stamped with a caller-supplied monotonic millisecond clock. The clock
 *   is an explicit parameter so tests can drive time deterministically;
 *   production passes CACurrentMediaTime() * 1000.
 * - first-audio / first-video are milestone marks. A repeated first-video
 *   for the same attempt is ignored (no double counting). Marks carrying a
 *   stale attempt id or generation (an old callback arriving after a newer
 *   attempt began) are ignored and counted as stale_ignored.
 * - failed (with a failure stage) and cancelled are terminal. Cancelled
 *   attempts are counted in their own column and excluded from the
 *   success-rate denominator: success / (success + failed).
 * - Latencies feed bounded bucket histograms (no unbounded sample lists);
 *   P50/P95 come from the buckets. Counters are cumulative totals; the
 *   per-attempt ring (128 entries) is only a recent window and evicting
 *   an old record never rewrites a counter or a histogram bucket.
 * - Prewarmed launches are counted but their latencies are excluded from
 *   the histograms (audit: remove the prewarm influence).
 * - No I/O, no allocation, no strings: identifiers are uint64 hashes
 *   (FNV-1a, see HostPerfLedgerHashString) of the UUID/revision strings
 *   the ObjC layer passes in, so no URL, header or media content can
 *   enter this ledger by construction.
 */
#ifndef HOST_PERF_ATTEMPT_LEDGER_H
#define HOST_PERF_ATTEMPT_LEDGER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Fixed capacity of the recent-attempt ring (recent window only). */
#define HOST_PERF_LEDGER_MAX_ATTEMPTS 128
/* Latency histogram bucket count; last bucket is open-ended. */
#define HOST_PERF_LEDGER_HISTOGRAM_BUCKETS 11
/* Number of failure-stage slots (indexed by HostPerfFailureStage). */
#define HOST_PERF_LEDGER_STAGE_SLOTS 9
/* Engine slots in the stats arrays: one per engine + one overall slot. */
#define HOST_PERF_LEDGER_ENGINE_SLOTS 6

/* Upper edge (ms) of each histogram bucket; the last edge is open-ended. */
extern const int64_t HostPerfLedgerBucketEdgesMs[HOST_PERF_LEDGER_HISTOGRAM_BUCKETS];

typedef enum {
    HostPerfEngineUnknown = 0,
    HostPerfEngineAVPlayer = 1,
    HostPerfEngineCicada = 2,
    HostPerfEngineMPV = 3,
    HostPerfEngineCNPlayer = 4
} HostPerfEngine;

typedef enum {
    HostPerfStageNone = 0,
    HostPerfStageSetup = 1,
    HostPerfStagePrepare = 2,
    HostPerfStageNetwork = 3,
    HostPerfStageAuth = 4,
    HostPerfStageTimeout = 5,
    HostPerfStageService = 6,
    HostPerfStagePlayback = 7,
    HostPerfStageUnknown = 8
} HostPerfFailureStage;

typedef enum {
    HostPerfAttemptPending = 0,
    HostPerfAttemptSuccessVideo = 1,
    HostPerfAttemptSuccessAudio = 2,
    HostPerfAttemptFailed = 3,
    HostPerfAttemptCancelled = 4
} HostPerfAttemptState;

typedef enum {
    HostPerfActionSelect = 0,
    HostPerfActionRetry = 1,
    HostPerfActionAutoRecovery = 2,
    HostPerfActionResume = 3,
    HostPerfActionUnknown = 4
} HostPerfUserAction;

typedef struct {
    uint64_t session_id;
    uint64_t attempt_id;
    uint64_t generation;
    uint64_t source_revision;
    int64_t started_ms;
    int64_t first_audio_ms; /* -1 when not yet observed */
    int64_t first_video_ms; /* -1 when not yet observed */
    HostPerfEngine engine;
    HostPerfUserAction action;
    HostPerfAttemptState state;
    HostPerfFailureStage failure_stage;
    int expects_video;
    int prewarmed;
    /* Set when a newer attempt began for the same session: late callbacks
     * for this attempt are stale even when their generation matches. */
    int superseded;
} HostPerfAttemptRecord;

typedef struct {
    uint64_t count;
    uint64_t total_ms;
    int64_t min_ms; /* -1 when empty */
    int64_t max_ms; /* -1 when empty */
    uint64_t buckets[HOST_PERF_LEDGER_HISTOGRAM_BUCKETS];
} HostPerfLatencyStats;

typedef struct {
    HostPerfAttemptRecord attempts[HOST_PERF_LEDGER_MAX_ATTEMPTS];
    size_t count;     /* records currently in the ring (<= MAX) */
    size_t next_slot; /* ring write position */
    uint64_t stale_ignored;
    uint64_t duplicate_ignored;
    uint64_t started;
    uint64_t success_video;
    uint64_t success_audio;
    uint64_t failed;
    uint64_t cancelled;
    uint64_t failed_by_stage[HOST_PERF_LEDGER_STAGE_SLOTS];
    /* Per-engine latency stats, indexed by HostPerfEngine; the last slot
     * (index HOST_PERF_LEDGER_ENGINE_SLOTS - 1) is the overall aggregate. */
    HostPerfLatencyStats video[HOST_PERF_LEDGER_ENGINE_SLOTS];
    HostPerfLatencyStats audio[HOST_PERF_LEDGER_ENGINE_SLOTS];
} HostPerfAttemptLedger;

void HostPerfLedgerInit(HostPerfAttemptLedger *ledger);

/* Start an attempt. Returns 1 when recorded, 0 when an attempt with the
 * same (session_id, attempt_id) is already known (duplicate begin). */
int HostPerfLedgerBegin(HostPerfAttemptLedger *ledger,
                        uint64_t session_id, uint64_t attempt_id,
                        uint64_t generation, uint64_t source_revision,
                        HostPerfEngine engine, HostPerfUserAction action,
                        int expects_video, int prewarmed, int64_t now_ms);

/* Milestone / terminal marks. Each returns 1 when it changed the attempt,
 * 0 when ignored (stale identity, duplicate milestone, or attempt already
 * terminal). `engine` updates the record's engine when it is still
 * Unknown (the engine is often only known once playback starts). */
int HostPerfLedgerMarkFirstAudio(HostPerfAttemptLedger *ledger,
                                 uint64_t session_id, uint64_t attempt_id,
                                 uint64_t generation, HostPerfEngine engine,
                                 int64_t now_ms);
int HostPerfLedgerMarkFirstVideo(HostPerfAttemptLedger *ledger,
                                 uint64_t session_id, uint64_t attempt_id,
                                 uint64_t generation, HostPerfEngine engine,
                                 int64_t now_ms);
int HostPerfLedgerMarkFailed(HostPerfAttemptLedger *ledger,
                             uint64_t session_id, uint64_t attempt_id,
                             uint64_t generation, HostPerfEngine engine,
                             HostPerfFailureStage stage, int64_t now_ms);
int HostPerfLedgerMarkCancelled(HostPerfAttemptLedger *ledger,
                                uint64_t session_id, uint64_t attempt_id,
                                uint64_t generation, int64_t now_ms);

/* Quantile (0 < q <= 1) of a latency histogram via linear interpolation
 * inside the bucket holding the quantile. Returns -1 when empty. */
int64_t HostPerfLedgerQuantileMs(const HostPerfLatencyStats *stats, double q);

/* Success rate over terminal attempts: success / (success + failed).
 * Cancelled attempts are NOT in the denominator. Returns -1 when there
 * are no terminal success/failed attempts yet. */
double HostPerfLedgerSuccessRate(const HostPerfAttemptLedger *ledger);

/* FNV-1a 64-bit hash for UUID / revision strings passed in from ObjC.
 * Deterministic; used so the ledger stores no strings at all. */
uint64_t HostPerfLedgerHashString(const char *s);

#ifdef __cplusplus
}
#endif

#endif /* HOST_PERF_ATTEMPT_LEDGER_H */
