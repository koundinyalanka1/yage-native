/*
 * YAGE Audio Module
 *
 * OpenSL ES audio backend (Android) + libretro audio callbacks.
 * Implements:
 *   - Ring-buffer audio pipeline for low-latency playback
 *   - Adaptive sample-rate detection (initial 30-frame window + continuous monitoring)
 *   - Volume scaling and mute support
 *   - audio_sample_batch_callback / audio_sample_callback (libretro contract)
 */

#include "yage_internal.h"

/* ── Volume / audio enable (owned here, set via yage_core_set_volume) ── */
float g_volume       = 1.0f;
int   g_audio_enabled = 1;

/* ── Pre-roll suppression (cross-platform) ────────────────────────────────
 * Set to 1 by yage_core_load_rom around the JIT pre-roll loop.  Audio
 * callbacks short-circuit while set: no rate detection, no OpenSL init, no
 * ring writes.  Declared at file scope so test builds on Linux / macOS
 * link cleanly even though only Android consumes it. */
int g_in_preroll = 0;

#ifdef __ANDROID__

/* ── OpenSL ES state ─────────────────────────────────────────────────── */
static SLObjectItf g_sl_engine     = NULL;
static SLEngineItf g_sl_engine_itf = NULL;
static SLObjectItf g_sl_output_mix = NULL;
static SLObjectItf g_sl_player     = NULL;
static SLPlayItf   g_sl_play_itf   = NULL;
static SLAndroidSimpleBufferQueueItf g_sl_buffer_queue = NULL;

/* Runtime buffer count — default 4; call yage_audio_set_buffer_count() before
 * the first init_opensl_audio() to raise to 6 on TV (higher HDMI latency). */
int g_audio_buffer_count = AUDIO_BUFFERS_DEFAULT;

static int16_t* g_sl_buffers[AUDIO_BUFFERS_MAX];
static int      g_sl_buffer_index = 0;
static atomic_int g_sl_initialized = 0;

/* ── Lock-free ring buffer ────────────────────────────────────────────── */
static int16_t g_ring_buffer[RING_BUFFER_SIZE];
atomic_int g_ring_read  = 0;
atomic_int g_ring_write = 0;

/* ── Audio smoothing / monitoring state ──────────────────────────────── */
static int16_t g_last_sample_l = 0;
static int16_t g_last_sample_r = 0;
int g_underrun_count = 0;
int g_audio_started  = 0;
static double g_audio_sample_rate = 32768.0;

/* Set to 1 by yage_frame_loop_stop so the OpenSL callback silences
 * output immediately instead of looping the elastic hold-buffer.  Cleared
 * by shutdown_opensl_audio_impl so the next game starts cleanly. */
atomic_int g_audio_stopping = 0;

/* ── Elastic playback: hold-buffer loop + adaptive playback rate ─────────
 *
 * When the ring drains faster than the emulator fills it (slow-emu), the old
 * code faded to zero over 64 samples then emitted dead silence until the ring
 * refilled — producing ~30 ms silence + burst artefacts every 2 s on NDS.
 *
 * Two-pronged fix:
 *
 *  (a) Hold-buffer loop: as we consume real audio from the ring we always
 *      write into a circular ELASTIC_HOLD_FRAMES-frame buffer.  On underrun
 *      we loop that buffer instead of silencing — continuous pitched audio
 *      is far less distracting than silence + chirp.
 *
 *  (b) SLPlaybackRateItf rate adaptation: when the ring has been low for
 *      ELASTIC_LOW_MIN_TICKS consecutive callbacks (~512 ms), we drop the
 *      OpenSL playback rate to ELASTIC_RATE_SLOW permille so OpenSL drains
 *      the ring proportionally slower, matching the actual emu fps.  When
 *      the ring recovers above ELASTIC_LOW_THRESH for ELASTIC_RECOVER_TICKS
 *      callbacks we restore to 1000 ‰.  The interface is optional — we
 *      request it with SL_BOOLEAN_FALSE and the hold-buffer fallback remains
 *      effective regardless.
 */
#define ELASTIC_HOLD_FRAMES   1024          /* stereo frames; ~31 ms @ 32 kHz */
#define ELASTIC_HOLD_SAMPLES  (ELASTIC_HOLD_FRAMES * 2) /* int16_t count      */
#define ELASTIC_LOW_THRESH    1500   /* ring samples below this → suspect slow  */
#define ELASTIC_LOW_MIN_TICKS 32     /* ~512 ms sustained before engaging       */
#define ELASTIC_RECOVER_TICKS 8      /* ~128 ms above thresh before disengaging */
#define ELASTIC_RATE_NORMAL   1000   /* permille at full speed                  */
#define ELASTIC_RATE_FLOOR    200    /* allow down to 20% on severely-throttled devices.
                                      * compute_elastic_rate() returns target/ewma×1000; when
                                      * retro_run exceeds 5× the frame budget the production
                                      * rate falls below 200‰. A floor higher than the actual
                                      * production rate means audio drains the ring faster than
                                      * the emulator fills it, causing the hold-loop to engage
                                      * and disengage repeatedly with many SetRate calls. Keeping
                                      * the floor ≤ realistic production rate lets the adapter
                                      * stabilise rather than oscillate. At very low rates audio
                                      * sounds proportionally slow; the hold-loop covers any
                                      * remaining underruns. */
#define ELASTIC_RATE_CEILING  950    /* engage point: clearly slow              */
#define ELASTIC_RATE_UPDATE_TICKS 16 /* avoid SetRate/logcat churn in callback  */
#define ELASTIC_RATE_QUANTUM  25     /* quantize to stable, audible buckets      */

/* Actual minimum rate the device's OpenSL driver accepts, queried via
 * GetRateRange() at init_opensl_audio().  Declared here, above
 * compute_elastic_rate(), so C sees it before its first use. */
static SLpermille g_sl_rate_min = ELASTIC_RATE_FLOOR;

/* Compute the elastic playback rate from the frame-loop's EWMA of retro_run
 * cost.  Idea: at full speed retro_run ≈ g_core_frame_ns and the producer is
 * exactly keeping up with a 1000‰ consumer.  When retro_run takes 2× the
 * core frame interval the emu is producing half as many samples per wall-
 * clock second, so a 500‰ consumer would match perfectly.  We never go
 * below ELASTIC_RATE_FLOOR (sounds bad) and we leave a small headroom over
 * the strict 1:1 match so the ring slowly refills.
 *
 * Falls back to a sane "75 %" if the frame loop hasn't published any EWMA
 * data yet (e.g. when audio is driven by something other than the native
 * frame loop). */
static SLpermille compute_elastic_rate(void) {
#ifdef __ANDROID__
    int ewma_us = atomic_load_explicit(&g_retro_run_ewma_us, memory_order_relaxed);
    if (ewma_us <= 0 || g_core_frame_ns <= 0) {
        return 750;
    }
    int target_us = (int)(g_core_frame_ns / 1000);     /* core frame µs   */
    if (target_us <= 0) return 750;
    /* ratio_x1000 = target / ewma × 1000, clamped to [FLOOR, CEILING].
     * We use a small bias (95 %) so when emu is exactly on time the rate
     * still climbs back to 1000 via the disengage path rather than
     * oscillating around 950. */
    int ratio = (int)((int64_t)target_us * 1000 / ewma_us);
    /* Clamp to [floor, ceiling]. The floor is the LARGER of the compile-time
     * minimum (ELASTIC_RATE_FLOOR, the lowest rate we'll ever try) and
     * g_sl_rate_min (the minimum the device's OpenSL driver actually accepts,
     * queried at init via GetRateRange). Using the device's true minimum avoids
     * SL_RESULT_PARAMETER_INVALID spam on HDMI audio paths that only support
     * rates ≥ 500–750 ‰. */
    int floor = (int)g_sl_rate_min > ELASTIC_RATE_FLOOR
              ? (int)g_sl_rate_min : ELASTIC_RATE_FLOOR;
    if (ratio > ELASTIC_RATE_CEILING) ratio = ELASTIC_RATE_CEILING;
    if (ratio < floor)                ratio = floor;
    ratio = ((ratio + (ELASTIC_RATE_QUANTUM / 2)) / ELASTIC_RATE_QUANTUM)
          * ELASTIC_RATE_QUANTUM;
    if (ratio > ELASTIC_RATE_CEILING) ratio = ELASTIC_RATE_CEILING;
    if (ratio < floor)                ratio = floor;
    return (SLpermille)ratio;
#else
    return 750;
#endif
}

/* All elastic fields are only touched from the OpenSL callback thread. */
static int16_t g_elastic_hold_buf[ELASTIC_HOLD_SAMPLES];
static int     g_elastic_hold_write  = 0;  /* circular write pos in hold buf    */
static int     g_elastic_hold_read   = 0;  /* read pos when looping hold buf     */
static int     g_elastic_hold_count  = 0;  /* total stereo samples written in    */
static int     g_elastic_hold_filled = 0;  /* 1 once buf populated ≥ once        */
static int     g_elastic_low_count   = 0;  /* consecutive low-ring cb count      */
static int     g_elastic_high_count  = 0;  /* consecutive recovered cb count     */
static int     g_elastic_active      = 0;  /* 1 = hold-buf loop engaged          */
static int     g_elastic_rate_ticks  = 0;  /* throttle SetRate from OpenSL cb     */

static SLPlaybackRateItf g_sl_rate_itf   = NULL; /* optional; NULL = unsupported */
static SLpermille        g_rate_permille = ELASTIC_RATE_NORMAL;
/* g_sl_rate_min declared above compute_elastic_rate() — see there. */

/* ── Adaptive rate detection ─────────────────────────────────────────── */
int    g_rate_detection_samples = 0;
int    g_rate_detected          = 0;
double g_detected_rate          = 0;
double g_reported_rate          = 32768.0;

/* ── Continuous monitoring ────────────────────────────────────────────── */
int g_monitor_frames      = 0;
int g_monitor_samples     = 0;
int g_frames_since_reinit = 0;

/* ── Per-second diagnostics ─────────────────────────────────────────── */
int g_audio_batch_count = 0;
int g_overflow_count    = 0;

/* Pre-buffer threshold — wait for ~3 callbacks before starting playback. */
#define PREBUFFER_SAMPLES (AUDIO_BUFFER_FRAMES * 3)

/* ── Forward declarations ────────────────────────────────────────────── */
static void shutdown_opensl_audio_impl(void);
static int  init_opensl_audio_impl(double sample_rate);

/* ── Sample-rate classification ──────────────────────────────────────── */
/*
 * Classify sample rate from average samples-per-frame.
 * mGBA runs at ~59.7275 fps, so expected samples/frame:
 *   131072 Hz → ~2194  (GB/GBC native: 4.194304 MHz ÷ 32)
 *    65536 Hz → ~1097  (most GBA)
 *    48000 Hz → ~804   (NES/SNES)
 *    44100 Hz → ~735   (Genesis Plus GX)
 *    32768 Hz → ~549   (some GB/GBA)
 */
static double classify_sample_rate(double samples_per_frame) {
    if (samples_per_frame > 1600) return 131072.0;
    if (samples_per_frame > 850)  return 65536.0;
    if (samples_per_frame > 770)  return 48000.0;
    if (samples_per_frame > 640)  return 44100.0;
    return 32768.0;
}

static int rate_frame_count(void) {
#ifndef _WIN32
    int core_frames = atomic_load_explicit(&g_core_frames_total,
                                           memory_order_relaxed);
    if (core_frames > 0) return core_frames;
#endif
    return g_video_frames_total;
}

/* ── Ring buffer helpers ─────────────────────────────────────────────── */
int ring_buffer_available(void) {
    int write_pos = atomic_load_explicit(&g_ring_write, memory_order_acquire);
    int read_pos  = atomic_load_explicit(&g_ring_read,  memory_order_acquire);
    return (write_pos - read_pos + RING_BUFFER_SIZE) & RING_BUFFER_MASK;
}

static inline int ring_buffer_free(void) {
    return RING_BUFFER_SIZE - 1 - ring_buffer_available();
}

void reset_opensl_audio_pipeline(void) {
    atomic_store_explicit(&g_ring_read, 0, memory_order_release);
    atomic_store_explicit(&g_ring_write, 0, memory_order_release);
    memset(g_ring_buffer, 0, sizeof(g_ring_buffer));

    g_sl_buffer_index = 0;
    g_last_sample_l = 0;
    g_last_sample_r = 0;
    g_underrun_count = 0;
    g_overflow_count = 0;
    g_audio_started = 0;

    memset(g_elastic_hold_buf, 0, sizeof(g_elastic_hold_buf));
    g_elastic_hold_write  = 0;
    g_elastic_hold_read   = 0;
    g_elastic_hold_count  = 0;
    g_elastic_hold_filled = 0;
    g_elastic_low_count   = 0;
    g_elastic_high_count  = 0;
    g_elastic_active      = 0;
    g_elastic_rate_ticks  = 0;

    if (g_sl_rate_itf != NULL && g_rate_permille != ELASTIC_RATE_NORMAL) {
        if ((*g_sl_rate_itf)->SetRate(g_sl_rate_itf,
                                      (SLpermille)ELASTIC_RATE_NORMAL) ==
            SL_RESULT_SUCCESS) {
            g_rate_permille = ELASTIC_RATE_NORMAL;
        }
    } else {
        g_rate_permille = ELASTIC_RATE_NORMAL;
    }

    LOGI("Audio: pipeline reset");
}

/* ── OpenSL callback ─────────────────────────────────────────────────── */
static void sl_buffer_callback(SLAndroidSimpleBufferQueueItf bq, void* context) {
    (void)context;

    if (!atomic_load_explicit(&g_sl_initialized, memory_order_acquire)) return;

    int16_t* buffer = g_sl_buffers[g_sl_buffer_index];
    if (!buffer) return;
    g_sl_buffer_index = (g_sl_buffer_index + 1) % g_audio_buffer_count;

    int samples_needed = AUDIO_BUFFER_FRAMES * 2; /* stereo */
    int read_pos  = atomic_load_explicit(&g_ring_read,  memory_order_acquire);
    int write_pos = atomic_load_explicit(&g_ring_write, memory_order_acquire);
    int available = (write_pos - read_pos + RING_BUFFER_SIZE) & RING_BUFFER_MASK;

    if (!g_audio_started) {
        if (available < PREBUFFER_SAMPLES * 2) {
            memset(buffer, 0, samples_needed * sizeof(int16_t));
            (*bq)->Enqueue(bq, buffer, samples_needed * sizeof(int16_t));
            return;
        }
        g_audio_started = 1;
        LOGI("Audio pre-buffer filled (%d samples), starting playback", available);
    }

    /* Silence immediately when the frame loop has stopped (pause / stop).
     * Without this the elastic hold-buffer loops the last ~1024 audio frames
     * producing a "radio" noise until shutdown_opensl_audio is called. */
    if (atomic_load_explicit(&g_audio_stopping, memory_order_acquire)) {
        memset(buffer, 0, samples_needed * sizeof(int16_t));
        (*bq)->Enqueue(bq, buffer, samples_needed * sizeof(int16_t));
        return;
    }

    /* ── Elastic: update low/high counters and engage or disengage ─────── */
    if (available < ELASTIC_LOW_THRESH) {
        g_elastic_low_count++;
        g_elastic_high_count = 0;
        if (!g_elastic_active &&
            g_elastic_hold_filled &&
            g_elastic_low_count >= ELASTIC_LOW_MIN_TICKS) {
            g_elastic_active    = 1;
            /* Start looping from oldest sample (= current write pointer). */
            g_elastic_hold_read = g_elastic_hold_write;
            LOGI("Elastic: hold-loop engaged (ring=%d ticks=%d)",
                 available, g_elastic_low_count);
        }
    } else {
        g_elastic_high_count++;
        g_elastic_low_count = 0;
        if (g_elastic_active && g_elastic_high_count >= ELASTIC_RECOVER_TICKS) {
            g_elastic_active    = 0;
            g_elastic_high_count = 0;
            LOGI("Elastic: hold-loop disengaged (ring=%d)", available);
        }
    }

    /* ── Elastic: apply or restore playback rate via SLPlaybackRateItf ───
     *
     * When the hold loop is engaged we compute a rate from the live EWMA
     * of retro_run cost (see compute_elastic_rate).  The target is quantized
     * and applied only every few callbacks so a slow TV does not burn CPU in
     * SetRate/logcat churn while already behind. */
    {
        SLpermille target = g_elastic_active
            ? compute_elastic_rate()
            : (SLpermille)ELASTIC_RATE_NORMAL;
        int delta = (int)target - (int)g_rate_permille;
        if (delta < 0) delta = -delta;
        g_elastic_rate_ticks++;
        int force_restore = (!g_elastic_active &&
                             g_rate_permille != ELASTIC_RATE_NORMAL);
        if (g_elastic_rate_ticks >= ELASTIC_RATE_UPDATE_TICKS || force_restore) {
            g_elastic_rate_ticks = 0;
        } else {
            delta = 0;
        }
        if (delta >= ELASTIC_RATE_QUANTUM && g_sl_rate_itf != NULL) {
            SLresult rr = (*g_sl_rate_itf)->SetRate(g_sl_rate_itf, target);
            if (rr == SL_RESULT_SUCCESS) {
                g_rate_permille = target;
                LOGI("Elastic: playback rate → %d permille", (int)target);
            }
        }
    }

    for (int i = 0; i < samples_needed; i += 2) {
        if (available >= 2) {
            int16_t sl = g_ring_buffer[read_pos];
            read_pos = (read_pos + 1) & RING_BUFFER_MASK;
            int16_t sr = g_ring_buffer[read_pos];
            read_pos = (read_pos + 1) & RING_BUFFER_MASK;
            available -= 2;
            g_underrun_count = 0;
            g_last_sample_l  = sl;
            g_last_sample_r  = sr;
            /* Feed the hold buffer so it always contains the freshest audio. */
            g_elastic_hold_buf[g_elastic_hold_write] = sl;
            g_elastic_hold_write =
                (g_elastic_hold_write + 1) % ELASTIC_HOLD_SAMPLES;
            g_elastic_hold_buf[g_elastic_hold_write] = sr;
            g_elastic_hold_write =
                (g_elastic_hold_write + 1) % ELASTIC_HOLD_SAMPLES;
            if (!g_elastic_hold_filled) {
                g_elastic_hold_count += 2;
                if (g_elastic_hold_count >= ELASTIC_HOLD_SAMPLES)
                    g_elastic_hold_filled = 1;
            }
        } else {
            g_underrun_count++;
            if (g_elastic_active && g_elastic_hold_filled) {
                /* Loop the hold buffer — continuous pitched audio beats
                 * silence+burst artefacts when the emu is slow. */
                g_last_sample_l = g_elastic_hold_buf[g_elastic_hold_read];
                g_elastic_hold_read =
                    (g_elastic_hold_read + 1) % ELASTIC_HOLD_SAMPLES;
                g_last_sample_r = g_elastic_hold_buf[g_elastic_hold_read];
                g_elastic_hold_read =
                    (g_elastic_hold_read + 1) % ELASTIC_HOLD_SAMPLES;
            } else if (g_underrun_count < 64) {
                /* Gentle fade while elastic is not yet armed. */
                g_last_sample_l = (g_last_sample_l * 15) >> 4;
                g_last_sample_r = (g_last_sample_r * 15) >> 4;
            } else {
                g_last_sample_l = 0;
                g_last_sample_r = 0;
            }
        }
        buffer[i]     = g_last_sample_l;
        buffer[i + 1] = g_last_sample_r;
    }

    atomic_store_explicit(&g_ring_read, read_pos, memory_order_release);
    (*bq)->Enqueue(bq, buffer, samples_needed * sizeof(int16_t));
}

/* ── OpenSL init ─────────────────────────────────────────────────────── */
static int init_opensl_audio_impl(double sample_rate) {
    SLresult result;

    if (atomic_load_explicit(&g_sl_initialized, memory_order_acquire)) {
        shutdown_opensl_audio_impl();
    }

    atomic_store(&g_ring_read, 0);
    atomic_store(&g_ring_write, 0);
    g_last_sample_l = 0;
    g_last_sample_r = 0;
    g_underrun_count = 0;
    g_audio_started  = 0;
    memset(g_ring_buffer, 0, sizeof(g_ring_buffer));

    g_audio_sample_rate = sample_rate;
    LOGI("Initializing OpenSL ES audio at %.0f Hz", sample_rate);

    result = slCreateEngine(&g_sl_engine, 0, NULL, 0, NULL, NULL);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to create OpenSL engine"); return -1; }

    result = (*g_sl_engine)->Realize(g_sl_engine, SL_BOOLEAN_FALSE);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to realize OpenSL engine"); return -1; }

    result = (*g_sl_engine)->GetInterface(g_sl_engine, SL_IID_ENGINE, &g_sl_engine_itf);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to get engine interface"); return -1; }

    result = (*g_sl_engine_itf)->CreateOutputMix(g_sl_engine_itf, &g_sl_output_mix, 0, NULL, NULL);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to create output mix"); return -1; }

    result = (*g_sl_output_mix)->Realize(g_sl_output_mix, SL_BOOLEAN_FALSE);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to realize output mix"); return -1; }

    SLDataLocator_AndroidSimpleBufferQueue loc_bufq = {
        SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE, (SLuint32)g_audio_buffer_count
    };

    SLuint32 sample_rate_mhz = (SLuint32)(sample_rate * 1000);
    SLDataFormat_PCM format_pcm = {
        SL_DATAFORMAT_PCM, 2, sample_rate_mhz,
        SL_PCMSAMPLEFORMAT_FIXED_16, SL_PCMSAMPLEFORMAT_FIXED_16,
        SL_SPEAKER_FRONT_LEFT | SL_SPEAKER_FRONT_RIGHT,
        SL_BYTEORDER_LITTLEENDIAN
    };
    SLDataSource audio_src = {&loc_bufq, &format_pcm};

    SLDataLocator_OutputMix loc_outmix = {SL_DATALOCATOR_OUTPUTMIX, g_sl_output_mix};
    SLDataSink audio_sink = {&loc_outmix, NULL};

    /* Request SL_IID_PLAYBACKRATE as optional — not all devices support it.
     * The elastic hold-buffer fallback works regardless of its availability. */
    const SLInterfaceID ids[] = {SL_IID_BUFFERQUEUE, SL_IID_PLAYBACKRATE};
    const SLboolean req[]     = {SL_BOOLEAN_TRUE,    SL_BOOLEAN_FALSE};

    result = (*g_sl_engine_itf)->CreateAudioPlayer(g_sl_engine_itf, &g_sl_player,
        &audio_src, &audio_sink, 2, ids, req);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to create audio player"); return -1; }

    result = (*g_sl_player)->Realize(g_sl_player, SL_BOOLEAN_FALSE);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to realize audio player"); return -1; }

    result = (*g_sl_player)->GetInterface(g_sl_player, SL_IID_PLAY, &g_sl_play_itf);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to get play interface"); return -1; }

    result = (*g_sl_player)->GetInterface(g_sl_player, SL_IID_BUFFERQUEUE, &g_sl_buffer_queue);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to get buffer queue interface"); return -1; }

    /* Optional playback-rate interface for elastic rate adaptation. */
    g_sl_rate_itf   = NULL;
    g_rate_permille = ELASTIC_RATE_NORMAL;
    g_sl_rate_min   = ELASTIC_RATE_FLOOR;
    if ((*g_sl_player)->GetInterface(
            g_sl_player, SL_IID_PLAYBACKRATE, &g_sl_rate_itf) == SL_RESULT_SUCCESS) {
        /* Query the device's actual supported rate range. HDMI audio paths on
         * Android TV often only accept rates ≥ 500–750 ‰; calling SetRate()
         * below that minimum returns SL_RESULT_PARAMETER_INVALID. Store the
         * queried minimum in g_sl_rate_min so compute_elastic_rate() stays
         * within the supported range and avoids driver spam. */
        SLpermille min_rate = ELASTIC_RATE_FLOOR, max_rate = 2000;
        SLpermille step_size = 0;
        SLuint32   caps = 0;
        if ((*g_sl_rate_itf)->GetRateRange(g_sl_rate_itf, 0,
                &min_rate, &max_rate, &step_size, &caps) == SL_RESULT_SUCCESS) {
            g_sl_rate_min = min_rate;
            LOGI("SLPlaybackRateItf available — elastic rate adaptation enabled "
                 "(min=%d max=%d step=%d permille)",
                 (int)min_rate, (int)max_rate, (int)step_size);
        } else {
            LOGI("SLPlaybackRateItf available — elastic rate adaptation enabled "
                 "(GetRateRange failed, using floor=%d)", ELASTIC_RATE_FLOOR);
        }
    } else {
        g_sl_rate_itf = NULL; /* ensure NULL on failure */
        LOGI("SLPlaybackRateItf unavailable — hold-buffer loop only");
    }

    /* Reset elastic playback state for the new session. */
    memset(g_elastic_hold_buf, 0, sizeof(g_elastic_hold_buf));
    g_elastic_hold_write  = 0;
    g_elastic_hold_read   = 0;
    g_elastic_hold_count  = 0;
    g_elastic_hold_filled = 0;
    g_elastic_low_count   = 0;
    g_elastic_high_count  = 0;
    g_elastic_active      = 0;
    g_elastic_rate_ticks  = 0;

    for (int i = 0; i < g_audio_buffer_count; i++) {
        g_sl_buffers[i] = (int16_t*)calloc(AUDIO_BUFFER_FRAMES * 2, sizeof(int16_t));
        if (!g_sl_buffers[i]) {
            LOGE("Failed to allocate audio buffer");
            for (int j = 0; j < i; j++) { free(g_sl_buffers[j]); g_sl_buffers[j] = NULL; }
            return -1;
        }
    }

    result = (*g_sl_buffer_queue)->RegisterCallback(g_sl_buffer_queue, sl_buffer_callback, NULL);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to register callback"); return -1; }

    /* Mark initialized BEFORE starting playback so callback fires correctly */
    atomic_store_explicit(&g_sl_initialized, 1, memory_order_release);

    result = (*g_sl_play_itf)->SetPlayState(g_sl_play_itf, SL_PLAYSTATE_PLAYING);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Failed to start playback");
        atomic_store_explicit(&g_sl_initialized, 0, memory_order_release);
        return -1;
    }

    for (int i = 0; i < g_audio_buffer_count; i++) {
        (*g_sl_buffer_queue)->Enqueue(g_sl_buffer_queue, g_sl_buffers[i],
            AUDIO_BUFFER_FRAMES * 2 * sizeof(int16_t));
    }

    LOGI("OpenSL ES audio initialized: %.0fHz stereo, %d buffers x %d frames",
         sample_rate, g_audio_buffer_count, AUDIO_BUFFER_FRAMES);
    return 0;
}

int init_opensl_audio(double sample_rate) {
    return init_opensl_audio_impl(sample_rate);
}

YAGE_API void yage_audio_set_buffer_count(YageCore* core, int32_t count) {
    (void)core;
    /* Clamp to valid range. Must be called before init_opensl_audio(). */
    if (count < 2) count = 2;
    if (count > AUDIO_BUFFERS_MAX) count = AUDIO_BUFFERS_MAX;
    g_audio_buffer_count = count;
    LOGI("Audio: buffer count set to %d", count);
}

/* ── OpenSL shutdown ─────────────────────────────────────────────────── */
static void shutdown_opensl_audio_impl(void) {
    atomic_store_explicit(&g_sl_initialized, 0, memory_order_release);
    atomic_store_explicit(&g_audio_stopping,  0, memory_order_release);

    if (g_sl_play_itf) {
        (*g_sl_play_itf)->SetPlayState(g_sl_play_itf, SL_PLAYSTATE_STOPPED);
    }
    if (g_sl_buffer_queue) {
        (*g_sl_buffer_queue)->Clear(g_sl_buffer_queue);
    }
    if (g_sl_player) {
        (*g_sl_player)->Destroy(g_sl_player);
        g_sl_player = NULL;
    }
    if (g_sl_output_mix) {
        (*g_sl_output_mix)->Destroy(g_sl_output_mix);
        g_sl_output_mix = NULL;
    }
    if (g_sl_engine) {
        (*g_sl_engine)->Destroy(g_sl_engine);
        g_sl_engine = NULL;
    }
    for (int i = 0; i < g_audio_buffer_count; i++) {
        if (g_sl_buffers[i]) { free(g_sl_buffers[i]); g_sl_buffers[i] = NULL; }
    }

    atomic_store(&g_ring_read, 0);
    atomic_store(&g_ring_write, 0);
    g_last_sample_l = 0;
    g_last_sample_r = 0;
    g_underrun_count = 0;
    g_audio_started  = 0;

    g_sl_rate_itf   = NULL;
    g_sl_rate_min   = ELASTIC_RATE_FLOOR;
    g_rate_permille = ELASTIC_RATE_NORMAL;
    g_elastic_active = 0;
    g_elastic_low_count  = 0;
    g_elastic_high_count = 0;
    g_elastic_rate_ticks = 0;

    g_sl_play_itf     = NULL;
    g_sl_buffer_queue = NULL;
    g_sl_engine_itf   = NULL;
}

void shutdown_opensl_audio(void) {
    shutdown_opensl_audio_impl();
}

#endif /* __ANDROID__ */

/* ══════════════════════════════════════════════════════════════════════
 * Libretro audio callbacks
 * ══════════════════════════════════════════════════════════════════════ */

size_t audio_sample_batch_callback(const int16_t* data, size_t frames) {
    if (!data || !g_audio_buffer) return frames;

#ifdef __ANDROID__
    /* JIT pre-roll: drop everything on the floor.  See note next to
     * g_in_preroll declaration. */
    if (g_in_preroll) {
        g_audio_samples = (int)frames;
        return frames;
    }
#endif

    size_t samples = frames * 2; /* stereo */
    if (samples > AUDIO_BUFFER_SIZE * 2) samples = AUDIO_BUFFER_SIZE * 2;

    if (!g_audio_enabled || g_volume <= 0.0f) {
        memset(g_audio_buffer, 0, samples * sizeof(int16_t));
    } else if (g_volume >= 1.0f) {
        memcpy(g_audio_buffer, data, samples * sizeof(int16_t));
    } else {
        int vol_fp = (int)(g_volume * 256.0f);
        for (size_t i = 0; i < samples; i++) {
            g_audio_buffer[i] = (int16_t)((data[i] * vol_fp) >> 8);
        }
    }
    g_audio_samples = (int)frames;

#ifdef __ANDROID__
    /* ── PHASE 1: Initial rate detection (first 30 emulated frames) ── */
    if (!g_rate_detected) {
        g_rate_detection_samples += (int)frames;

        int frame_count = rate_frame_count();
        if (frame_count >= 30) {
            double avg_spf = (frame_count > 0)
                ? (double)g_rate_detection_samples / frame_count
                : 0;
            double classified_rate = classify_sample_rate(avg_spf);
            double core_fps  = 1000000000.0 / (double)g_core_frame_ns;
            double actual_rate = avg_spf * core_fps;

            double use_rate;
            if (g_reported_rate >= 8000.0 && g_reported_rate <= 192000.0) {
                double ratio = actual_rate / g_reported_rate;
                if (ratio > 0.90 && ratio < 1.10) {
                    use_rate = g_reported_rate;
                    LOGI("Using reported sample rate: %.0f Hz (actual: %.0f Hz, %.1f spf, classified: %.0f Hz)",
                         use_rate, actual_rate, avg_spf, classified_rate);
                } else {
                    use_rate = actual_rate;
                    LOGI("Actual rate %.0f Hz deviates from reported %.0f Hz (ratio=%.3f) — using actual",
                         actual_rate, g_reported_rate, ratio);
                }
            } else {
                use_rate = (actual_rate > 8000.0) ? actual_rate : classified_rate;
                LOGI("Reported rate %.0f Hz out of range, using: %.0f Hz", g_reported_rate, use_rate);
            }

            g_detected_rate = use_rate;
            init_opensl_audio(g_detected_rate);
            g_rate_detected    = 1;
            g_frames_since_reinit = frame_count;
            g_monitor_frames      = frame_count;
            g_monitor_samples     = 0;
        }
        return frames;
    }

    /* ── PHASE 2: Continuous rate monitoring (every ~2 s) ──
     *
     * The detected rate is computed from samples/frame × core_fps, which is
     * independent of how slowly the emulator actually runs.  However, when a
     * core is severely CPU-bound (e.g. melonDS NDS on a low-end Android TV)
     * the SPU can briefly emit short or long batches as it catches up — that
     * showed up in tv_logs.txt as the 5 % gate firing repeatedly and
     * re-initing OpenSL ES, which itself drops audio for tens of ms each
     * time.  We tighten the gate to >12 % drift AND require two consecutive
     * windows to agree before paying the cost of an audio re-init.  This
     * keeps real rate changes (e.g. PAL ↔ NTSC core switch) snappy without
     * thrashing on transient slow-emu spikes.
     */
    g_monitor_samples += (int)frames;
    {
        static int    s_drift_streak    = 0;
        static double s_drift_streak_rate = 0.0;

        int frame_count          = rate_frame_count();
        int frames_in_window    = frame_count - g_monitor_frames;
        int frames_since_reinit = frame_count - g_frames_since_reinit;

        if (frames_in_window >= 120) {
            double avg_spf   = (frames_in_window > 0)
                ? (double)g_monitor_samples / frames_in_window : 0;
            double core_fps  = 1000000000.0 / (double)g_core_frame_ns;
            double new_rate  = avg_spf * core_fps;
            double ratio     = (g_detected_rate > 0) ? new_rate / g_detected_rate : 0;

            if ((ratio < 0.88 || ratio > 1.12) && frames_since_reinit > 180) {
                double streak_ratio = (s_drift_streak_rate > 0)
                    ? new_rate / s_drift_streak_rate : 0;
                /* Require two consecutive ~2-second windows agreeing on the
                 * new rate within ~3 % before we accept the change. */
                if (s_drift_streak > 0 &&
                    streak_ratio > 0.97 && streak_ratio < 1.03) {
                    LOGI("Rate change confirmed: %.0f → %.0f Hz (%.1f spf × %.1f fps)",
                         g_detected_rate, new_rate, avg_spf, core_fps);
                    g_detected_rate       = new_rate;
                    init_opensl_audio(new_rate);
                    g_frames_since_reinit = frame_count;
                    s_drift_streak        = 0;
                    s_drift_streak_rate   = 0.0;
                } else {
                    s_drift_streak++;
                    s_drift_streak_rate = new_rate;
                }
            } else {
                /* In-range — reset the streak. */
                s_drift_streak      = 0;
                s_drift_streak_rate = 0.0;
            }

            g_monitor_frames  = frame_count;
            g_monitor_samples = 0;
        }
    }

    /* ── Diagnostics (every ~1 s / 60 frames) ── */
    g_audio_batch_count++;
    if (g_audio_batch_count >= 60) {
        g_audio_batch_count = 0;
        if (g_overflow_count > 0) {
            LOGI("Audio: %zu frames/batch, overflows: %d, rate: %.0f",
                 frames, g_overflow_count, g_detected_rate);
            g_overflow_count = 0;
        }
    }

    /* ── PHASE 3: Push to ring buffer with adaptive latency cap ── */
    if (atomic_load_explicit(&g_sl_initialized, memory_order_acquire)) {
        int write_pos = atomic_load_explicit(&g_ring_write, memory_order_acquire);
        int read_pos  = atomic_load_explicit(&g_ring_read,  memory_order_acquire);
        int available = (write_pos - read_pos + RING_BUFFER_SIZE) & RING_BUFFER_MASK;
        int free_space = RING_BUFFER_SIZE - 1 - available;

        int max_buffered = (int)(g_detected_rate * 2.0 * 0.090);
        if (max_buffered < AUDIO_BUFFER_FRAMES * 2 * 6)
            max_buffered = AUDIO_BUFFER_FRAMES * 2 * 6;
        {
            int hard_cap = (RING_BUFFER_SIZE * 3) / 4;
            if (max_buffered > hard_cap) max_buffered = hard_cap;
        }

        if (available > max_buffered) {
            int keep    = max_buffered / 2;
            int excess  = available - keep;
            read_pos    = (read_pos + excess) & RING_BUFFER_MASK;
            atomic_store_explicit(&g_ring_read, read_pos, memory_order_release);
            available   = keep;
            free_space  = RING_BUFFER_SIZE - 1 - available;
        }

        if ((int)samples > free_space) {
            int need    = (int)samples - free_space + 128;
            int new_read = (read_pos + need) & RING_BUFFER_MASK;
            atomic_store_explicit(&g_ring_read, new_read, memory_order_release);
            g_overflow_count++;
        }

        for (size_t i = 0; i < samples; i++) {
            g_ring_buffer[write_pos] = g_audio_buffer[i];
            write_pos = (write_pos + 1) & RING_BUFFER_MASK;
        }
        atomic_store_explicit(&g_ring_write, write_pos, memory_order_release);
    }
#endif /* __ANDROID__ */

    return frames;
}

void audio_sample_callback(int16_t left, int16_t right) {
    (void)left;
    (void)right;
}
