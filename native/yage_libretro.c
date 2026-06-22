/*
 * YAGE Libretro Wrapper — Core Lifecycle & Orchestration
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * MODULE ARCHITECTURE
 * ══════════════════════════════════════════════════════════════════════════════
 *   yage_libretro.c      (this file) — Core lifecycle, API orchestration
 *   yage_core_vars.c     — Core option variable storage & parsing
 *   yage_input.c         — Input callbacks (joypad/analog/touch)
 *   yage_callbacks.c     — Memory-map helpers & logging bridge
 *   yage_hw_render.c     — EGL/OpenGL ES context (Android only)
 *   yage_audio.c         — OpenSL ES audio + callbacks
 *   yage_video.c         — Video processing + ANativeWindow blit
 *   yage_frame_loop.c    — Native frame-loop thread
 *   yage_state.c         — Save state, rewind, SRAM, cheat codes
 *   yage_env_callback.c  — Libretro environment_callback
 */

#include "yage_internal.h"
#ifdef _WIN32
#  define strcasecmp _stricmp
#else
#  include <sys/mman.h>
#  include <sys/stat.h>
#  include <fcntl.h>
#  include <unistd.h>
#endif

/* Largest commercial cart we ever need to buffer: 512 MiB (4 Gbit NDS).
 * Anything bigger is rejected loudly instead of silently skipped — a silent
 * skip is how Dragon Quest IX (256 MiB) black-screened under the old
 * 128 MiB cap. */
#define YAGE_MAX_ROM_SIZE ((size_t)512 * 1024 * 1024)

static void yage_rom_data_free(YageCore* core);

/* ══════════════════════════════════════════════════════════════════════
 * Core-level globals (owned by this file)
 * ══════════════════════════════════════════════════════════════════════ */

YageCore*  g_current_core          = NULL;
char*      g_core_lib_path         = NULL;
uint32_t*  g_video_buffer          = NULL;
size_t     g_video_buffer_capacity = 0;
int16_t*   g_audio_buffer          = NULL;
int        g_audio_samples         = 0;
int        g_variables_dirty       = 1;
int        g_sgb_borders_enabled   = 1;
int        g_log_frame_count       = 0;
/* Set to 1 while inside retro_load_game(). Used by the SET_HW_RENDER env
 * callback to decide whether it is safe to fire context_reset immediately
 * (libretro spec forbids context_reset during retro_load_game — calling it
 * there can SIGSEGV in cores that lazy-init GL state). When SET_HW_RENDER
 * fires outside retro_load_game (e.g. melonDS, which negotiates GL during
 * retro_run), context_reset can and must run synchronously so the core's
 * very next GL call sees valid shader/VAO/UBO IDs. */
int        g_in_load_game          = 0;

/* ══════════════════════════════════════════════════════════════════════
 * Core lifecycle
 * ══════════════════════════════════════════════════════════════════════ */

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

    /* M27: optional melonDS deferred-GL2D hooks (NULL on every other core).
     * The two callback setters share one typedef, so they can't use LOAD_SYM
     * (it token-pastes "_t" onto the symbol name). */
    LOAD_SYM(melonds_m27_set_enabled);
    LOAD_SYM(melonds_m27_has_pending);
    LOAD_SYM(melonds_m27_execute);
    core->melonds_m27_set_kick_callback =
        (melonds_m27_set_cb_t)GET_PROC(core->lib, "melonds_m27_set_kick_callback");
    core->melonds_m27_set_wait_callback =
        (melonds_m27_set_cb_t)GET_PROC(core->lib, "melonds_m27_set_wait_callback");
    if (core->melonds_m27_set_enabled && core->melonds_m27_execute &&
        core->melonds_m27_set_kick_callback && core->melonds_m27_set_wait_callback) {
        LOGI("Core exports M27 deferred-GL2D hooks (set_enabled/has_pending/execute/kick/wait)");
    }
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
        /* HW-render cores (mupen64plus-next GLideN64, Beetle PSX HW) tear
         * down GL resources inside retro_unload_game / retro_deinit, so
         * the context must be current on THIS thread first.  The frame
         * loop thread released it on exit (see frame_loop_thread), so this
         * rebind succeeds deterministically. */
        if (eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface,
                           g_egl_context)) {
            LOGI("destroy: EGL context re-bound for clean shutdown");
        } else {
            LOGE("destroy: eglMakeCurrent failed (err=0x%x) — core GL "
                 "teardown will run without a current context",
                 (unsigned)eglGetError());
        }
    }
#endif

    core_vars_clear();

    if (core->game_loaded && core->retro_unload_game) core->retro_unload_game();
    if (core->initialized  && core->retro_deinit)     core->retro_deinit();

    /* The core's libretro memory descriptors point into RAM it just freed.
     * Reset the table so a subsequently loaded core can never resolve
     * RetroAchievements reads through these now-dangling pointers. */
    g_mem_region_count = 0;
    g_io_ptr   = NULL;
    g_io_start = 0;
    g_io_len   = 0;

    /* The game is unloaded — now it is safe to drop the ROM image the core
     * may have been reading from (e.g. melonDS retro_reset). */
    yage_rom_data_free(core);

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

/* Release the ROM image owned by the core (no-op if none). Safe to call
 * only after the game is unloaded / before a new ROM replaces it — cores
 * may hold pointers into this buffer while a game is running. */
static void yage_rom_data_free(YageCore* core) {
    if (!core || !core->rom_data) return;
    free(core->rom_data);
    core->rom_data      = NULL;
    core->rom_data_size = 0;
}

/* Load the ROM file into core->rom_data / core->rom_data_size.
 *
 * Uses a WRITABLE, private RAM buffer (malloc) with a 64-byte zero-padded
 * tail. This previously used a read-only, file-backed mmap on POSIX, which
 * is a well-known cause of core load crashes (SIGSEGV/SIGBUS):
 *
 *   1. Cores frequently modify `info->data` IN PLACE — byte-swapping
 *      .v64/.n64, de-interleaving SNES, header/checksum fixups — and a
 *      read-only mapping faults on the first write.
 *   2. Cores commonly OVER-READ a few bytes past the ROM end (32-bit word or
 *      SIMD header scans). On a file-backed mapping an over-read that crosses
 *      the final mapped page raises SIGBUS; the 64-byte zero tail keeps those
 *      reads in bounds.
 *
 * Trade-off: the cart is resident in RAM (bounded by YAGE_MAX_ROM_SIZE). A
 * huge cart on a memory-constrained device now fails the allocation and the
 * load returns -1 gracefully instead of risking a crash. Returns 0 on
 * success. */
static int yage_rom_data_load(YageCore* core, const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return -1;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    long sz = ftell(f);
    if (sz <= 0 || (size_t)sz > YAGE_MAX_ROM_SIZE) { fclose(f); return -1; }
    rewind(f);

    const size_t pad = 64;
    void* buf = malloc((size_t)sz + pad);
    if (!buf) { fclose(f); return -1; }

    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    if (got != (size_t)sz) { free(buf); return -1; }

    memset((char*)buf + sz, 0, pad);   /* over-read guard tail */
    core->rom_data      = buf;
    core->rom_data_size = (size_t)sz;
    return 0;
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
        else if (strcasecmp(ext, ".a26") == 0)   { core->platform = YAGE_PLATFORM_A2600; g_width = A2600_WIDTH; g_height = A2600_HEIGHT; }
        else if (strcasecmp(ext, ".vb") == 0)    { core->platform = YAGE_PLATFORM_VB;    g_width = VB_WIDTH;   g_height = VB_HEIGHT;   }
        else if (strcasecmp(ext, ".tic") == 0)   { core->platform = YAGE_PLATFORM_TIC80; g_width = TIC80_WIDTH; g_height = TIC80_HEIGHT; }
        else if (strcasecmp(ext, ".p8") == 0)    { core->platform = YAGE_PLATFORM_PICO8; g_width = PICO8_WIDTH; g_height = PICO8_HEIGHT; }
        else if (strcasecmp(ext, ".png") == 0) {
            /* PICO-8 .p8.png cart — detect double extension. */
            size_t plen = strlen(path);
            if (plen >= 7 && strcasecmp(path + plen - 7, ".p8.png") == 0) {
                core->platform = YAGE_PLATFORM_PICO8;
                g_width = PICO8_WIDTH; g_height = PICO8_HEIGHT;
            }
        }
        else if (strcasecmp(ext, ".nds") == 0)   { core->platform = YAGE_PLATFORM_NDS;   g_width = NDS_WIDTH;  g_height = NDS_HEIGHT;  }
        else if (strcasecmp(ext, ".z64") == 0 || strcasecmp(ext, ".n64") == 0 ||
                 strcasecmp(ext, ".v64") == 0)   { core->platform = YAGE_PLATFORM_N64;   g_width = N64_WIDTH;  g_height = N64_HEIGHT;  }
        else if (strcasecmp(ext, ".cue") == 0 || strcasecmp(ext, ".chd") == 0 ||
                 strcasecmp(ext, ".pbp") == 0 || strcasecmp(ext, ".iso") == 0)
                                                  { core->platform = YAGE_PLATFORM_PS1;   g_width = PSX_WIDTH;  g_height = PSX_HEIGHT;  }
        else if (strcasecmp(ext, ".int") == 0 || strcasecmp(ext, ".itv") == 0)
                                                  { core->platform = YAGE_PLATFORM_INTV;  g_width = 160;        g_height = 96;          }
    }

    /* Generalized color tuning: GB family keeps its mild default boost;
     * everything else starts neutral and is configured from Dart via
     * yage_video_set_color_tuning (see yage_video.c). */
    yage_video_apply_default_tuning(core->platform);
    g_variables_dirty = 1;

#ifdef __ANDROID__
    if (core->platform == YAGE_PLATFORM_NDS &&
        g_core_lib_path && strstr(g_core_lib_path, "melonds")) {
#  if defined(__arm__) && !defined(__aarch64__)
        LOGI("melonDS ABI: armeabi-v7a/AArch32 build; staged JIT backend is available when enabled by core options");
#  elif defined(__aarch64__)
        LOGI("melonDS ABI: arm64-v8a/AArch64 build; JIT backend is available when enabled by core options");
#  elif defined(__x86_64__)
        LOGI("melonDS ABI: x86_64 build; JIT backend is available when enabled by core options");
#  else
        LOGI("melonDS ABI: no known JIT backend for this Android ABI, using interpreter");
#  endif
    }
#endif

    /* ── ROM data handoff ────────────────────────────────────────────────
     * Cores with need_fullpath=false (melonDS, mGBA, …) REQUIRE the ROM
     * contents in info.data; they never open info.path themselves. Two
     * hard-won rules live here:
     *
     *  1. NO silent skip on big ROMs. The old 128 MiB cap quietly left
     *     info.data = NULL for larger files, so melonDS direct-booted
     *     FreeBIOS with an all-zero cart buffer — Dragon Quest IX (256 MiB)
     *     ran at a healthy 60 fps showing nothing but DispCnt=00000000
     *     black screens. Oversized/unreadable ROMs now FAIL the load loudly.
     *
     *  2. The buffer (and the retro_game_info struct itself) must OUTLIVE
     *     retro_load_game. melonDS caches the info pointer and re-reads
     *     info->data inside retro_reset(); the old free-after-load made
     *     in-game reset read freed memory. Both now live in YageCore and
     *     are released in yage_core_destroy after retro_unload_game. */
    yage_rom_data_free(core);
    struct retro_game_info* info = &core->game_info;
    memset(info, 0, sizeof(*info));
    info->path = path;

    int core_needs_data = 0;
    if (core->retro_get_system_info) {
        struct retro_system_info sys_info = {0};
        core->retro_get_system_info(&sys_info);
        core_needs_data = !sys_info.need_fullpath;
    }

    if (core_needs_data) {
        if (yage_rom_data_load(core, path) != 0) {
            LOGE("Failed to buffer ROM (missing, unreadable, or >%zu MiB): %s",
                 YAGE_MAX_ROM_SIZE / (1024 * 1024), path);
            return -1;
        }
        info->data = core->rom_data;
        info->size = core->rom_data_size;
        LOGI("Loaded ROM into memory: %zu bytes", info->size);
    }

    g_in_load_game = 1;
    yage_env_frame_time_reset();
    bool load_ok = core->retro_load_game(info);
    g_in_load_game = 0;
    if (!load_ok) {
        yage_rom_data_free(core);
        LOGE("retro_load_game failed for: %s", path ? path : "(null)");
        return -1;
    }

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
    /* The Dart-side `path` string does not outlive this call, but cores may
     * re-read the cached retro_game_info later — keep it pointing at our
     * own persistent copy. */
    core->game_info.path = core->rom_path;

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

#ifdef __ANDROID__
        /* ── HW render geometry decoupling ──────────────────────────────
         * We deliberately do NOT recreate the EGL surface to match AV info
         * here.  Many cores (notably melonDS) report the *maximum* possible
         * geometry in AV info (e.g. 1024×1536 = 4× upscale) even when the
         * user-selected scale option produces a smaller render (256×384 at
         * 1×).  If we sized the EGL window to AV info max, the core's
         * `glViewport(0, 0, screen_layout_data.buffer_width, ...)` would
         * only fill the bottom-left corner of an oversized window — the
         * rest would stay cleared to (0,0,0,0).
         *
         * The EGL surface size is set once at SET_HW_RENDER time using
         * the platform-native dimensions from the file-extension table
         * above (NDS_WIDTH×NDS_HEIGHT for .nds, N64_WIDTH×N64_HEIGHT for
         * .z64, etc.). This matches the core's actual render output 1:1
         * for the default scale.  If the user later picks a higher GL
         * upscale via core options, the core fires SET_GEOMETRY and we
         * handle the resize there without destroying the EGL context. */
#endif
    }

#ifdef __ANDROID__
    shutdown_opensl_audio();
    atomic_store_explicit(&g_core_frames_total, 0, memory_order_relaxed);
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
    LOGI("Audio deferred: will init after 30 emulated frames (reported rate: %.0f Hz)",
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

/* ── JIT warm-up ─────────────────────────────────────────────────────────────
 * MUST be invoked by the frontend AFTER the battery save (SRAM) has been
 * restored into RETRO_MEMORY_SAVE_RAM, and BEFORE the frame loop starts.
 *
 * Previously this pre-roll ran at the tail of yage_core_load_rom — i.e. BEFORE
 * the frontend's loadSram() bridge had a chance to inject the .sav. Games that
 * probe their save during early boot (notably Pokémon's Continue / New Game
 * check) then read an all-zero SRAM, conclude "no save exists", and the freshly
 * restored .sav is effectively ignored — the title screen shows New Game even
 * though a valid save was on disk. Running the warm-up only after SRAM restore
 * guarantees the very first emulated frame already sees the real save data. */
void yage_core_warm_jit(YageCore* core) {
    if (!core || !core->game_loaded || !core->retro_run) return;
#ifdef __ANDROID__
    /* ── JIT pre-roll ────────────────────────────────────────────────────────
     * Run N frames in a tight loop while the "Loading" screen is still up
     * to warm the JIT cache so the first real gameplay frames are rendered
     * at full speed instead of the usual 5–10 s of <20 fps stutter at boot.
     *
     * Per-platform pre-roll length (cost / benefit balance):
     *   * 60 — heavy ARM JIT cores: melonDS (NDS), Beetle PSX SW (PS1 HLE)
     *   * 30 — medium JIT cores: mGBA (GBA), Snes9x2010, FCEUmm
     *   * 10 — already-fast dynarec cores: mupen64plus-next (N64)
     *   *  0 — interpreter-only cores with no warm-up: NES/A2600/etc. or
     *          any core where pre-roll has shown to cause issues.
     * Cost: each frame is ~16–80 ms of CPU; 60 frames ≈ 1 s extra "Loading…".
     *
     * HW render cores (mupen64plus-next, Beetle PSX HW): we must bind the
     * EGL context to the load thread for the duration of the pre-roll AND
     * fire context_reset before the first retro_run, otherwise the GL
     * plugin (e.g. GLideN64) calls OpenGL with no current context, derefs
     * a NULL function pointer, and crashes with SIGSEGV. After pre-roll we
     * release the context again and clear the pending flag so the frame
     * loop thread doesn't double-fire context_reset.
     *
     * Audio path: g_in_preroll = 1 makes audio_sample_batch_callback drop
     * every batch.  No rate detection, no OpenSL init, no ring writes during
     * pre-roll.  This guarantees that real gameplay starts with a clean
     * ring and the deferred audio-init window begins from zero.
     *
     * Video path: frames write to g_video_buffer (harmless; Dart hasn't
     * attached the texture yet at this point in start-up).
     */
    int preroll_frames = 30;  /* sensible default for unknown cores */

    /* HW-render cores (mupen64plus-next, Beetle PSX HW) must NOT be pre-rolled
     * on the load thread.  The native window is not yet attached when
     * yage_core_load_rom runs, so the EGL context is pbuffer-only.  Pre-rolling
     * fires context_reset on that pbuffer context; then hw_render_readback fires
     * it a SECOND time once the native window is ready (frame-loop thread).
     * That double-reset leaves GLideN64 / Reicast with dangling GL resources
     * from the first context, producing a blank or corrupted 3D display.
     *
     * The frame-loop's deferred-context-bind path (see yage_frame_loop.c)
     * lets hw_render_readback fire context_reset exactly once on the correct
     * window-surface context — no pre-roll needed. */
    if (g_hw_render_enabled) preroll_frames = 0;

    if (g_core_lib_path) {
        /* melonDS *lazily* negotiates SET_HW_RENDER from inside the first
         * retro_run (not from retro_load_game), so g_hw_render_enabled is
         * still 0 at this point even though the core will use OpenGL.
         * Pre-rolling on the load thread would trigger the lazy negotiation
         * there, create an EGL context with no native window (pbuffer), and
         * then run render_opengl_frame against uninitialized GL handles
         * (shader[]=0, vao=0, ubo=0) — producing GL_INVALID_VALUE every
         * frame and a black screen.  Force preroll off for melonDS so the
         * first retro_run lands on the frame loop thread where the native
         * window is available and SET_HW_RENDER creates a window surface
         * with a synchronous context_reset (see env_callback). */
        if (strstr(g_core_lib_path, "melonds")) {
            preroll_frames = 0;
        } else if (!g_hw_render_enabled &&
            (strstr(g_core_lib_path, "mednafen_psx") ||
             strstr(g_core_lib_path, "beetle_psx"))) {
            /* PSX needs 60 frames: CD-ROM state machine + SPU ring fill. */
            preroll_frames = 60;
        } else if (!g_hw_render_enabled &&
                   strstr(g_core_lib_path, "mupen64plus")) {
            preroll_frames = 10;
        } else if (strstr(g_core_lib_path, "stella") ||
                   strstr(g_core_lib_path, "freeintv") ||
                   strstr(g_core_lib_path, "fceumm")  ||
                   strstr(g_core_lib_path, "mednafen_vb") ||
                   strstr(g_core_lib_path, "mednafen_ngp") ||
                   strstr(g_core_lib_path, "mednafen_wswan")) {
            preroll_frames = 15;
        }
    }

    if (core->retro_run && preroll_frames > 0) {
        int hw_bound = 0;
        if (g_hw_render_enabled &&
            g_egl_display != EGL_NO_DISPLAY &&
            g_egl_surface != EGL_NO_SURFACE &&
            g_egl_context != EGL_NO_CONTEXT) {
            if (eglMakeCurrent(g_egl_display, g_egl_surface,
                                g_egl_surface, g_egl_context)) {
                hw_bound = 1;
                if (g_hw_context_reset_pending && g_hw_render_cb.context_reset) {
                    g_hw_context_reset_pending = 0;
                    LOGI("HW render: firing context_reset on load thread for pre-roll");
                    g_hw_render_cb.context_reset();
                }
            } else {
                /* Couldn't rebind — skip pre-roll entirely.  Running
                 * retro_run for a HW-render core without a bound context
                 * would deref NULL GL function pointers (mupen64plus-next
                 * GLideN64 backend) and SIGSEGV. */
                LOGE("HW render: eglMakeCurrent failed on load thread (err=0x%x); "
                     "skipping JIT pre-roll for this core",
                     (unsigned)eglGetError());
                goto skip_preroll;
            }
        }

        g_in_preroll = 1;  /* audio callback drops everything from here */
        int pf;
        for (pf = 0; pf < preroll_frames; pf++) {
            yage_env_frame_time_tick();
            core->retro_run();
        }
        g_in_preroll = 0;

        /* Belt-and-braces: even though g_in_preroll suppressed audio writes,
         * make sure the ring + counters look fresh in case some path slipped
         * through (e.g. core changed audio behaviour mid-frame). */
        atomic_store(&g_ring_read,  0);
        atomic_store(&g_ring_write, 0);
        atomic_store_explicit(&g_core_frames_total, 0, memory_order_relaxed);
        g_video_frames_total     = 0;
        g_rate_detection_samples = 0;
        g_audio_batch_count      = 0;
        LOGI("JIT pre-roll: ran %d frames to warm cache%s",
             preroll_frames,
             hw_bound ? " (HW render context bound)" : "");

        if (hw_bound) {
            /* Release the context so the frame loop thread can take
             * ownership when it starts.  context_reset has already been
             * fired above; the frame loop thread sees g_hw_context_reset_pending
             * = 0 and skips re-firing it. */
            eglMakeCurrent(g_egl_display, EGL_NO_SURFACE,
                            EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
    }
skip_preroll:;
#endif
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

/* ══════════════════════════════════════════════════════════════════════
 * Per-frame execution
 * ══════════════════════════════════════════════════════════════════════ */

void yage_core_reset(YageCore* core) {
    if (!core || !core->game_loaded || !core->retro_reset) return;
    core->retro_reset();
}

void yage_core_run_frame(YageCore* core) {
    if (!core || !core->game_loaded || !core->retro_run) return;
    g_audio_samples = 0;
    yage_env_frame_time_tick();
    core->retro_run();
}

/* ══════════════════════════════════════════════════════════════════════
 * Input setters
 * ══════════════════════════════════════════════════════════════════════ */

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

void yage_core_set_analog_index(YageCore* core, int32_t index, int16_t x, int16_t y) {
    (void)core;
    if (index == RETRO_DEVICE_INDEX_ANALOG_RIGHT) {
#ifndef _WIN32
        atomic_store_explicit(&g_analog_right_x, x, memory_order_relaxed);
        atomic_store_explicit(&g_analog_right_y, y, memory_order_relaxed);
#else
        g_analog_right_x = x; g_analog_right_y = y;
#endif
        return;
    }
    yage_core_set_analog(core, x, y);
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

/* ══════════════════════════════════════════════════════════════════════
 * Buffer getters
 * ══════════════════════════════════════════════════════════════════════ */

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

/* ══════════════════════════════════════════════════════════════════════
 * Audio / display configuration
 * ══════════════════════════════════════════════════════════════════════ */

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

/* ══════════════════════════════════════════════════════════════════════
 * Link cable — GB/GBC SIO register access
 * ══════════════════════════════════════════════════════════════════════ */

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

/* ══════════════════════════════════════════════════════════════════════
 * Memory read API (RetroAchievements)
 * ══════════════════════════════════════════════════════════════════════ */

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

/* ══════════════════════════════════════════════════════════════════════
 * GPU Zero-Copy Texture Rendering (Android)
 * ══════════════════════════════════════════════════════════════════════ */

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

/* ══════════════════════════════════════════════════════════════════════
 * Dynamic Core Options UI
 * ══════════════════════════════════════════════════════════════════════ */

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
