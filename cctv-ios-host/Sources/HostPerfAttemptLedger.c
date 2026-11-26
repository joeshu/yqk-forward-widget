/* HostPerfAttemptLedger.c — bounded playback-attempt accounting (pure C).
 * See the header for the model. No I/O, no allocation, no strings. */
#include "HostPerfAttemptLedger.h"

#include <string.h>

const int64_t HostPerfLedgerBucketEdgesMs[HOST_PERF_LEDGER_HISTOGRAM_BUCKETS] = {
    100, 250, 500, 1000, 2000, 3000, 5000, 10000, 30000, 60000,
    INT64_MAX /* open-ended bucket */
};

static void stats_init(HostPerfLatencyStats *stats) {
    memset(stats, 0, sizeof(*stats));
    stats->min_ms = -1;
    stats->max_ms = -1;
}

void HostPerfLedgerInit(HostPerfAttemptLedger *ledger) {
    size_t i;
    if (!ledger) return;
    memset(ledger, 0, sizeof(*ledger));
    for (i = 0; i < HOST_PERF_LEDGER_ENGINE_SLOTS; i++) {
        stats_init(&ledger->video[i]);
        stats_init(&ledger->audio[i]);
    }
}

uint64_t HostPerfLedgerHashString(const char *s) {
    /* FNV-1a 64-bit. */
    uint64_t hash = 14695981039346656037ULL;
    const unsigned char *p = (const unsigned char *)s;
    if (!s) return 0;
    while (*p) {
        hash ^= (uint64_t)*p++;
        hash *= 1099511628211ULL;
    }
    return hash;
}

static HostPerfAttemptRecord *find_attempt(HostPerfAttemptLedger *ledger,
                                           uint64_t session_id,
                                           uint64_t attempt_id) {
    size_t i;
    for (i = 0; i < ledger->count; i++) {
        HostPerfAttemptRecord *r = &ledger->attempts[i];
        if (r->session_id == session_id && r->attempt_id == attempt_id) return r;
    }
    return NULL;
}

/* The current attempt of a session is its most recently begun one. A mark
 * belongs to it only when session, attempt id AND generation all match and
 * no newer attempt for the session has superseded it. */
static HostPerfAttemptRecord *current_attempt(HostPerfAttemptLedger *ledger,
                                              uint64_t session_id,
                                              uint64_t attempt_id,
                                              uint64_t generation) {
    HostPerfAttemptRecord *r = find_attempt(ledger, session_id, attempt_id);
    if (!r) return NULL;
    if (r->superseded) return NULL;
    if (r->generation != generation) return NULL;
    return r;
}

static void stats_add(HostPerfLatencyStats *stats, int64_t latency_ms) {
    int b;
    if (latency_ms < 0) latency_ms = 0;
    stats->count++;
    stats->total_ms += (uint64_t)latency_ms;
    if (stats->min_ms < 0 || latency_ms < stats->min_ms) stats->min_ms = latency_ms;
    if (stats->max_ms < 0 || latency_ms > stats->max_ms) stats->max_ms = latency_ms;
    for (b = 0; b < HOST_PERF_LEDGER_HISTOGRAM_BUCKETS; b++) {
        if (latency_ms <= HostPerfLedgerBucketEdgesMs[b]) {
            stats->buckets[b]++;
            break;
        }
    }
}

static void stats_add_for_engine(HostPerfLatencyStats (*table)[HOST_PERF_LEDGER_ENGINE_SLOTS],
                                   HostPerfEngine engine, int64_t latency_ms) {
    int slot = (engine >= HostPerfEngineUnknown && engine <= HostPerfEngineCNPlayer)
                   ? (int)engine
                   : (int)HostPerfEngineUnknown;
    stats_add(&(*table)[slot], latency_ms);
    stats_add(&(*table)[HOST_PERF_LEDGER_ENGINE_SLOTS - 1], latency_ms);
}

int HostPerfLedgerBegin(HostPerfAttemptLedger *ledger,
                        uint64_t session_id, uint64_t attempt_id,
                        uint64_t generation, uint64_t source_revision,
                        HostPerfEngine engine, HostPerfUserAction action,
                        int expects_video, int prewarmed, int64_t now_ms) {
    HostPerfAttemptRecord *r;
    size_t i;
    if (!ledger) return 0;
    if (find_attempt(ledger, session_id, attempt_id)) return 0; /* duplicate begin */
    /* A newer attempt supersedes every earlier attempt of the same session:
     * their late callbacks are stale from here on. */
    for (i = 0; i < ledger->count; i++) {
        if (ledger->attempts[i].session_id == session_id)
            ledger->attempts[i].superseded = 1;
    }
    r = &ledger->attempts[ledger->next_slot];
    memset(r, 0, sizeof(*r));
    r->session_id = session_id;
    r->attempt_id = attempt_id;
    r->generation = generation;
    r->source_revision = source_revision;
    r->started_ms = now_ms;
    r->first_audio_ms = -1;
    r->first_video_ms = -1;
    r->engine = engine;
    r->action = action;
    r->state = HostPerfAttemptPending;
    r->failure_stage = HostPerfStageNone;
    r->expects_video = expects_video ? 1 : 0;
    r->prewarmed = prewarmed ? 1 : 0;
    ledger->next_slot = (ledger->next_slot + 1) % HOST_PERF_LEDGER_MAX_ATTEMPTS;
    if (ledger->count < HOST_PERF_LEDGER_MAX_ATTEMPTS) ledger->count++;
    ledger->started++;
    return 1;
}

static void adopt_engine(HostPerfAttemptRecord *r, HostPerfEngine engine) {
    if (r->engine == HostPerfEngineUnknown && engine != HostPerfEngineUnknown)
        r->engine = engine;
}

int HostPerfLedgerMarkFirstAudio(HostPerfAttemptLedger *ledger,
                                 uint64_t session_id, uint64_t attempt_id,
                                 uint64_t generation, HostPerfEngine engine,
                                 int64_t now_ms) {
    HostPerfAttemptRecord *r;
    int64_t latency_ms;
    if (!ledger) return 0;
    r = current_attempt(ledger, session_id, attempt_id, generation);
    if (!r) { ledger->stale_ignored++; return 0; }
    if (r->state != HostPerfAttemptPending) { ledger->duplicate_ignored++; return 0; }
    if (r->first_audio_ms >= 0) { ledger->duplicate_ignored++; return 0; }
    adopt_engine(r, engine);
    latency_ms = now_ms - r->started_ms;
    if (latency_ms < 0) latency_ms = 0;
    r->first_audio_ms = latency_ms;
    if (!r->prewarmed)
        stats_add_for_engine(&ledger->audio, r->engine, latency_ms);
    if (!r->expects_video) {
        r->state = HostPerfAttemptSuccessAudio;
        ledger->success_audio++;
    }
    return 1;
}

int HostPerfLedgerMarkFirstVideo(HostPerfAttemptLedger *ledger,
                                 uint64_t session_id, uint64_t attempt_id,
                                 uint64_t generation, HostPerfEngine engine,
                                 int64_t now_ms) {
    HostPerfAttemptRecord *r;
    int64_t latency_ms;
    if (!ledger) return 0;
    r = current_attempt(ledger, session_id, attempt_id, generation);
    if (!r) { ledger->stale_ignored++; return 0; }
    if (r->state != HostPerfAttemptPending) { ledger->duplicate_ignored++; return 0; }
    if (r->first_video_ms >= 0) { ledger->duplicate_ignored++; return 0; }
    adopt_engine(r, engine);
    latency_ms = now_ms - r->started_ms;
    if (latency_ms < 0) latency_ms = 0;
    r->first_video_ms = latency_ms;
    if (!r->prewarmed)
        stats_add_for_engine(&ledger->video, r->engine, latency_ms);
    r->state = HostPerfAttemptSuccessVideo;
    ledger->success_video++;
    return 1;
}

int HostPerfLedgerMarkFailed(HostPerfAttemptLedger *ledger,
                             uint64_t session_id, uint64_t attempt_id,
                             uint64_t generation, HostPerfEngine engine,
                             HostPerfFailureStage stage, int64_t now_ms) {
    HostPerfAttemptRecord *r;
    (void)now_ms;
    if (!ledger) return 0;
    r = current_attempt(ledger, session_id, attempt_id, generation);
    if (!r) { ledger->stale_ignored++; return 0; }
    if (r->state != HostPerfAttemptPending) { ledger->duplicate_ignored++; return 0; }
    adopt_engine(r, engine);
    r->state = HostPerfAttemptFailed;
    r->failure_stage = stage;
    ledger->failed++;
    if (stage >= 0 && stage < HOST_PERF_LEDGER_STAGE_SLOTS)
        ledger->failed_by_stage[stage]++;
    return 1;
}

int HostPerfLedgerMarkCancelled(HostPerfAttemptLedger *ledger,
                                uint64_t session_id, uint64_t attempt_id,
                                uint64_t generation, int64_t now_ms) {
    HostPerfAttemptRecord *r;
    (void)now_ms;
    if (!ledger) return 0;
    r = current_attempt(ledger, session_id, attempt_id, generation);
    if (!r) { ledger->stale_ignored++; return 0; }
    if (r->state != HostPerfAttemptPending) { ledger->duplicate_ignored++; return 0; }
    r->state = HostPerfAttemptCancelled;
    ledger->cancelled++;
    return 1;
}

int64_t HostPerfLedgerQuantileMs(const HostPerfLatencyStats *stats, double q) {
    uint64_t target, cumulative = 0;
    int b;
    int64_t lower;
    if (!stats || stats->count == 0 || q <= 0.0 || q > 1.0) return -1;
    /* Smallest rank reaching the quantile (1-based, ceiling). */
    target = (uint64_t)(q * (double)stats->count);
    if ((double)target < q * (double)stats->count) target++;
    if (target < 1) target = 1;
    lower = 0;
    for (b = 0; b < HOST_PERF_LEDGER_HISTOGRAM_BUCKETS; b++) {
        uint64_t bucket_count = stats->buckets[b];
        int64_t upper = HostPerfLedgerBucketEdgesMs[b];
        if (bucket_count == 0) continue;
        if (cumulative + bucket_count >= target) {
            uint64_t within = target - cumulative; /* 1..bucket_count */
            double fraction = (double)within / (double)bucket_count;
            if (upper == INT64_MAX) return lower; /* open-ended: report edge */
            return lower + (int64_t)(fraction * (double)(upper - lower));
        }
        cumulative += bucket_count;
        lower = upper;
    }
    return stats->max_ms;
}

double HostPerfLedgerSuccessRate(const HostPerfAttemptLedger *ledger) {
    uint64_t terminal;
    if (!ledger) return -1.0;
    terminal = ledger->success_video + ledger->success_audio + ledger->failed;
    if (terminal == 0) return -1.0;
    return (double)(ledger->success_video + ledger->success_audio) / (double)terminal;
}
