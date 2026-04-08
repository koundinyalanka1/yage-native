#include "yage_internal.h"

float g_volume       = 1.0f;
int   g_audio_enabled = 1;

#ifdef __ANDROID__

static SLObjectItf g_sl_engine     = NULL;
static SLEngineItf g_sl_engine_itf = NULL;
static SLObjectItf g_sl_output_mix = NULL;
static SLObjectItf g_sl_player     = NULL;
static SLPlayItf   g_sl_play_itf   = NULL;
static SLAndroidSimpleBufferQueueItf g_sl_buffer_queue = NULL;

static int16_t* g_sl_buffers[AUDIO_BUFFERS] = {NULL, NULL, NULL, NULL};
static int      g_sl_buffer_index = 0;
static atomic_int g_sl_initialized = 0;

static int16_t g_ring_buffer[RING_BUFFER_SIZE];
atomic_int g_ring_read  = 0;
atomic_int g_ring_write = 0;

static int16_t g_last_sample_l = 0;
static int16_t g_last_sample_r = 0;
int g_underrun_count = 0;
int g_audio_started  = 0;
static double g_audio_sample_rate = 32768.0;

int    g_rate_detection_samples = 0;
int    g_rate_detected          = 0;
double g_detected_rate          = 0;
double g_reported_rate          = 32768.0;

int g_monitor_frames      = 0;
int g_monitor_samples     = 0;
int g_frames_since_reinit = 0;

int g_audio_batch_count = 0;
int g_overflow_count    = 0;

#define PREBUFFER_SAMPLES (AUDIO_BUFFER_FRAMES * 3)

static void shutdown_opensl_audio_impl(void);
static int  init_opensl_audio_impl(double sample_rate);

static double classify_sample_rate(double samples_per_frame) {
    if (samples_per_frame > 1600) return 131072.0;
    if (samples_per_frame > 850)  return 65536.0;
    if (samples_per_frame > 770)  return 48000.0;
    if (samples_per_frame > 640)  return 44100.0;
    return 32768.0;
}

int ring_buffer_available(void) {
    int write_pos = atomic_load_explicit(&g_ring_write, memory_order_acquire);
    int read_pos  = atomic_load_explicit(&g_ring_read,  memory_order_acquire);
    return (write_pos - read_pos + RING_BUFFER_SIZE) & RING_BUFFER_MASK;
}

static inline int ring_buffer_free(void) {
    return RING_BUFFER_SIZE - 1 - ring_buffer_available();
}

static void sl_buffer_callback(SLAndroidSimpleBufferQueueItf bq, void* context) {
    (void)context;

    if (!atomic_load_explicit(&g_sl_initialized, memory_order_acquire)) return;

    int16_t* buffer = g_sl_buffers[g_sl_buffer_index];
    if (!buffer) return;
    g_sl_buffer_index = (g_sl_buffer_index + 1) % AUDIO_BUFFERS;

    int samples_needed = AUDIO_BUFFER_FRAMES * 2; 
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

    for (int i = 0; i < samples_needed; i += 2) {
        if (available >= 2) {
            g_last_sample_l = g_ring_buffer[read_pos];
            read_pos = (read_pos + 1) & RING_BUFFER_MASK;
            g_last_sample_r = g_ring_buffer[read_pos];
            read_pos = (read_pos + 1) & RING_BUFFER_MASK;
            available -= 2;
            g_underrun_count = 0;
        } else {
            g_underrun_count++;
            if (g_underrun_count < 64) {
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
        SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE, AUDIO_BUFFERS
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

    const SLInterfaceID ids[] = {SL_IID_BUFFERQUEUE};
    const SLboolean req[]     = {SL_BOOLEAN_TRUE};

    result = (*g_sl_engine_itf)->CreateAudioPlayer(g_sl_engine_itf, &g_sl_player,
        &audio_src, &audio_sink, 1, ids, req);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to create audio player"); return -1; }

    result = (*g_sl_player)->Realize(g_sl_player, SL_BOOLEAN_FALSE);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to realize audio player"); return -1; }

    result = (*g_sl_player)->GetInterface(g_sl_player, SL_IID_PLAY, &g_sl_play_itf);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to get play interface"); return -1; }

    result = (*g_sl_player)->GetInterface(g_sl_player, SL_IID_BUFFERQUEUE, &g_sl_buffer_queue);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to get buffer queue interface"); return -1; }

    for (int i = 0; i < AUDIO_BUFFERS; i++) {
        g_sl_buffers[i] = (int16_t*)calloc(AUDIO_BUFFER_FRAMES * 2, sizeof(int16_t));
        if (!g_sl_buffers[i]) {
            LOGE("Failed to allocate audio buffer");
            for (int j = 0; j < i; j++) { free(g_sl_buffers[j]); g_sl_buffers[j] = NULL; }
            return -1;
        }
    }

    result = (*g_sl_buffer_queue)->RegisterCallback(g_sl_buffer_queue, sl_buffer_callback, NULL);
    if (result != SL_RESULT_SUCCESS) { LOGE("Failed to register callback"); return -1; }

    
    atomic_store_explicit(&g_sl_initialized, 1, memory_order_release);

    result = (*g_sl_play_itf)->SetPlayState(g_sl_play_itf, SL_PLAYSTATE_PLAYING);
    if (result != SL_RESULT_SUCCESS) {
        LOGE("Failed to start playback");
        atomic_store_explicit(&g_sl_initialized, 0, memory_order_release);
        return -1;
    }

    for (int i = 0; i < AUDIO_BUFFERS; i++) {
        (*g_sl_buffer_queue)->Enqueue(g_sl_buffer_queue, g_sl_buffers[i],
            AUDIO_BUFFER_FRAMES * 2 * sizeof(int16_t));
    }

    LOGI("OpenSL ES audio initialized: %.0fHz stereo, %d buffers x %d frames",
         sample_rate, AUDIO_BUFFERS, AUDIO_BUFFER_FRAMES);
    return 0;
}

int init_opensl_audio(double sample_rate) {
    return init_opensl_audio_impl(sample_rate);
}

static void shutdown_opensl_audio_impl(void) {
    atomic_store_explicit(&g_sl_initialized, 0, memory_order_release);

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
    for (int i = 0; i < AUDIO_BUFFERS; i++) {
        if (g_sl_buffers[i]) { free(g_sl_buffers[i]); g_sl_buffers[i] = NULL; }
    }

    atomic_store(&g_ring_read, 0);
    atomic_store(&g_ring_write, 0);
    g_last_sample_l = 0;
    g_last_sample_r = 0;
    g_underrun_count = 0;
    g_audio_started  = 0;

    g_sl_play_itf     = NULL;
    g_sl_buffer_queue = NULL;
    g_sl_engine_itf   = NULL;
}

void shutdown_opensl_audio(void) {
    shutdown_opensl_audio_impl();
}

#endif 

size_t audio_sample_batch_callback(const int16_t* data, size_t frames) {
    if (!data || !g_audio_buffer) return frames;

    size_t samples = frames * 2; 
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
    
    if (!g_rate_detected) {
        g_rate_detection_samples += (int)frames;

        if (g_video_frames_total >= 30) {
            double avg_spf = (g_video_frames_total > 0)
                ? (double)g_rate_detection_samples / g_video_frames_total
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
            g_frames_since_reinit = g_video_frames_total;
            g_monitor_frames      = g_video_frames_total;
            g_monitor_samples     = 0;
        }
        return frames;
    }

    
    g_monitor_samples += (int)frames;
    {
        int vframes_in_window   = g_video_frames_total - g_monitor_frames;
        int vframes_since_reinit = g_video_frames_total - g_frames_since_reinit;

        if (vframes_in_window >= 120) {
            double avg_spf   = (vframes_in_window > 0)
                ? (double)g_monitor_samples / vframes_in_window : 0;
            double core_fps  = 1000000000.0 / (double)g_core_frame_ns;
            double new_rate  = avg_spf * core_fps;
            double ratio     = (g_detected_rate > 0) ? new_rate / g_detected_rate : 0;

            if ((ratio < 0.95 || ratio > 1.05) && vframes_since_reinit > 180) {
                LOGI("Rate change detected: %.0f → %.0f Hz (%.1f spf × %.1f fps)",
                     g_detected_rate, new_rate, avg_spf, core_fps);
                g_detected_rate       = new_rate;
                init_opensl_audio(new_rate);
                g_frames_since_reinit = g_video_frames_total;
            }

            g_monitor_frames  = g_video_frames_total;
            g_monitor_samples = 0;
        }
    }

    
    g_audio_batch_count++;
    if (g_audio_batch_count >= 60) {
        g_audio_batch_count = 0;
        if (g_overflow_count > 0) {
            LOGI("Audio: %zu frames/batch, overflows: %d, rate: %.0f",
                 frames, g_overflow_count, g_detected_rate);
            g_overflow_count = 0;
        }
    }

    
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
#endif 

    return frames;
}

void audio_sample_callback(int16_t left, int16_t right) {
    (void)left;
    (void)right;
}
