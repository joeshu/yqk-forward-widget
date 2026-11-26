/* native_perf_ledger_tests.c — scripted harness for HostPerfAttemptLedger.
 *
 * Test double for T01: a controllable monotonic clock (explicit `now_ms`
 * values) plus a fake engine / event emitter (scripted begin / first-audio /
 * first-video / failed / cancelled calls, including duplicate and stale
 * callbacks and a cancel-then-retry sequence). Prints one `RESULT <name>
 * <key>=<value> ...` line per scenario and exits non-zero on any failed
 * check. Performs no file I/O by design.
 *
 * Built and driven by Tests/test_perf_metrics_attempt_accounting.py with
 * the system C compiler (cc) so the production ledger code executes on
 * Linux as well as on macOS.
 */
#include "HostPerfAttemptLedger.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        printf("FAILED: "); printf(__VA_ARGS__); printf("\n"); \
        failures++; \
    } \
} while (0)

static void scenario_quantiles(void) {
    HostPerfAttemptLedger ledger;
    int64_t p50, p95;
    const HostPerfLatencyStats *overall;
    int i;
    HostPerfLedgerInit(&ledger);
    for (i = 1; i <= 100; i++) {
        uint64_t attempt = 1000u + (uint64_t)i;
        HostPerfLedgerBegin(&ledger, 1, attempt, 1, 7,
                            HostPerfEngineAVPlayer, HostPerfActionSelect,
                            1, 0, 0);
        HostPerfLedgerMarkFirstVideo(&ledger, 1, attempt, 1,
                                     HostPerfEngineAVPlayer, i * 100);
    }
    overall = &ledger.video[HOST_PERF_LEDGER_ENGINE_SLOTS - 1];
    p50 = HostPerfLedgerQuantileMs(overall, 0.50);
    p95 = HostPerfLedgerQuantileMs(overall, 0.95);
    CHECK(p50 == 5000, "quantiles p50 expected 5000 got %lld", (long long)p50);
    CHECK(p95 == 9500, "quantiles p95 expected 9500 got %lld", (long long)p95);
    CHECK(overall->count == 100, "quantiles count expected 100 got %llu",
          (unsigned long long)overall->count);
    CHECK(overall->min_ms == 100, "quantiles min expected 100 got %lld",
          (long long)overall->min_ms);
    CHECK(overall->max_ms == 10000, "quantiles max expected 10000 got %lld",
          (long long)overall->max_ms);
    CHECK(overall->total_ms / overall->count == 5050,
          "quantiles avg expected 5050 got %llu",
          (unsigned long long)(overall->total_ms / overall->count));
    printf("RESULT quantiles p50=%lld p95=%lld count=%llu min=%lld max=%lld avg=%llu\n",
           (long long)p50, (long long)p95,
           (unsigned long long)overall->count,
           (long long)overall->min_ms, (long long)overall->max_ms,
           (unsigned long long)(overall->total_ms / overall->count));
}

static void scenario_success_rate(void) {
    HostPerfAttemptLedger ledger;
    double rate;
    int i;
    HostPerfLedgerInit(&ledger);
    for (i = 1; i <= 7; i++) {
        HostPerfLedgerBegin(&ledger, 1, 2000u + (uint64_t)i, 1, 7,
                            HostPerfEngineAVPlayer, HostPerfActionSelect,
                            1, 0, 0);
        HostPerfLedgerMarkFirstVideo(&ledger, 1, 2000u + (uint64_t)i, 1,
                                     HostPerfEngineAVPlayer, 1000);
    }
    for (i = 1; i <= 2; i++) {
        HostPerfLedgerBegin(&ledger, 1, 2100u + (uint64_t)i, 1, 7,
                            HostPerfEngineCicada, HostPerfActionSelect,
                            1, 0, 0);
        HostPerfLedgerMarkFailed(&ledger, 1, 2100u + (uint64_t)i, 1,
                                 HostPerfEngineCicada,
                                 i == 1 ? HostPerfStageNetwork : HostPerfStageTimeout,
                                 500);
    }
    HostPerfLedgerBegin(&ledger, 1, 2201, 1, 7, HostPerfEngineMPV,
                        HostPerfActionSelect, 1, 0, 0);
    HostPerfLedgerMarkCancelled(&ledger, 1, 2201, 1, 0);
    rate = HostPerfLedgerSuccessRate(&ledger);
    CHECK(ledger.started == 10, "success_rate started expected 10 got %llu",
          (unsigned long long)ledger.started);
    CHECK(ledger.success_video == 7, "success_rate success expected 7 got %llu",
          (unsigned long long)ledger.success_video);
    CHECK(ledger.failed == 2, "success_rate failed expected 2 got %llu",
          (unsigned long long)ledger.failed);
    CHECK(ledger.cancelled == 1, "success_rate cancelled expected 1 got %llu",
          (unsigned long long)ledger.cancelled);
    /* 7 / (7 + 2) = 0.777...; cancelled is NOT in the denominator. */
    CHECK(rate > 0.777 && rate < 0.778, "success_rate expected 7/9 got %f", rate);
    CHECK(ledger.failed_by_stage[HostPerfStageNetwork] == 1,
          "success_rate network failures expected 1");
    CHECK(ledger.failed_by_stage[HostPerfStageTimeout] == 1,
          "success_rate timeout failures expected 1");
    printf("RESULT success_rate started=%llu success=%llu failed=%llu cancelled=%llu rate_milli=%d\n",
           (unsigned long long)ledger.started,
           (unsigned long long)ledger.success_video,
           (unsigned long long)ledger.failed,
           (unsigned long long)ledger.cancelled,
           (int)(rate * 1000.0));
}

static void scenario_duplicate_first_video(void) {
    HostPerfAttemptLedger ledger;
    int first, second;
    HostPerfLedgerInit(&ledger);
    HostPerfLedgerBegin(&ledger, 1, 3001, 1, 7, HostPerfEngineAVPlayer,
                        HostPerfActionSelect, 1, 0, 0);
    first = HostPerfLedgerMarkFirstVideo(&ledger, 1, 3001, 1,
                                         HostPerfEngineAVPlayer, 800);
    second = HostPerfLedgerMarkFirstVideo(&ledger, 1, 3001, 1,
                                          HostPerfEngineAVPlayer, 900);
    CHECK(first == 1, "duplicate first video: first mark must count");
    CHECK(second == 0, "duplicate first video: second mark must be ignored");
    CHECK(ledger.success_video == 1, "duplicate first video: success must be 1");
    CHECK(ledger.duplicate_ignored == 1, "duplicate first video: duplicate_ignored must be 1");
    printf("RESULT duplicate_first_video success=%llu duplicate_ignored=%llu\n",
           (unsigned long long)ledger.success_video,
           (unsigned long long)ledger.duplicate_ignored);
}

static void scenario_stale_callback(void) {
    HostPerfAttemptLedger ledger;
    int stale_video, stale_generation, fresh_video;
    HostPerfLedgerInit(&ledger);
    HostPerfLedgerBegin(&ledger, 5, 4001, 1, 7, HostPerfEngineAVPlayer,
                        HostPerfActionSelect, 1, 0, 1000);
    HostPerfLedgerBegin(&ledger, 5, 4002, 2, 7, HostPerfEngineAVPlayer,
                        HostPerfActionSelect, 1, 0, 2000);
    /* Old attempt's late first video must not count for the new attempt. */
    stale_video = HostPerfLedgerMarkFirstVideo(&ledger, 5, 4001, 1,
                                               HostPerfEngineAVPlayer, 2500);
    /* Right attempt id, wrong (old) generation must not count either. */
    stale_generation = HostPerfLedgerMarkFirstVideo(&ledger, 5, 4002, 1,
                                                    HostPerfEngineAVPlayer, 2500);
    fresh_video = HostPerfLedgerMarkFirstVideo(&ledger, 5, 4002, 2,
                                               HostPerfEngineAVPlayer, 2600);
    CHECK(stale_video == 0, "stale callback: old attempt mark must be ignored");
    CHECK(stale_generation == 0, "stale callback: old generation mark must be ignored");
    CHECK(fresh_video == 1, "stale callback: current attempt mark must count");
    CHECK(ledger.stale_ignored == 2, "stale callback: stale_ignored must be 2 got %llu",
          (unsigned long long)ledger.stale_ignored);
    CHECK(ledger.success_video == 1, "stale callback: success must be 1");
    printf("RESULT stale_callback stale_ignored=%llu success=%llu\n",
           (unsigned long long)ledger.stale_ignored,
           (unsigned long long)ledger.success_video);
}

static void scenario_cancel_terminal(void) {
    HostPerfAttemptLedger ledger;
    int late_video;
    HostPerfLedgerInit(&ledger);
    HostPerfLedgerBegin(&ledger, 1, 5001, 1, 7, HostPerfEngineAVPlayer,
                        HostPerfActionSelect, 1, 0, 0);
    HostPerfLedgerMarkCancelled(&ledger, 1, 5001, 1, 400);
    late_video = HostPerfLedgerMarkFirstVideo(&ledger, 1, 5001, 1,
                                              HostPerfEngineAVPlayer, 900);
    CHECK(late_video == 0, "cancel terminal: late first video must be ignored");
    CHECK(ledger.cancelled == 1, "cancel terminal: cancelled must be 1");
    CHECK(ledger.success_video == 0, "cancel terminal: success must be 0");
    printf("RESULT cancel_terminal cancelled=%llu success=%llu\n",
           (unsigned long long)ledger.cancelled,
           (unsigned long long)ledger.success_video);
}

static void scenario_audio_only(void) {
    HostPerfAttemptLedger ledger;
    HostPerfLedgerInit(&ledger);
    /* Audio-only media: first audio is the success signal. */
    HostPerfLedgerBegin(&ledger, 1, 6001, 1, 7, HostPerfEngineAVPlayer,
                        HostPerfActionSelect, 0, 0, 0);
    HostPerfLedgerMarkFirstAudio(&ledger, 1, 6001, 1, HostPerfEngineAVPlayer, 300);
    /* Video media with audio only so far: still pending, not a success. */
    HostPerfLedgerBegin(&ledger, 1, 6002, 1, 7, HostPerfEngineAVPlayer,
                        HostPerfActionSelect, 1, 0, 0);
    HostPerfLedgerMarkFirstAudio(&ledger, 1, 6002, 1, HostPerfEngineAVPlayer, 300);
    CHECK(ledger.success_audio == 1, "audio only: success_audio must be 1 got %llu",
          (unsigned long long)ledger.success_audio);
    CHECK(ledger.success_video == 0, "audio only: success_video must be 0");
    CHECK(ledger.started == 2, "audio only: started must be 2");
    printf("RESULT audio_only success_audio=%llu success_video=%llu started=%llu\n",
           (unsigned long long)ledger.success_audio,
           (unsigned long long)ledger.success_video,
           (unsigned long long)ledger.started);
}

static void scenario_prewarm_excluded(void) {
    HostPerfAttemptLedger ledger;
    int64_t p50;
    const HostPerfLatencyStats *overall;
    HostPerfLedgerInit(&ledger);
    HostPerfLedgerBegin(&ledger, 1, 7001, 1, 7, HostPerfEngineAVPlayer,
                        HostPerfActionSelect, 1, 1, 0);
    HostPerfLedgerMarkFirstVideo(&ledger, 1, 7001, 1, HostPerfEngineAVPlayer, 50);
    HostPerfLedgerBegin(&ledger, 1, 7002, 1, 7, HostPerfEngineAVPlayer,
                        HostPerfActionSelect, 1, 0, 0);
    HostPerfLedgerMarkFirstVideo(&ledger, 1, 7002, 1, HostPerfEngineAVPlayer, 5000);
    overall = &ledger.video[HOST_PERF_LEDGER_ENGINE_SLOTS - 1];
    p50 = HostPerfLedgerQuantileMs(overall, 0.50);
    CHECK(overall->count == 1, "prewarm: histogram must hold only the cold sample");
    CHECK(p50 == 5000, "prewarm: p50 must be 5000 got %lld", (long long)p50);
    CHECK(ledger.started == 2, "prewarm: started must still count both attempts");
    CHECK(ledger.success_video == 2, "prewarm: success must count both attempts");
    printf("RESULT prewarm_excluded histogram_count=%llu p50=%lld started=%llu\n",
           (unsigned long long)overall->count, (long long)p50,
           (unsigned long long)ledger.started);
}

static void scenario_ring_bounded(void) {
    HostPerfAttemptLedger ledger;
    int i;
    HostPerfLedgerInit(&ledger);
    for (i = 1; i <= 200; i++) {
        HostPerfLedgerBegin(&ledger, 1, 8000u + (uint64_t)i, 1, 7,
                            HostPerfEngineAVPlayer, HostPerfActionSelect,
                            1, 0, 0);
    }
    CHECK(ledger.count == HOST_PERF_LEDGER_MAX_ATTEMPTS,
          "ring: count must stay at capacity %d got %lu",
          HOST_PERF_LEDGER_MAX_ATTEMPTS, (unsigned long)ledger.count);
    CHECK(ledger.started == 200, "ring: started must be 200");
    printf("RESULT ring_bounded ring_count=%lu started=%llu capacity=%d\n",
           (unsigned long)ledger.count,
           (unsigned long long)ledger.started,
           HOST_PERF_LEDGER_MAX_ATTEMPTS);
}

static void scenario_engine_split_and_retry(void) {
    HostPerfAttemptLedger ledger;
    HostPerfLedgerInit(&ledger);
    /* Three AVPlayer successes, two Cicada successes. */
    HostPerfLedgerBegin(&ledger, 1, 9001, 1, 7, HostPerfEngineAVPlayer,
                        HostPerfActionSelect, 1, 0, 0);
    HostPerfLedgerMarkFirstVideo(&ledger, 1, 9001, 1, HostPerfEngineAVPlayer, 1200);
    HostPerfLedgerBegin(&ledger, 1, 9002, 1, 7, HostPerfEngineAVPlayer,
                        HostPerfActionSelect, 1, 0, 0);
    HostPerfLedgerMarkFirstVideo(&ledger, 1, 9002, 1, HostPerfEngineAVPlayer, 900);
    HostPerfLedgerBegin(&ledger, 1, 9003, 1, 7, HostPerfEngineAVPlayer,
                        HostPerfActionSelect, 1, 0, 0);
    HostPerfLedgerMarkFirstVideo(&ledger, 1, 9003, 1, HostPerfEngineAVPlayer, 1500);
    HostPerfLedgerBegin(&ledger, 1, 9004, 1, 7, HostPerfEngineCicada,
                        HostPerfActionSelect, 1, 0, 0);
    HostPerfLedgerMarkFirstVideo(&ledger, 1, 9004, 1, HostPerfEngineCicada, 2000);
    HostPerfLedgerBegin(&ledger, 1, 9005, 1, 7, HostPerfEngineCicada,
                        HostPerfActionSelect, 1, 0, 0);
    HostPerfLedgerMarkFirstVideo(&ledger, 1, 9005, 1, HostPerfEngineCicada, 1800);
    /* Cancel-then-retry: attempt 9010 fails, attempt 9011 (new id, gen 2) succeeds. */
    HostPerfLedgerBegin(&ledger, 2, 9010, 1, 9, HostPerfEngineAVPlayer,
                        HostPerfActionSelect, 1, 0, 0);
    HostPerfLedgerMarkFailed(&ledger, 2, 9010, 1, HostPerfEngineAVPlayer,
                             HostPerfStageNetwork, 700);
    HostPerfLedgerBegin(&ledger, 2, 9011, 2, 9, HostPerfEngineAVPlayer,
                        HostPerfActionRetry, 1, 0, 1000);
    HostPerfLedgerMarkFirstVideo(&ledger, 2, 9011, 2, HostPerfEngineAVPlayer, 2200);
    CHECK(ledger.video[HostPerfEngineAVPlayer].count == 4,
          "engine split: AVPlayer video count must be 4 got %llu",
          (unsigned long long)ledger.video[HostPerfEngineAVPlayer].count);
    CHECK(ledger.video[HostPerfEngineCicada].count == 2,
          "engine split: Cicada video count must be 2 got %llu",
          (unsigned long long)ledger.video[HostPerfEngineCicada].count);
    CHECK(ledger.success_video == 6, "retry: success must be 6 got %llu",
          (unsigned long long)ledger.success_video);
    CHECK(ledger.failed == 1, "retry: failed must be 1");
    printf("RESULT engine_split avplayer=%llu cicada=%llu success=%llu failed=%llu\n",
           (unsigned long long)ledger.video[HostPerfEngineAVPlayer].count,
           (unsigned long long)ledger.video[HostPerfEngineCicada].count,
           (unsigned long long)ledger.success_video,
           (unsigned long long)ledger.failed);
}

static void scenario_hash(void) {
    uint64_t a = HostPerfLedgerHashString("attempt-uuid-1");
    uint64_t b = HostPerfLedgerHashString("attempt-uuid-1");
    uint64_t c = HostPerfLedgerHashString("attempt-uuid-2");
    uint64_t d = HostPerfLedgerHashString("revision-42");
    CHECK(a == b, "hash: same string must hash identically");
    CHECK(a != c, "hash: different strings must (almost surely) differ");
    CHECK(d != 0, "hash: non-empty string must not hash to zero");
    printf("RESULT hash deterministic=1\n");
}

int main(void) {
    scenario_quantiles();
    scenario_success_rate();
    scenario_duplicate_first_video();
    scenario_stale_callback();
    scenario_cancel_terminal();
    scenario_audio_only();
    scenario_prewarm_excluded();
    scenario_ring_bounded();
    scenario_engine_split_and_retry();
    scenario_hash();
    if (failures) {
        printf("HARNESS FAILED: %d check(s)\n", failures);
        return 1;
    }
    printf("HARNESS OK\n");
    return 0;
}
