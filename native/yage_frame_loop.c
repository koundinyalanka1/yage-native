#include "yage_internal.h"

#ifndef _WIN32

int64_t        g_core_frame_ns       = DEFAULT_FRAME_NS;
uint32_t*      g_display_buf         = NULL;
size_t         g_display_buf_capacity = 0;
int            g_display_width        = 0;
int            g_display_height       = 0;
pthread_mutex_t g_display_mutex       = PTHREAD_MUTEX_INITIALIZER;

static pthread_t           g_frame_thread;
atomic_int                 g_floop_running       = 0;
static atomic_int          g_floop_speed_pct     = 100;
static atomic_int          g_floop_rewind_on     = 0;
static atomic_int          g_floop_rewind_interval = 5;
static atomic_int          g_floop_rcheevos_on   = 0;
static atomic_int          g_floop_fps_x100      = 0;
static yage_frame_callback_t g_frame_callback    = NULL;

static void* frame_loop_thread(void* arg) {
    YageCore* core = (YageCore*)arg;

    struct timespec last_time;
    clock_gettime(CLOCK_MONOTONIC, &last_time);

    int64_t emu_accum_ns     = 0;
    int64_t display_accum_ns = 0;
    int     total_frames     = 0;
    int     rewind_counter   = 0;
    int64_t retro_run_total_ns = 0;
    int     retro_run_count    = 0;
    int     blit_ok_count      = 0;
    int     blit_fail_count    = 0;

    struct timespec fps_time  = last_time;
    struct timespec diag_time = last_time;

    LOGI("Frame loop thread started (core_frame_ns=%lld)", (long long)g_core_frame_ns);

#ifdef __ANDROID__
    
    if (g_hw_render_enabled &&
        g_egl_display != EGL_NO_DISPLAY &&
        g_egl_surface != EGL_NO_SURFACE &&
        g_egl_context != EGL_NO_CONTEXT) {
        if (!eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface, g_egl_context)) {
            LOGE("Frame loop: eglMakeCurrent failed (err=0x%x)", (unsigned)eglGetError());
            atomic_store_explicit(&g_floop_running, 0, memory_order_release);
            return NULL;
        }
        LOGI("Frame loop: EGL context bound to frame thread");

        if (g_hw_context_reset_pending && g_hw_render_cb.context_reset) {
            g_hw_context_reset_pending = 0;
            LOGI("Frame loop: calling deferred context_reset before first retro_run");
            g_hw_render_cb.context_reset();
        }
    }
#endif 

    while (atomic_load_explicit(&g_floop_running, memory_order_acquire)) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        int64_t elapsed_ns = (now.tv_sec  - last_time.tv_sec)  * 1000000000LL
                           + (now.tv_nsec - last_time.tv_nsec);
        last_time = now;

        emu_accum_ns     += elapsed_ns;
        display_accum_ns += elapsed_ns;

        int speed_pct = atomic_load_explicit(&g_floop_speed_pct, memory_order_relaxed);
        if (speed_pct < 25) speed_pct = 25;
        int64_t target_ns = g_core_frame_ns * 100LL / speed_pct;

        int frames_run = 0;
        while (atomic_load_explicit(&g_floop_running, memory_order_relaxed) &&
               emu_accum_ns >= target_ns && frames_run < 8) {

            g_audio_samples = 0;
            {
                struct timespec t0, t1;
                clock_gettime(CLOCK_MONOTONIC, &t0);
                core->retro_run();
                clock_gettime(CLOCK_MONOTONIC, &t1);
                retro_run_total_ns += (t1.tv_sec - t0.tv_sec) * 1000000000LL
                                    + (t1.tv_nsec - t0.tv_nsec);
                retro_run_count++;
            }
            total_frames++;

            if (atomic_load_explicit(&g_floop_rewind_on, memory_order_relaxed)) {
                rewind_counter++;
                int interval = atomic_load_explicit(&g_floop_rewind_interval,
                                                     memory_order_relaxed);
                if (interval > 0 && rewind_counter >= interval) {
                    rewind_counter = 0;
                    yage_core_rewind_push(core);
                }
            }

            if (atomic_load_explicit(&g_floop_rcheevos_on, memory_order_relaxed)) {
                yage_rc_do_frame();
            }

            emu_accum_ns -= target_ns;
            frames_run++;
        }

        if (emu_accum_ns > target_ns * 10) emu_accum_ns = 0;

        if (frames_run > 0 && display_accum_ns >= DISPLAY_INTERVAL_NS) {
            display_accum_ns -= DISPLAY_INTERVAL_NS;
            if (display_accum_ns > DISPLAY_INTERVAL_NS * 3) display_accum_ns = 0;

            int w = g_width;
            int h = g_height;

#ifdef __ANDROID__
            if (g_native_window) {
                if (g_hw_render_enabled && hw_render_is_direct_present()) {
                    blit_ok_count++;
                } else {
                    if (blit_to_native_window() == 0) blit_ok_count++;
                    else blit_fail_count++;
                }
            } else
#endif
            {
                size_t pixels = (size_t)w * h;
                if (g_display_buf && pixels <= g_display_buf_capacity && g_video_buffer) {
                    pthread_mutex_lock(&g_display_mutex);
                    memcpy(g_display_buf, g_video_buffer, pixels * sizeof(uint32_t));
                    g_display_width  = w;
                    g_display_height = h;
                    pthread_mutex_unlock(&g_display_mutex);
                }
            }

            if (g_frame_callback) g_frame_callback(frames_run);
        }

        int64_t fps_elapsed = (now.tv_sec  - fps_time.tv_sec)  * 1000000000LL
                            + (now.tv_nsec - fps_time.tv_nsec);
        if (fps_elapsed >= 500000000LL) {
            double fps = (double)total_frames * 1.0e9 / (double)fps_elapsed;
            atomic_store_explicit(&g_floop_fps_x100, (int)(fps * 100.0), memory_order_relaxed);
            total_frames = 0;
            fps_time = now;
        }

        int64_t diag_elapsed = (now.tv_sec  - diag_time.tv_sec)  * 1000000000LL
                             + (now.tv_nsec - diag_time.tv_nsec);
        if (diag_elapsed >= 2000000000LL) {
#ifdef __ANDROID__
            {
                int avail = ring_buffer_available();
                double avg_run_ms = (retro_run_count > 0)
                    ? (double)retro_run_total_ns / retro_run_count / 1e6 : 0;
                double diag_fps = (retro_run_count > 0)
                    ? (double)retro_run_count * 1.0e9 / (double)diag_elapsed : 0;
                LOGI("Diag: fps=%.1f, retro_run=%.1fms avg (%d frames), blit=%d ok/%d fail, "
                     "ring=%d/%d, underruns=%d, overflows=%d",
                     diag_fps, avg_run_ms, retro_run_count,
                     blit_ok_count, blit_fail_count,
                     avail, RING_BUFFER_SIZE - 1,
                     g_underrun_count, g_overflow_count);
            }
#else
            (void)blit_ok_count; (void)blit_fail_count;
#endif
            retro_run_total_ns = 0;
            retro_run_count    = 0;
            blit_ok_count      = 0;
            blit_fail_count    = 0;
            diag_time = now;
        }

        int64_t next_emu_ns     = target_ns - emu_accum_ns;
        int64_t next_display_ns = DISPLAY_INTERVAL_NS - display_accum_ns;
        int64_t sleep_ns = next_emu_ns < next_display_ns ? next_emu_ns : next_display_ns;

        if (sleep_ns > 500000) {
            struct timespec ts;
            ts.tv_sec  = sleep_ns / 1000000000LL;
            ts.tv_nsec = sleep_ns % 1000000000LL;
            nanosleep(&ts, NULL);
        }
    }

    LOGI("Frame loop thread exiting");
    return NULL;
}

int yage_frame_loop_start(YageCore* core, yage_frame_callback_t callback) {
    if (!core || !core->game_loaded || !core->retro_run) return -1;
    if (atomic_load(&g_floop_running)) return -1;

    size_t needed = g_video_buffer_capacity;
    if (!g_display_buf || g_display_buf_capacity < needed) {
        free(g_display_buf);
        g_display_buf = (uint32_t*)malloc(needed * sizeof(uint32_t));
        if (!g_display_buf) { LOGE("Failed to allocate display buffer"); return -1; }
        g_display_buf_capacity = needed;
    }
    memset(g_display_buf, 0, needed * sizeof(uint32_t));
    g_display_width  = g_width;
    g_display_height = g_height;

    g_frame_callback = callback;
    atomic_store_explicit(&g_floop_fps_x100, 0, memory_order_relaxed);
    atomic_store_explicit(&g_floop_running,  1, memory_order_release);

    int rc = pthread_create(&g_frame_thread, NULL, frame_loop_thread, core);
    if (rc != 0) {
        atomic_store(&g_floop_running, 0);
        g_frame_callback = NULL;
        LOGE("pthread_create failed: %d", rc);
        return -1;
    }

    LOGI("Native frame loop started (speed=%d%%)", atomic_load(&g_floop_speed_pct));
    return 0;
}

void yage_frame_loop_stop(YageCore* core) {
    (void)core;
    if (!atomic_load(&g_floop_running)) return;
    atomic_store_explicit(&g_floop_running, 0, memory_order_release);
    pthread_join(g_frame_thread, NULL);
    g_frame_callback = NULL;
    LOGI("Native frame loop stopped");
}

void yage_frame_loop_set_speed(YageCore* core, int32_t speed_percent) {
    (void)core;
    if (speed_percent < 25)  speed_percent = 25;
    if (speed_percent > 800) speed_percent = 800;
    atomic_store_explicit(&g_floop_speed_pct, speed_percent, memory_order_relaxed);
}

void yage_frame_loop_set_rewind(YageCore* core, int32_t enabled, int32_t interval) {
    (void)core;
    atomic_store_explicit(&g_floop_rewind_on, enabled ? 1 : 0, memory_order_relaxed);
    if (interval > 0)
        atomic_store_explicit(&g_floop_rewind_interval, interval, memory_order_relaxed);
}

void yage_frame_loop_set_rcheevos(YageCore* core, int32_t enabled) {
    (void)core;
    atomic_store_explicit(&g_floop_rcheevos_on, enabled ? 1 : 0, memory_order_relaxed);
}

int32_t yage_frame_loop_get_fps_x100(YageCore* core) {
    (void)core;
    return atomic_load_explicit(&g_floop_fps_x100, memory_order_relaxed);
}

uint32_t* yage_frame_loop_get_display_buffer(YageCore* core) {
    (void)core;
    return g_display_buf;
}

int32_t yage_frame_loop_get_display_width(YageCore* core) {
    (void)core;
    return g_display_width;
}

int32_t yage_frame_loop_get_display_height(YageCore* core) {
    (void)core;
    return g_display_height;
}

void yage_frame_loop_lock_display(YageCore* core) {
    (void)core;
    pthread_mutex_lock(&g_display_mutex);
}

void yage_frame_loop_unlock_display(YageCore* core) {
    (void)core;
    pthread_mutex_unlock(&g_display_mutex);
}

int32_t yage_frame_loop_is_running(YageCore* core) {
    (void)core;
    return atomic_load_explicit(&g_floop_running, memory_order_acquire);
}

#else 

int  yage_frame_loop_start(YageCore* c, yage_frame_callback_t cb) { (void)c; (void)cb; return -1; }
void yage_frame_loop_stop(YageCore* c) { (void)c; }
void yage_frame_loop_set_speed(YageCore* c, int32_t s) { (void)c; (void)s; }
void yage_frame_loop_set_rewind(YageCore* c, int32_t e, int32_t i) { (void)c; (void)e; (void)i; }
void yage_frame_loop_set_rcheevos(YageCore* c, int32_t e) { (void)c; (void)e; }
int32_t   yage_frame_loop_get_fps_x100(YageCore* c)          { (void)c; return 0; }
uint32_t* yage_frame_loop_get_display_buffer(YageCore* c)    { (void)c; return NULL; }
int32_t   yage_frame_loop_get_display_width(YageCore* c)     { (void)c; return 0; }
int32_t   yage_frame_loop_get_display_height(YageCore* c)    { (void)c; return 0; }
void      yage_frame_loop_lock_display(YageCore* c)          { (void)c; }
void      yage_frame_loop_unlock_display(YageCore* c)        { (void)c; }
int32_t   yage_frame_loop_is_running(YageCore* c)            { (void)c; return 0; }

#endif 
