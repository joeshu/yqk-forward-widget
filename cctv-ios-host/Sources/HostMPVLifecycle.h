/* HostMPVLifecycle.h
 *
 * Pure-C terminal lifecycle core for the MPV adapter (B1/T02, audit S1).
 *
 * C99 + pthreads only: no Foundation, no I/O, no allocation except the
 * lifecycle object itself (heap-allocated, atomically refcounted, so the
 * background teardown can outlive the adapter object safely).
 *
 * What it owns (and only this):
 *   - prepare/destroy ownership: double prepare is rejected, destroy is
 *     single-owner and idempotent, commands after the terminal stop
 *     (destroy) are rejected;
 *   - the event-consumer exit handshake: background teardown waits for the
 *     mpv_wait_event consumer thread to leave before the handle may be
 *     released with mpv_terminate_destroy, so terminate_destroy can never
 *     run while the consumer is still inside wait_event or reading an
 *     event payload.
 *
 * What it deliberately does NOT own: playback state (playing/paused/
 * buffering), first-frame/seek semantics, rendering. Those stay in the
 * adapter (T08/T20 scope). `stop` (mpv "stop": unload the current file)
 * is a media command, not a lifecycle transition: the handle and the
 * event thread stay alive, commands stay allowed. Only destroy is
 * terminal.
 *
 * Locking: one mutex serialises every state transition (the "single
 * lifecycle queue" of T02). The event-exit condition is a separate cond
 * on the same mutex. Refcount uses __sync builtins so retain/release
 * are safe even while another thread is freeing the object.
 */
#ifndef CCTVHOST_HOST_MPV_LIFECYCLE_H
#define CCTVHOST_HOST_MPV_LIFECYCLE_H

#include <pthread.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    HOST_MPV_LC_IDLE = 0,       /* no handle */
    HOST_MPV_LC_PREPARED = 1,   /* handle live, event thread running (or starting) */
    HOST_MPV_LC_DESTROYING = 2, /* destroy claimed; teardown pending */
    HOST_MPV_LC_DESTROYED = 3   /* terminal; handle released */
} host_mpv_lifecycle_state_t;

typedef struct host_mpv_lifecycle {
    pthread_mutex_t mutex;
    pthread_cond_t exited_cond;
    host_mpv_lifecycle_state_t state;
    int event_thread_started;
    int event_thread_exited;
    int refcount; /* atomic via __sync builtins; guarded field, never read bare */
} host_mpv_lifecycle_t;

/* Creates a lifecycle in IDLE with refcount 1 (owned by the caller). */
host_mpv_lifecycle_t *host_mpv_lifecycle_create(void);
/* Retains/releases one reference; release to zero deinitialises and frees. */
host_mpv_lifecycle_t *host_mpv_lifecycle_retain(host_mpv_lifecycle_t *lc);
void host_mpv_lifecycle_release(host_mpv_lifecycle_t *lc);
/* Current refcount (tests/diagnostics only). */
int host_mpv_lifecycle_refcount(host_mpv_lifecycle_t *lc);
/* Current state (mutex-guarded snapshot). */
host_mpv_lifecycle_state_t host_mpv_lifecycle_state(host_mpv_lifecycle_t *lc);
/* 1 if the caller may create a handle (IDLE -> PREPARED), else 0. */
int host_mpv_lifecycle_begin_prepare(host_mpv_lifecycle_t *lc);
/* Returns a failed prepare to IDLE. Only valid before the event thread
 * started; returns 0 (refused, state unchanged) once it has. */
int host_mpv_lifecycle_abandon_prepare(host_mpv_lifecycle_t *lc);
/* Called by the owner right before the event thread is started. */
void host_mpv_lifecycle_note_event_thread_started(host_mpv_lifecycle_t *lc);
/* Called by the event thread on every exit path after its last handle access. */
void host_mpv_lifecycle_note_event_thread_exited(host_mpv_lifecycle_t *lc);
/* 1 while the event thread has exited, else 0. */
int host_mpv_lifecycle_event_thread_exited(host_mpv_lifecycle_t *lc);
/* 1 iff a media command may touch the handle (state == PREPARED). */
int host_mpv_lifecycle_command_allowed(host_mpv_lifecycle_t *lc);
/* Claims teardown. PREPARED -> DESTROYING or IDLE -> DESTROYED, returns 1.
 * DESTROYING/DESTROYED returns 0: destroy is idempotent, exactly one
 * caller owns the release. */
int host_mpv_lifecycle_begin_destroy(host_mpv_lifecycle_t *lc);
/* Blocks until the consumer exits or the timeout elapses. A negative timeout
 * waits without a deadline and is intended for background teardown only.
 * Returns 1 if the consumer exited or was never started. A 0 result does
 * not grant permission to release the handle. */
int host_mpv_lifecycle_wait_event_thread_exit(host_mpv_lifecycle_t *lc, int timeout_ms);
/* DESTROYING -> DESTROYED after the event thread exits. */
void host_mpv_lifecycle_finish_destroy(host_mpv_lifecycle_t *lc);

#ifdef __cplusplus
}
#endif

#endif /* CCTVHOST_HOST_MPV_LIFECYCLE_H */
