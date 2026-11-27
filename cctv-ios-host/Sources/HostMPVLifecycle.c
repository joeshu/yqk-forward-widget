/* HostMPVLifecycle.c
 *
 * Pure-C terminal lifecycle core for the MPV adapter (B1/T02, audit S1).
 * See the header for the contract. C99 + pthreads only: no Foundation,
 * no I/O, no allocation besides the lifecycle object itself.
 */
#define _POSIX_C_SOURCE 200809L /* clock_gettime, pthread_condattr_setclock */

#include "HostMPVLifecycle.h"

#include <errno.h>
#include <stdlib.h>
#include <time.h>

static void host_mpv_lifecycle_lock(host_mpv_lifecycle_t *lc) {
    (void)pthread_mutex_lock(&lc->mutex);
}

static void host_mpv_lifecycle_unlock(host_mpv_lifecycle_t *lc) {
    (void)pthread_mutex_unlock(&lc->mutex);
}

host_mpv_lifecycle_t *host_mpv_lifecycle_create(void) {
    host_mpv_lifecycle_t *lc = (host_mpv_lifecycle_t *)calloc(1, sizeof(*lc));
    if (!lc) return NULL;
    (void)pthread_mutex_init(&lc->mutex, NULL);
    /* Prefer a monotonic clock for the exit wait so a wall-clock jump
     * can neither stretch nor cut the bounded wait short. macOS has no
     * pthread_condattr_setclock: there the cond uses the default clock
     * and the wait deadline is computed in the same clock (see
     * host_mpv_lifecycle_wait_event_thread_exit). */
#if !defined(__APPLE__)
    {
        pthread_condattr_t attr;
        if (pthread_condattr_init(&attr) == 0) {
            (void)pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
            (void)pthread_cond_init(&lc->exited_cond, &attr);
            (void)pthread_condattr_destroy(&attr);
        } else {
            (void)pthread_cond_init(&lc->exited_cond, NULL);
        }
    }
#else
    (void)pthread_cond_init(&lc->exited_cond, NULL);
#endif
    lc->state = HOST_MPV_LC_IDLE;
    lc->event_thread_started = 0;
    lc->event_thread_exited = 0;
    lc->refcount = 1;
    return lc;
}

host_mpv_lifecycle_t *host_mpv_lifecycle_retain(host_mpv_lifecycle_t *lc) {
    if (!lc) return NULL;
    (void)__sync_add_and_fetch(&lc->refcount, 1);
    return lc;
}

void host_mpv_lifecycle_release(host_mpv_lifecycle_t *lc) {
    if (!lc) return;
    if (__sync_sub_and_fetch(&lc->refcount, 1) == 0) {
        (void)pthread_cond_destroy(&lc->exited_cond);
        (void)pthread_mutex_destroy(&lc->mutex);
        free(lc);
    }
}

int host_mpv_lifecycle_refcount(host_mpv_lifecycle_t *lc) {
    if (!lc) return 0;
    return __sync_fetch_and_add(&lc->refcount, 0);
}

host_mpv_lifecycle_state_t host_mpv_lifecycle_state(host_mpv_lifecycle_t *lc) {
    host_mpv_lifecycle_state_t state;
    if (!lc) return HOST_MPV_LC_IDLE;
    host_mpv_lifecycle_lock(lc);
    state = lc->state;
    host_mpv_lifecycle_unlock(lc);
    return state;
}

int host_mpv_lifecycle_begin_prepare(host_mpv_lifecycle_t *lc) {
    int allowed = 0;
    if (!lc) return 0;
    host_mpv_lifecycle_lock(lc);
    if (lc->state == HOST_MPV_LC_IDLE) {
        lc->state = HOST_MPV_LC_PREPARED;
        allowed = 1;
    }
    host_mpv_lifecycle_unlock(lc);
    return allowed;
}

int host_mpv_lifecycle_abandon_prepare(host_mpv_lifecycle_t *lc) {
    int abandoned = 0;
    if (!lc) return 0;
    host_mpv_lifecycle_lock(lc);
    if (lc->state == HOST_MPV_LC_PREPARED && !lc->event_thread_started) {
        lc->state = HOST_MPV_LC_IDLE;
        abandoned = 1;
    }
    host_mpv_lifecycle_unlock(lc);
    return abandoned;
}

void host_mpv_lifecycle_note_event_thread_started(host_mpv_lifecycle_t *lc) {
    if (!lc) return;
    host_mpv_lifecycle_lock(lc);
    lc->event_thread_started = 1;
    host_mpv_lifecycle_unlock(lc);
}

void host_mpv_lifecycle_note_event_thread_exited(host_mpv_lifecycle_t *lc) {
    if (!lc) return;
    host_mpv_lifecycle_lock(lc);
    if (!lc->event_thread_exited) {
        lc->event_thread_exited = 1;
        (void)pthread_cond_broadcast(&lc->exited_cond);
    }
    host_mpv_lifecycle_unlock(lc);
}

int host_mpv_lifecycle_event_thread_exited(host_mpv_lifecycle_t *lc) {
    int exited;
    if (!lc) return 0;
    host_mpv_lifecycle_lock(lc);
    exited = lc->event_thread_exited;
    host_mpv_lifecycle_unlock(lc);
    return exited;
}

int host_mpv_lifecycle_command_allowed(host_mpv_lifecycle_t *lc) {
    int allowed;
    if (!lc) return 0;
    host_mpv_lifecycle_lock(lc);
    allowed = (lc->state == HOST_MPV_LC_PREPARED);
    host_mpv_lifecycle_unlock(lc);
    return allowed;
}

int host_mpv_lifecycle_begin_destroy(host_mpv_lifecycle_t *lc) {
    int owned = 0;
    if (!lc) return 0;
    host_mpv_lifecycle_lock(lc);
    if (lc->state == HOST_MPV_LC_PREPARED) {
        lc->state = HOST_MPV_LC_DESTROYING;
        owned = 1;
    } else if (lc->state == HOST_MPV_LC_IDLE) {
        lc->state = HOST_MPV_LC_DESTROYED;
        owned = 1;
    }
    host_mpv_lifecycle_unlock(lc);
    return owned;
}

int host_mpv_lifecycle_wait_event_thread_exit(host_mpv_lifecycle_t *lc, int timeout_ms) {
    int exited = 0;
    struct timespec deadline;
    if (!lc) return 0;
    if (timeout_ms < 0) timeout_ms = 0;
    (void)clock_gettime(CLOCK_MONOTONIC, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000L;
    }
    host_mpv_lifecycle_lock(lc);
    if (!lc->event_thread_started) {
        /* No consumer was ever started: nothing to wait for. */
        exited = 1;
    } else {
        while (!lc->event_thread_exited) {
#ifdef __APPLE__
            struct timespec now;
            struct timespec remaining;
            (void)clock_gettime(CLOCK_MONOTONIC, &now);
            remaining.tv_sec = deadline.tv_sec - now.tv_sec;
            remaining.tv_nsec = deadline.tv_nsec - now.tv_nsec;
            if (remaining.tv_nsec < 0) {
                remaining.tv_sec -= 1;
                remaining.tv_nsec += 1000000000L;
            }
            if (remaining.tv_sec < 0 || (remaining.tv_sec == 0 && remaining.tv_nsec <= 0)) {
                break;
            }
            int rc = pthread_cond_timedwait_relative_np(&lc->exited_cond, &lc->mutex, &remaining);
#else
            int rc = pthread_cond_timedwait(&lc->exited_cond, &lc->mutex, &deadline);
#endif
            if (rc == EINTR) continue;
            if (rc != 0) break; /* timeout (or error): bounded wait ends here */
        }
        exited = lc->event_thread_exited ? 1 : 0;
    }
    host_mpv_lifecycle_unlock(lc);
    return exited;
}

void host_mpv_lifecycle_finish_destroy(host_mpv_lifecycle_t *lc) {
    if (!lc) return;
    host_mpv_lifecycle_lock(lc);
    if (lc->state == HOST_MPV_LC_DESTROYING) {
        lc->state = HOST_MPV_LC_DESTROYED;
    }
    host_mpv_lifecycle_unlock(lc);
}
