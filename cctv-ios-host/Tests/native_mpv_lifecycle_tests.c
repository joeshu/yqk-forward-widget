/* native_mpv_lifecycle_tests.c
 *
 * Test doubles for the T02 (S1) MPV lifecycle core
 * (Sources/HostMPVLifecycle.c): a fake mpv_wait_event consumer thread
 * (blocks in a 250ms timed wait, like wait_event(ctx, 0.25), and exits
 * when told) plus scripted destroy races. No I/O, no files.
 *
 * Prints one `RESULT <scenario> <key>=<value> ...` line per scenario;
 * any failed check exits 1. Timing is measured with CLOCK_MONOTONIC.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>

#include "HostMPVLifecycle.h"

static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: " __VA_ARGS__); \
        fprintf(stderr, "\n"); \
        failures++; \
    } \
} while (0)

static long now_ms(void) {
    struct timespec ts;
    (void)clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)(ts.tv_sec * 1000L + ts.tv_nsec / 1000000L);
}

/* ---- fake event consumer: mirrors wait_event(ctx, 0.25) ---- */
typedef struct {
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    int stop_requested;   /* destroy asked the consumer to leave */
    int ignore_stop;      /* stuck-consumer model: never leaves */
    int started;
    host_mpv_lifecycle_t *lc;
    long exit_seq;        /* global sequence number at exit, -1 if never */
} fake_consumer_t;

static long global_seq = 0;
static pthread_mutex_t seq_mutex = PTHREAD_MUTEX_INITIALIZER;

static long next_seq(void) {
    long s;
    (void)pthread_mutex_lock(&seq_mutex);
    s = ++global_seq;
    (void)pthread_mutex_unlock(&seq_mutex);
    return s;
}

static void *fake_consumer_main(void *arg) {
    fake_consumer_t *c = (fake_consumer_t *)arg;
    (void)pthread_mutex_lock(&c->mutex);
    c->started = 1;
    while (!c->stop_requested || c->ignore_stop) {
        struct timespec deadline;
        (void)clock_gettime(CLOCK_MONOTONIC, &deadline);
        deadline.tv_nsec += 250 * 1000000L;
        if (deadline.tv_nsec >= 1000000000L) {
            deadline.tv_sec += 1;
            deadline.tv_nsec -= 1000000000L;
        }
        (void)pthread_cond_timedwait(&c->cond, &c->mutex, &deadline);
    }
    (void)pthread_mutex_unlock(&c->mutex);
    /* Exit handshake: exactly once, before touching the handle again. */
    host_mpv_lifecycle_note_event_thread_exited(c->lc);
    c->exit_seq = next_seq();
    return NULL;
}

static void fake_consumer_start(fake_consumer_t *c, host_mpv_lifecycle_t *lc, int ignore_stop) {
    memset(c, 0, sizeof(*c));
    c->lc = lc;
    c->ignore_stop = ignore_stop;
    c->exit_seq = -1;
    (void)pthread_mutex_init(&c->mutex, NULL);
    (void)pthread_cond_init(&c->cond, NULL);
    host_mpv_lifecycle_note_event_thread_started(lc);
    if (pthread_create(&c->thread, NULL, fake_consumer_main, c) != 0) {
        fprintf(stderr, "FAIL: pthread_create\n");
        failures++;
    }
}

static void fake_consumer_request_stop(fake_consumer_t *c) {
    (void)pthread_mutex_lock(&c->mutex);
    c->stop_requested = 1;
    (void)pthread_cond_signal(&c->cond);
    (void)pthread_mutex_unlock(&c->mutex);
}

static void fake_consumer_join(fake_consumer_t *c) {
    (void)pthread_join(c->thread, NULL);
    (void)pthread_cond_destroy(&c->cond);
    (void)pthread_mutex_destroy(&c->mutex);
}

/* ---- scenarios ---- */

static void scenario_prepare_once(void) {
    host_mpv_lifecycle_t *lc = host_mpv_lifecycle_create();
    int prepared = host_mpv_lifecycle_begin_prepare(lc);
    int allowed = host_mpv_lifecycle_command_allowed(lc);
    host_mpv_lifecycle_state_t state = host_mpv_lifecycle_state(lc);
    printf("RESULT prepare_once prepared=%d allowed=%d state=%d\n",
           prepared, allowed, (int)state);
    CHECK(prepared == 1, "prepare_once: begin_prepare must succeed");
    CHECK(allowed == 1, "prepare_once: commands must be allowed once prepared");
    CHECK(state == HOST_MPV_LC_PREPARED, "prepare_once: state must be PREPARED");
    host_mpv_lifecycle_release(lc);
}

static void scenario_double_prepare_rejected(void) {
    host_mpv_lifecycle_t *lc = host_mpv_lifecycle_create();
    int first = host_mpv_lifecycle_begin_prepare(lc);
    int second = host_mpv_lifecycle_begin_prepare(lc);
    int allowed = host_mpv_lifecycle_command_allowed(lc);
    host_mpv_lifecycle_state_t state = host_mpv_lifecycle_state(lc);
    printf("RESULT double_prepare_rejected first=%d second=%d allowed=%d state=%d\n",
           first, second, allowed, (int)state);
    CHECK(first == 1, "double_prepare: first prepare must succeed");
    CHECK(second == 0, "double_prepare: second prepare must be rejected (no orphan handle)");
    CHECK(allowed == 1, "double_prepare: commands still allowed on the live handle");
    CHECK(state == HOST_MPV_LC_PREPARED, "double_prepare: state must stay PREPARED");
    host_mpv_lifecycle_release(lc);
}

static void scenario_commands_after_destroy(void) {
    host_mpv_lifecycle_t *lc = host_mpv_lifecycle_create();
    (void)host_mpv_lifecycle_begin_prepare(lc);
    int owned = host_mpv_lifecycle_begin_destroy(lc);
    int allowed = host_mpv_lifecycle_command_allowed(lc);
    int reprepare = host_mpv_lifecycle_begin_prepare(lc);
    int second_destroy = host_mpv_lifecycle_begin_destroy(lc);
    int waited = host_mpv_lifecycle_wait_event_thread_exit(lc, 200);
    host_mpv_lifecycle_finish_destroy(lc);
    host_mpv_lifecycle_state_t state = host_mpv_lifecycle_state(lc);
    printf("RESULT commands_after_destroy owned=%d allowed=%d reprepare=%d second_destroy=%d waited=%d state=%d\n",
           owned, allowed, reprepare, second_destroy, waited, (int)state);
    CHECK(owned == 1, "commands_after_destroy: first destroy must own teardown");
    CHECK(allowed == 0, "commands_after_destroy: commands must be rejected after destroy");
    CHECK(reprepare == 0, "commands_after_destroy: prepare after destroy must be rejected");
    CHECK(second_destroy == 0, "commands_after_destroy: destroy must be idempotent");
    CHECK(waited == 1, "commands_after_destroy: no consumer started, wait must return at once");
    CHECK(state == HOST_MPV_LC_DESTROYED, "commands_after_destroy: state must be DESTROYED");
    host_mpv_lifecycle_release(lc);
}

static void scenario_destroy_before_prepare(void) {
    host_mpv_lifecycle_t *lc = host_mpv_lifecycle_create();
    int owned = host_mpv_lifecycle_begin_destroy(lc);
    int allowed = host_mpv_lifecycle_command_allowed(lc);
    int reprepare = host_mpv_lifecycle_begin_prepare(lc);
    long t0 = now_ms();
    int waited = host_mpv_lifecycle_wait_event_thread_exit(lc, 200);
    long elapsed = now_ms() - t0;
    host_mpv_lifecycle_state_t state = host_mpv_lifecycle_state(lc);
    printf("RESULT destroy_before_prepare owned=%d allowed=%d reprepare=%d waited=%d elapsed_ms=%ld state=%d\n",
           owned, allowed, reprepare, waited, elapsed, (int)state);
    CHECK(owned == 1, "destroy_before_prepare: destroy of a never-prepared lifecycle must succeed");
    CHECK(allowed == 0, "destroy_before_prepare: commands must be rejected");
    CHECK(reprepare == 0, "destroy_before_prepare: prepare after destroy must be rejected");
    CHECK(waited == 1, "destroy_before_prepare: wait must return at once (no consumer)");
    CHECK(elapsed < 100, "destroy_before_prepare: wait must not block, elapsed=%ld", elapsed);
    CHECK(state == HOST_MPV_LC_DESTROYED, "destroy_before_prepare: state must be DESTROYED");
    host_mpv_lifecycle_release(lc);
}

static void scenario_event_exit_handshake(void) {
    host_mpv_lifecycle_t *lc = host_mpv_lifecycle_create();
    (void)host_mpv_lifecycle_begin_prepare(lc);
    fake_consumer_t consumer;
    fake_consumer_start(&consumer, lc, 0);
    /* Let the consumer enter its fake wait_event. */
    struct timespec nap = {0, 50 * 1000000L};
    (void)nanosleep(&nap, NULL);
    int owned = host_mpv_lifecycle_begin_destroy(lc);
    fake_consumer_request_stop(&consumer);
    long t0 = now_ms();
    int waited = host_mpv_lifecycle_wait_event_thread_exit(lc, 2000);
    long elapsed = now_ms() - t0;
    long release_seq = next_seq();
    /* Teardown (release) happens only after the wait returned. */
    host_mpv_lifecycle_finish_destroy(lc);
    fake_consumer_join(&consumer);
    host_mpv_lifecycle_state_t state = host_mpv_lifecycle_state(lc);
    printf("RESULT event_exit_handshake owned=%d waited=%d elapsed_ms=%ld exit_seq=%ld release_seq=%ld state=%d\n",
           owned, waited, elapsed, consumer.exit_seq, release_seq, (int)state);
    CHECK(owned == 1, "handshake: destroy must own teardown");
    CHECK(waited == 1, "handshake: wait must report the consumer exited");
    CHECK(elapsed < 1000, "handshake: wait must return promptly, elapsed=%ld", elapsed);
    CHECK(consumer.exit_seq > 0, "handshake: consumer must have exited");
    CHECK(consumer.exit_seq < release_seq, "handshake: release must happen after consumer exit");
    CHECK(state == HOST_MPV_LC_DESTROYED, "handshake: state must be DESTROYED");
    host_mpv_lifecycle_release(lc);
}

static void scenario_event_exit_timeout_bounded(void) {
    host_mpv_lifecycle_t *lc = host_mpv_lifecycle_create();
    (void)host_mpv_lifecycle_begin_prepare(lc);
    fake_consumer_t consumer;
    fake_consumer_start(&consumer, lc, 1); /* stuck: ignores the stop request */
    struct timespec nap = {0, 50 * 1000000L};
    (void)nanosleep(&nap, NULL);
    int owned = host_mpv_lifecycle_begin_destroy(lc);
    fake_consumer_request_stop(&consumer);
    long t0 = now_ms();
    int waited = host_mpv_lifecycle_wait_event_thread_exit(lc, 200);
    long elapsed = now_ms() - t0;
    /* Bounded wait ends anyway: teardown proceeds, never hangs the caller. */
    host_mpv_lifecycle_finish_destroy(lc);
    host_mpv_lifecycle_state_t state = host_mpv_lifecycle_state(lc);
    printf("RESULT event_exit_timeout_bounded owned=%d waited=%d elapsed_ms=%ld state=%d\n",
           owned, waited, elapsed, (int)state);
    CHECK(owned == 1, "timeout: destroy must own teardown");
    CHECK(waited == 0, "timeout: wait must report the consumer did NOT exit");
    CHECK(elapsed >= 150 && elapsed < 1000, "timeout: wait must be bounded (~200ms), elapsed=%ld", elapsed);
    CHECK(state == HOST_MPV_LC_DESTROYED, "timeout: teardown still finishes the state");
    /* Unstick the consumer for a clean process exit. */
    (void)pthread_mutex_lock(&consumer.mutex);
    consumer.ignore_stop = 0;
    consumer.stop_requested = 1;
    (void)pthread_cond_signal(&consumer.cond);
    (void)pthread_mutex_unlock(&consumer.mutex);
    fake_consumer_join(&consumer);
    host_mpv_lifecycle_release(lc);
}

typedef struct {
    host_mpv_lifecycle_t *lc;
    int result;
} destroy_racer_t;

static void *destroy_racer_main(void *arg) {
    destroy_racer_t *r = (destroy_racer_t *)arg;
    r->result = host_mpv_lifecycle_begin_destroy(r->lc);
    return NULL;
}

static void scenario_concurrent_destroy_single_owner(void) {
    int owners_total = 0;
    int rounds = 50;
    for (int i = 0; i < rounds; i++) {
        host_mpv_lifecycle_t *lc = host_mpv_lifecycle_create();
        (void)host_mpv_lifecycle_begin_prepare(lc);
        destroy_racer_t a = {lc, -1}, b = {lc, -1};
        pthread_t ta, tb;
        (void)pthread_create(&ta, NULL, destroy_racer_main, &a);
        (void)pthread_create(&tb, NULL, destroy_racer_main, &b);
        (void)pthread_join(ta, NULL);
        (void)pthread_join(tb, NULL);
        int owners = (a.result == 1) + (b.result == 1);
        owners_total += owners;
        CHECK(owners == 1, "concurrent_destroy round %d: exactly one owner, got %d", i, owners);
        host_mpv_lifecycle_finish_destroy(lc);
        host_mpv_lifecycle_release(lc);
    }
    printf("RESULT concurrent_destroy_single_owner rounds=%d owners_total=%d\n",
           rounds, owners_total);
    CHECK(owners_total == rounds, "concurrent_destroy: every round must have exactly one owner");
}

static void scenario_abandon_prepare(void) {
    host_mpv_lifecycle_t *lc = host_mpv_lifecycle_create();
    int first = host_mpv_lifecycle_begin_prepare(lc);
    int abandoned = host_mpv_lifecycle_abandon_prepare(lc);
    host_mpv_lifecycle_state_t idle_state = host_mpv_lifecycle_state(lc);
    int reprepare = host_mpv_lifecycle_begin_prepare(lc);
    int allowed = host_mpv_lifecycle_command_allowed(lc);
    printf("RESULT abandon_prepare first=%d abandoned=%d idle_state=%d reprepare=%d allowed=%d\n",
           first, abandoned, (int)idle_state, reprepare, allowed);
    CHECK(first == 1, "abandon: first prepare must succeed");
    CHECK(abandoned == 1, "abandon: prepare failed before thread start must return to IDLE");
    CHECK(idle_state == HOST_MPV_LC_IDLE, "abandon: state must be IDLE after abandon");
    CHECK(reprepare == 1, "abandon: a fresh prepare after abandon must succeed");
    CHECK(allowed == 1, "abandon: commands allowed after re-prepare");
    host_mpv_lifecycle_release(lc);
}

static void scenario_abandon_after_thread_started_refused(void) {
    host_mpv_lifecycle_t *lc = host_mpv_lifecycle_create();
    (void)host_mpv_lifecycle_begin_prepare(lc);
    host_mpv_lifecycle_note_event_thread_started(lc);
    int abandoned = host_mpv_lifecycle_abandon_prepare(lc);
    host_mpv_lifecycle_state_t state = host_mpv_lifecycle_state(lc);
    int allowed = host_mpv_lifecycle_command_allowed(lc);
    printf("RESULT abandon_after_thread_started_refused abandoned=%d state=%d allowed=%d\n",
           abandoned, (int)state, allowed);
    CHECK(abandoned == 0, "abandon_started: abandon must be refused once the consumer runs");
    CHECK(state == HOST_MPV_LC_PREPARED, "abandon_started: state must stay PREPARED");
    CHECK(allowed == 1, "abandon_started: commands still allowed");
    /* Clean up through the normal destroy path. */
    (void)host_mpv_lifecycle_begin_destroy(lc);
    host_mpv_lifecycle_note_event_thread_exited(lc);
    (void)host_mpv_lifecycle_wait_event_thread_exit(lc, 200);
    host_mpv_lifecycle_finish_destroy(lc);
    host_mpv_lifecycle_release(lc);
}

static void scenario_rapid_prepare_destroy_cycles(void) {
    int cycles = 200;
    int bad = 0;
    for (int i = 0; i < cycles; i++) {
        host_mpv_lifecycle_t *lc = host_mpv_lifecycle_create();
        if (!host_mpv_lifecycle_begin_prepare(lc)) bad++;
        host_mpv_lifecycle_note_event_thread_started(lc);
        if (!host_mpv_lifecycle_begin_destroy(lc)) bad++;
        host_mpv_lifecycle_note_event_thread_exited(lc);
        if (!host_mpv_lifecycle_wait_event_thread_exit(lc, 200)) bad++;
        host_mpv_lifecycle_finish_destroy(lc);
        if (host_mpv_lifecycle_state(lc) != HOST_MPV_LC_DESTROYED) bad++;
        if (host_mpv_lifecycle_command_allowed(lc)) bad++;
        host_mpv_lifecycle_release(lc);
    }
    printf("RESULT rapid_prepare_destroy_cycles cycles=%d bad=%d\n", cycles, bad);
    CHECK(bad == 0, "rapid_cycles: all %d cycles must follow the terminal sequence", cycles);
}

static void scenario_refcount_teardown_outlives_owner(void) {
    host_mpv_lifecycle_t *lc = host_mpv_lifecycle_create();
    int rc_create = host_mpv_lifecycle_refcount(lc);
    host_mpv_lifecycle_t *teardown_ref = host_mpv_lifecycle_retain(lc);
    int rc_after_retain = host_mpv_lifecycle_refcount(lc);
    (void)teardown_ref;
    host_mpv_lifecycle_release(lc); /* owner (adapter) drops its reference */
    int rc_after_owner_release = host_mpv_lifecycle_refcount(lc);
    (void)host_mpv_lifecycle_begin_prepare(lc);
    (void)host_mpv_lifecycle_begin_destroy(lc);
    host_mpv_lifecycle_finish_destroy(lc);
    int rc_before_teardown_release = host_mpv_lifecycle_refcount(lc);
    host_mpv_lifecycle_release(lc); /* teardown drops its reference: freed */
    printf("RESULT refcount_teardown_outlives_owner rc_create=%d rc_after_retain=%d rc_after_owner_release=%d rc_before_teardown_release=%d\n",
           rc_create, rc_after_retain, rc_after_owner_release, rc_before_teardown_release);
    CHECK(rc_create == 1, "refcount: create must start at 1");
    CHECK(rc_after_retain == 2, "refcount: teardown retain must make 2");
    CHECK(rc_after_owner_release == 1, "refcount: owner release must leave the teardown ref alive");
    CHECK(rc_before_teardown_release == 1, "refcount: teardown ref must still be alive at finish");
}

int main(void) {
    scenario_prepare_once();
    scenario_double_prepare_rejected();
    scenario_commands_after_destroy();
    scenario_destroy_before_prepare();
    scenario_event_exit_handshake();
    scenario_event_exit_timeout_bounded();
    scenario_concurrent_destroy_single_owner();
    scenario_abandon_prepare();
    scenario_abandon_after_thread_started_refused();
    scenario_rapid_prepare_destroy_cycles();
    scenario_refcount_teardown_outlives_owner();
    if (failures) {
        fprintf(stderr, "mpv lifecycle doubles: %d failure(s)\n", failures);
        return 1;
    }
    printf("MPV_LIFECYCLE_DOUBLES_OK\n");
    return 0;
}
