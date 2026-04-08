#include "yage_internal.h"
#ifdef _WIN32
#  define strcasecmp _stricmp
#endif

YageCore*  g_current_core          = NULL;
char*      g_core_lib_path         = NULL;
uint32_t*  g_video_buffer          = NULL;
size_t     g_video_buffer_capacity = 0;
int16_t*   g_audio_buffer          = NULL;
int        g_audio_samples         = 0;
int        g_variables_dirty       = 1;
int        g_sgb_borders_enabled   = 1;
int        g_log_frame_count       = 0;

YageCore* yage_core_create(void) {
    YageCore* core = (YageCore*)calloc(1, sizeof(YageCore));
    if (!core) return NULL;

    g_video_buffer = (uint32_t*)malloc(VIDEO_BUFFER_SIZE * sizeof(uint32_t));
    g_video_buffer_capacity = VIDEO_BUFFER_SIZE;
    if (!g_video_buffer) {
        g_video_buffer_capacity = 0;
        free(core);
        return NULL;
    }

    g_audio_buffer = (int16_t*)malloc(AUDIO_BUFFER_SIZE * 2 * sizeof(int16_t));
    if (!g_audio_buffer) {
        free(g_video_buffer); g_video_buffer = NULL; g_video_buffer_capacity = 0;
        free(core);
        return NULL;
    }

    return core;
}

YAGE_API int yage_core_set_core(const char* path) {
    if (g_core_lib_path) { free(g_core_lib_path); g_core_lib_path = NULL; }
    if (path && path[0]) {
        g_core_lib_path = strdup(path);
        LOGI("Core selection: %s", g_core_lib_path);
    }
    return 0;
}

int yage_core_init(YageCore* core) {
    if (!core) return -1;

    const char* lib_name;
#ifdef _WIN32
    lib_name = g_core_lib_path ? g_core_lib_path : "mgba_libretro.dll";
#elif defined(__ANDROID__)
    lib_name = g_core_lib_path ? g_core_lib_path : "libmgba_libretro_android.so";
#else
    lib_name = g_core_lib_path ? g_core_lib_path : "libmgba_libretro.so";
#endif

    core->lib = LOAD_LIBRARY(lib_name);
    if (!core->lib) {
#ifdef _WIN32
        LOGE("Failed to load libretro core: %s (error %lu)", lib_name, GetLastError());
#else
        LOGE("Failed to load libretro core: %s (%s)", lib_name, dlerror());
#endif
        return -1;
    }

    #define LOAD_SYM(name) core->name = (name##_t)GET_PROC(core->lib, #name)
    LOAD_SYM(retro_init);
    LOAD_SYM(retro_deinit);
    LOAD_SYM(retro_reset);
    LOAD_SYM(retro_run);
    LOAD_SYM(retro_load_game);
    LOAD_SYM(retro_unload_game);
    LOAD_SYM(retro_serialize_size);
    LOAD_SYM(retro_serialize);
    LOAD_SYM(retro_unserialize);
    LOAD_SYM(retro_get_system_info);
    LOAD_SYM(retro_get_system_av_info);
    LOAD_SYM(retro_set_environment);
    LOAD_SYM(retro_set_video_refresh);
    LOAD_SYM(retro_set_audio_sample);
    LOAD_SYM(retro_set_audio_sample_batch);
    LOAD_SYM(retro_set_input_poll);
    LOAD_SYM(retro_set_input_state);
    LOAD_SYM(retro_get_memory_data);
    LOAD_SYM(retro_get_memory_size);
    LOAD_SYM(retro_cheat_reset);
    LOAD_SYM(retro_cheat_set);
    #undef LOAD_SYM

    if (!core->retro_init || !core->retro_run || !core->retro_load_game) {
        FREE_LIBRARY(core->lib); core->lib = NULL;
        return -1;
    }

    g_current_core = core;

    if (core->retro_set_environment)         core->retro_set_environment(environment_callback);
    if (core->retro_set_video_refresh)       core->retro_set_video_refresh(video_refresh_callback);
    if (core->retro_set_audio_sample)        core->retro_set_audio_sample(audio_sample_callback);
    if (core->retro_set_audio_sample_batch)  core->retro_set_audio_sample_batch(audio_sample_batch_callback);
    if (core->retro_set_input_poll)          core->retro_set_input_poll(input_poll_callback);
    if (core->retro_set_input_state)         core->retro_set_input_state(input_state_callback);

    core->retro_init();
    core->initialized = 1;
    return 0;
}

void yage_core_destroy(YageCore* core) {
    if (!core) return;

#ifndef _WIN32
    yage_frame_loop_stop(core);
#endif

    if (g_current_core == core) g_current_core = NULL;

#ifndef _WIN32
    atomic_store_explicit(&g_keys, 0, memory_order_relaxed);
#else
    g_keys = 0;
#endif

    yage_core_rewind_deinit(core);

#ifdef __ANDROID__
    shutdown_opensl_audio();
    if (g_hw_render_enabled &&
        g_egl_display != EGL_NO_DISPLAY &&
        g_egl_surface != EGL_NO_SURFACE &&
        g_egl_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface, g_egl_context);
        LOGI("destroy: EGL context re-bound for clean shutdown");
    }
#endif

    core_vars_clear();

    if (core->game_loaded && core->retro_unload_game) core->retro_unload_game();
    if (core->initialized  && core->retro_deinit)     core->retro_deinit();

#ifdef __ANDROID__
    hw_render_shutdown();
#endif

    if (core->lib)         FREE_LIBRARY(core->lib);
    if (core->save_dir)    free(core->save_dir);
    if (core->system_dir)  free(core->system_dir);
    if (core->rom_path)    free(core->rom_path);
    if (core->state_buffer) free(core->state_buffer);

    if (g_video_buffer) { free(g_video_buffer); g_video_buffer = NULL; g_video_buffer_capacity = 0; }
    if (g_audio_buffer) { free(g_audio_buffer); g_audio_buffer = NULL; }

    free(core);
}

int yage_core_load_rom(YageCore* core, const char* path) {
    if (!core || !core->initialized || !path) return -1;

    core->platform = YAGE_PLATFORM_UNKNOWN;
    g_width  = N64_WIDTH;
    g_height = N64_HEIGHT;

    const char* ext = strrchr(path, '.');
    if (ext) {
        if      (strcasecmp(ext, ".gba") == 0) { core->platform = YAGE_PLATFORM_GBA;  g_width = GBA_WIDTH;  g_height = GBA_HEIGHT; }
        else if (strcasecmp(ext, ".gbc") == 0) { core->platform = YAGE_PLATFORM_GBC;  g_width = GB_WIDTH;   g_height = GB_HEIGHT;  }
        else if (strcasecmp(ext, ".sgb") == 0) {
            core->platform = YAGE_PLATFORM_GB;
            if (g_sgb_borders_enabled) { g_width = SGB_WIDTH; g_height = SGB_HEIGHT; }
            else                        { g_width = GB_WIDTH;  g_height = GB_HEIGHT;  }
        }
        else if (strcasecmp(ext, ".gb") == 0)   { core->platform = YAGE_PLATFORM_GB;    g_width = GB_WIDTH;   g_height = GB_HEIGHT;   }
        else if (strcasecmp(ext, ".nes") == 0 || strcasecmp(ext, ".unf") == 0 ||
                 strcasecmp(ext, ".unif") == 0)  { core->platform = YAGE_PLATFORM_NES;   g_width = NES_WIDTH;  g_height = NES_HEIGHT;  }
        else if (strcasecmp(ext, ".sg") == 0)    { core->platform = YAGE_PLATFORM_SG1000; g_width = SMS_WIDTH; g_height = SMS_HEIGHT;  }
        else if (strcasecmp(ext, ".sfc") == 0 || strcasecmp(ext, ".smc") == 0)
                                                  { core->platform = YAGE_PLATFORM_SNES;  g_width = SNES_WIDTH; g_height = SNES_HEIGHT; }
        else if (strcasecmp(ext, ".sms") == 0)   { core->platform = YAGE_PLATFORM_SMS;   g_width = SMS_WIDTH;  g_height = SMS_HEIGHT;  }
        else if (strcasecmp(ext, ".gg") == 0)    { core->platform = YAGE_PLATFORM_GG;    g_width = GG_WIDTH;   g_height = GG_HEIGHT;   }
        else if (strcasecmp(ext, ".md") == 0 || strcasecmp(ext, ".gen") == 0 ||
                 strcasecmp(ext, ".smd") == 0 || strcasecmp(ext, ".bin") == 0)
                                                  { core->platform = YAGE_PLATFORM_MD;    g_width = MD_WIDTH;   g_height = MD_HEIGHT;   }
        else if (strcasecmp(ext, ".ngp") == 0 || strcasecmp(ext, ".ngc") == 0)
                                                  { core->platform = YAGE_PLATFORM_NGP;   g_width = NGP_WIDTH;  g_height = NGP_HEIGHT;  }
        else if (strcasecmp(ext, ".ws") == 0)    { core->platform = YAGE_PLATFORM_WS;    g_width = WSWAN_WIDTH; g_height = WSWAN_HEIGHT; }
        else if (strcasecmp(ext, ".wsc") == 0)   { core->platform = YAGE_PLATFORM_WSC;   g_width = WSWAN_WIDTH; g_height = WSWAN_HEIGHT; }
        else if (strcasecmp(ext, ".z64") == 0 || strcasecmp(ext, ".n64") == 0 ||
                 strcasecmp(ext, ".v64") == 0)   { core->platform = YAGE_PLATFORM_N64;   g_width = N64_WIDTH;  g_height = N64_HEIGHT;  }
    }

    g_color_correction_enabled = (core->platform == YAGE_PLATFORM_GB ||
                                   core->platform == YAGE_PLATFORM_GBC ||
                                   core->platform == YAGE_PLATFORM_GBA) ? 1 : 0;
    g_variables_dirty = 1;

    struct retro_game_info info = {0};
    info.path = path;

    void* rom_data = NULL;
    if (core->retro_get_system_info) {
        struct retro_system_info sys_info = {0};
        core->retro_get_system_info(&sys_info);
        if (!sys_info.need_fullpath) {
            FILE* f = fopen(path, "rb");
            if (f) {
                fseek(f, 0, SEEK_END);
                long sz = ftell(f);
                fseek(f, 0, SEEK_SET);
                if (sz > 0 && sz <= (long)(128 * 1024 * 1024)) {
                    rom_data = malloc((size_t)sz);
                    if (rom_data && fread(rom_data, 1, (size_t)sz, f) == (size_t)sz) {
                        info.data = rom_data;
                        info.size = (size_t)sz;
                        LOGI("Loaded ROM into memory: %zu bytes", info.size);
                    } else {
                        if (rom_data) free(rom_data);
                        rom_data = NULL;
                    }
                }
                fclose(f);
            }
        }
    }

    if (!core->retro_load_game(&info)) {
        if (rom_data) free(rom_data);
        LOGE("retro_load_game failed for: %s", path ? path : "(null)");
        return -1;
    }
    if (rom_data) free(rom_data);

#ifdef __ANDROID__
    if (g_hw_context_reset_pending &&
        g_egl_display != EGL_NO_DISPLAY &&
        g_egl_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(g_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        LOGI("HW render: EGL context released from load thread (context_reset deferred)");
    }
#endif

    if (core->rom_path) free(core->rom_path);
    core->rom_path = strdup(path);

    double reported_sample_rate = 32768.0;
#ifndef _WIN32
    g_core_frame_ns = DEFAULT_FRAME_NS;
#endif

    if (core->retro_get_system_av_info) {
        struct retro_system_av_info av_info;
        core->retro_get_system_av_info(&av_info);
        g_width  = (int)av_info.geometry.base_width;
        g_height = (int)av_info.geometry.base_height;
        reported_sample_rate = av_info.timing.sample_rate;
#ifdef __ANDROID__
        g_reported_rate = reported_sample_rate;
#endif
#ifndef _WIN32
        if (av_info.timing.fps > 1.0 && av_info.timing.fps < 240.0)
            g_core_frame_ns = (int64_t)(1000000000.0 / av_info.timing.fps);
#endif
        LOGI("AV Info: %ux%u, fps=%.2f, frame_ns=%lld, reported_sr=%.0f",
             g_width, g_height, av_info.timing.fps,
             (long long)g_core_frame_ns, reported_sample_rate);

        unsigned max_w = av_info.geometry.max_width  ? av_info.geometry.max_width  : (unsigned)g_width;
        unsigned max_h = av_info.geometry.max_height ? av_info.geometry.max_height : (unsigned)g_height;
        size_t needed = (size_t)max_w * max_h;
        if (needed > g_video_buffer_capacity && g_video_buffer) {
            uint32_t* new_buf = (uint32_t*)realloc(g_video_buffer, needed * sizeof(uint32_t));
            if (new_buf) { g_video_buffer = new_buf; g_video_buffer_capacity = needed; }
        }
    }

#ifdef __ANDROID__
    shutdown_opensl_audio();
    g_rate_detection_samples = 0;
    g_rate_detected          = 0;
    g_detected_rate          = 0;
    g_video_frames_total     = 0;
    g_monitor_frames         = 0;
    g_monitor_samples        = 0;
    g_frames_since_reinit    = 0;
    g_audio_started          = 0;
    g_audio_batch_count      = 0;
    g_overflow_count         = 0;
    g_log_frame_count        = 0;
    LOGI("Audio deferred: will init after 30 video frames (reported rate: %.0f Hz)",
         reported_sample_rate);
#else
    (void)reported_sample_rate;
#endif

    if (core->retro_serialize_size) {
        core->state_size = core->retro_serialize_size();
        if (core->state_size > 0) core->state_buffer = malloc(core->state_size);
    }

    core->game_loaded = 1;
    return 0;
}

int yage_core_load_bios(YageCore* core, const char* path) {
    (void)core; (void)path;
    return 0;
}

void yage_core_set_save_dir(YageCore* core, const char* path) {
    if (!core || !path) return;
    if (core->save_dir) free(core->save_dir);
    core->save_dir = strdup(path);
}

void yage_core_set_system_dir(YageCore* core, const char* path) {
    if (!core || !path) return;
    if (core->system_dir) free(core->system_dir);
    core->system_dir = strdup(path);
}

void yage_core_reset(YageCore* core) {
    if (!core || !core->game_loaded || !core->retro_reset) return;
    core->retro_reset();
}

void yage_core_run_frame(YageCore* core) {
    if (!core || !core->game_loaded || !core->retro_run) return;
    g_audio_samples = 0;
    core->retro_run();
}

void yage_core_set_keys(YageCore* core, uint32_t keys) {
    (void)core;
#ifndef _WIN32
    atomic_store_explicit(&g_keys, keys, memory_order_relaxed);
#else
    g_keys = keys;
#endif
    static unsigned log_count = 0;
    if (keys != 0 && (log_count++ % 60) == 0)
        LOGI("Input: yage_core_set_keys keys=0x%X", (unsigned)keys);
}

void yage_core_set_analog(YageCore* core, int16_t x, int16_t y) {
    (void)core;
#ifndef _WIN32
    atomic_store_explicit(&g_analog_x, x, memory_order_relaxed);
    atomic_store_explicit(&g_analog_y, y, memory_order_relaxed);
#else
    g_analog_x = x; g_analog_y = y;
#endif
}

YAGE_API void yage_core_set_touch(YageCore* core, int16_t x, int16_t y, int pressed) {
    (void)core;
#ifndef _WIN32
    atomic_store_explicit(&g_touch_x,    x,             memory_order_relaxed);
    atomic_store_explicit(&g_touch_y,    y,             memory_order_relaxed);
    atomic_store_explicit(&g_touch_down, (int16_t)pressed, memory_order_relaxed);
#else
    g_touch_x = x; g_touch_y = y; g_touch_down = (int16_t)pressed;
#endif
}

uint32_t* yage_core_get_video_buffer(YageCore* core) {
    (void)core; return g_video_buffer;
}

int yage_core_get_width(YageCore* core) {
    (void)core; return g_width;
}

int yage_core_get_height(YageCore* core) {
    (void)core; return g_height;
}

int16_t* yage_core_get_audio_buffer(YageCore* core) {
    (void)core; return g_audio_buffer;
}

int yage_core_get_audio_samples(YageCore* core) {
    (void)core; return g_audio_samples;
}

int yage_core_get_platform(YageCore* core) {
    if (!core) return YAGE_PLATFORM_UNKNOWN;
    return core->platform;
}

void yage_core_set_volume(YageCore* core, float volume) {
    (void)core;
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    g_volume = volume;
    LOGI("Volume set to %.2f", volume);
}

void yage_core_set_audio_enabled(YageCore* core, int enabled) {
    (void)core;
    g_audio_enabled = enabled ? 1 : 0;
    LOGI("Audio %s", enabled ? "enabled" : "disabled");
}

void yage_core_set_color_palette(YageCore* core, int palette_index,
                                  uint32_t color0, uint32_t color1,
                                  uint32_t color2, uint32_t color3) {
    (void)core;
    if (palette_index < 0) {
        g_palette_enabled = 0;
        LOGI("Color palette disabled");
    } else {
        g_palette_enabled = 1;
        #define ARGB_TO_ABGR(c) (((c) & 0xFF00FF00) | (((c) & 0x00FF0000) >> 16) | (((c) & 0x000000FF) << 16))
        g_palette_colors[0] = ARGB_TO_ABGR(color0);
        g_palette_colors[1] = ARGB_TO_ABGR(color1);
        g_palette_colors[2] = ARGB_TO_ABGR(color2);
        g_palette_colors[3] = ARGB_TO_ABGR(color3);
        #undef ARGB_TO_ABGR
        LOGI("Color palette set: #%06X #%06X #%06X #%06X",
             color0 & 0xFFFFFF, color1 & 0xFFFFFF, color2 & 0xFFFFFF, color3 & 0xFFFFFF);
    }
}

YAGE_API void yage_core_set_sgb_borders(YageCore* core, int enabled) {
    (void)core;
    g_sgb_borders_enabled = enabled ? 1 : 0;
    g_variables_dirty     = 1;
    LOGI("SGB borders %s", enabled ? "enabled" : "disabled");
}

#define GB_REG_SB  0xFF01
#define GB_REG_SC  0xFF02
#define GB_REG_IF  0xFF0F
#define SC_TRANSFER_START 0x80
#define SC_CLOCK_INTERNAL 0x01
#define IF_SERIAL         0x08

int yage_core_link_is_supported(YageCore* core) {
    (void)core;
    return g_io_ptr != NULL ? 1 : 0;
}

int yage_core_link_read_byte(YageCore* core, uint32_t addr) {
    (void)core;
    uint8_t* p = resolve_address(addr);
    if (!p) return -1;
    return (int)*p;
}

int yage_core_link_write_byte(YageCore* core, uint32_t addr, uint8_t value) {
    (void)core;
    uint8_t* p = resolve_address(addr);
    if (!p) return -1;
    *p = value;
    return 0;
}

int yage_core_link_get_transfer_status(YageCore* core) {
    (void)core;
    if (!g_io_ptr || g_io_start != 0xFF00) return -1;
    uint8_t* sc = resolve_address(GB_REG_SC);
    if (!sc) return -1;
    if (*sc & SC_TRANSFER_START) return (*sc & SC_CLOCK_INTERNAL) ? 1 : 0;
    return 0;
}

int yage_core_link_exchange_data(YageCore* core, uint8_t incoming) {
    (void)core;
    if (!g_io_ptr || g_io_start != 0xFF00) return -1;
    uint8_t* sb     = resolve_address(GB_REG_SB);
    uint8_t* sc     = resolve_address(GB_REG_SC);
    uint8_t* if_reg = resolve_address(GB_REG_IF);
    if (!sb || !sc || !if_reg) return -1;
    int outgoing = (int)*sb;
    *sb = incoming;
    *sc &= ~SC_TRANSFER_START;
    *if_reg |= IF_SERIAL;
    return outgoing;
}

int yage_core_read_memory(YageCore* core, uint32_t address,
                           int32_t count, uint8_t* buffer) {
    (void)core;
    if (!buffer || count <= 0) return -1;
    for (int32_t i = 0; i < count; i++) {
        uint8_t* p = resolve_address(address + (uint32_t)i);
        buffer[i] = p ? *p : 0;
    }
    return count;
}

int yage_core_get_memory_size(YageCore* core, int32_t region_id) {
    if (!core || !core->retro_get_memory_size) return 0;
    return (int)core->retro_get_memory_size((unsigned)region_id);
}

YAGE_API int32_t yage_gpu_texture_is_ready(YageCore* core) {
#ifdef __ANDROID__
    (void)core;
    return gpu_hwbuffer_is_ready();
#else
    (void)core;
    return 0;
#endif
}

YAGE_API int yage_gpu_texture_init(YageCore* core, uint32_t width, uint32_t height) {
#ifdef __ANDROID__
    (void)core;
    return gpu_hwbuffer_init(width, height);
#else
    (void)core;
    (void)width;
    (void)height;
    return -1;
#endif
}

YAGE_API void yage_gpu_texture_shutdown(YageCore* core) {
#ifdef __ANDROID__
    (void)core;
    gpu_hwbuffer_shutdown();
#else
    (void)core;
#endif
}

YAGE_API uint32_t yage_gpu_texture_get_id(YageCore* core) {
#ifdef __ANDROID__
    (void)core;
    return (uint32_t)gpu_hwbuffer_get_texture_id();
#else
    (void)core;
    return 0;
#endif
}

YAGE_API int32_t yage_gpu_texture_is_dirty(YageCore* core) {
#ifdef __ANDROID__
    (void)core;
    return (int32_t)gpu_hwbuffer_is_dirty();
#else
    (void)core;
    return 0;
#endif
}

YAGE_API const char* yage_core_get_options_json(YageCore* core) {
    (void)core;
    return options_ui_get_json();
}

YAGE_API int yage_core_set_option(YageCore* core, const char* key, const char* value) {
    (void)core;
    if (!key || !value) return -1;
    core_vars_set(key, value);
    g_variables_dirty = 1;
    return options_ui_set_value(key, value);
}

YAGE_API const char* yage_core_get_option(YageCore* core, const char* key) {
    (void)core;
    if (!key) return NULL;
    return options_ui_get_value(key);
}
