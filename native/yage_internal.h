/*
 * YAGE Internal Header
 *
 * Comprehensive shared header for all YAGE native modules.
 * Included by every .c module EXCEPT those noting otherwise.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * MODULE ARCHITECTURE
 * ══════════════════════════════════════════════════════════════════════════════
 *   yage_libretro.c      — Core lifecycle and orchestration
 *   yage_core_vars.c     — Core option variable storage & parsing
 *   yage_input.c         — Input callbacks (joypad/analog/touch)
 *   yage_callbacks.c     — Memory-map helpers & logging bridge
 *   yage_hw_render.c     — EGL/OpenGL ES context (Android only)
 *   yage_audio.c         — OpenSL ES audio + callbacks (Android+)
 *   yage_video.c         — Video processing + ANativeWindow blit
 *   yage_frame_loop.c    — Native frame-loop thread
 *   yage_state.c         — Save state, rewind, SRAM, cheat
 *   yage_env_callback.c  — Libretro environment callback
 */

#ifndef YAGE_INTERNAL_H
#define YAGE_INTERNAL_H

/* ── Standard headers ────────────────────────────────────────────────── */
#include "yage_libretro.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>

#ifndef _WIN32
#  include <stdatomic.h>
#  include <pthread.h>
#  include <time.h>
#  include <errno.h>
#endif

/* ── Platform dynamic library loading ───────────────────────────────── */
#ifdef _WIN32
#  include <windows.h>
#  define LOAD_LIBRARY(path)   LoadLibraryA(path)
#  define GET_PROC(lib, name)  GetProcAddress(lib, name)
#  define FREE_LIBRARY(lib)    FreeLibrary(lib)
typedef HMODULE LibHandle;
#else
#  include <dlfcn.h>
#  define LOAD_LIBRARY(path)   dlopen(path, RTLD_LAZY)
#  define GET_PROC(lib, name)  dlsym(lib, name)
#  define FREE_LIBRARY(lib)    dlclose(lib)
typedef void* LibHandle;
#endif

/* ── Android platform headers ───────────────────────────────────────── */
#ifdef __ANDROID__
#  include <stdatomic.h>
#  include <SLES/OpenSLES.h>
#  include <SLES/OpenSLES_Android.h>
#  include <EGL/egl.h>
#  include <GLES3/gl3.h>   /* GLES3: hw_render context is always GLES3 (melonDS, mupen64plus-next) */
#  include <android/log.h>
#  include <android/native_window.h>
#  include <android/native_window_jni.h>
#  include <jni.h>
#  define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  "YAGE", __VA_ARGS__)
#  define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "YAGE", __VA_ARGS__)
#else
#  define LOGI(...) do { printf("[YAGE] ");       printf(__VA_ARGS__); printf("\n"); } while(0)
#  define LOGE(...) do { printf("[YAGE ERROR] "); printf(__VA_ARGS__); printf("\n"); } while(0)
#endif

#ifndef EGL_OPENGL_ES3_BIT_KHR
#  define EGL_OPENGL_ES3_BIT_KHR 0x0040
#endif

/* Forward declarations used by function-pointer typedefs below. */
struct retro_game_info;
struct retro_system_info;
struct retro_system_av_info;

/* ── Libretro function pointer typedefs ─────────────────────────────── */
typedef void   (*retro_init_t)(void);
typedef void   (*retro_deinit_t)(void);
typedef void   (*retro_reset_t)(void);
typedef void   (*retro_run_t)(void);
typedef bool   (*retro_load_game_t)(const struct retro_game_info*);
typedef void   (*retro_unload_game_t)(void);
typedef size_t (*retro_serialize_size_t)(void);
typedef bool   (*retro_serialize_t)(void*, size_t);
typedef bool   (*retro_unserialize_t)(const void*, size_t);
typedef void   (*retro_get_system_info_t)(struct retro_system_info*);
typedef void   (*retro_get_system_av_info_t)(struct retro_system_av_info*);
typedef void   (*retro_set_environment_t)(void*);
typedef void   (*retro_set_video_refresh_t)(void*);
typedef void   (*retro_set_audio_sample_t)(void*);
typedef void   (*retro_set_audio_sample_batch_t)(void*);
typedef void   (*retro_set_input_poll_t)(void*);
typedef void   (*retro_set_input_state_t)(void*);
typedef void*  (*retro_get_memory_data_t)(unsigned id);
typedef size_t (*retro_get_memory_size_t)(unsigned id);
typedef void   (*retro_cheat_reset_t)(void);
typedef void   (*retro_cheat_set_t)(unsigned index, bool enabled, const char* code);
typedef void   (*retro_proc_address_t)(void);
typedef retro_proc_address_t (*retro_hw_get_proc_address_t)(const char*);

/* ── melonDS M27 deferred GL2D composite hooks (optional core exports) ──
 * Exported by the melonDS fork's GPU2D_OpenGL.cpp. All are optional: the
 * pointers stay NULL for every other core and for melonDS builds without
 * the hooks, and M27 stays disabled. */
typedef void (*melonds_m27_set_enabled_t)(int en);
typedef int  (*melonds_m27_has_pending_t)(void);
typedef void (*melonds_m27_execute_t)(void);
typedef void (*melonds_m27_set_cb_t)(void (*cb)(void));

/* ── Libretro structs ────────────────────────────────────────────────── */
struct retro_game_info {
    const char* path;
    const void* data;
    size_t size;
    const char* meta;
};

struct retro_system_info {
    const char* library_name;
    const char* library_version;
    const char* valid_extensions;
    bool need_fullpath;
    bool block_extract;
};

struct retro_game_geometry {
    unsigned base_width;
    unsigned base_height;
    unsigned max_width;
    unsigned max_height;
    float aspect_ratio;
};

struct retro_system_timing {
    double fps;
    double sample_rate;
};

struct retro_system_av_info {
    struct retro_game_geometry geometry;
    struct retro_system_timing timing;
};

enum retro_hw_context_type {
    RETRO_HW_CONTEXT_NONE       = 0,
    RETRO_HW_CONTEXT_OPENGL     = 1,
    RETRO_HW_CONTEXT_OPENGLES2  = 2,
    RETRO_HW_CONTEXT_OPENGL_CORE = 3,
    RETRO_HW_CONTEXT_OPENGLES3  = 4,
};

/* Must match libretro.h layout exactly — field order is ABI-critical. */
struct retro_hw_render_callback {
    enum retro_hw_context_type context_type;
    void (*context_reset)(void);
    uintptr_t (*get_current_framebuffer)(void);
    retro_hw_get_proc_address_t get_proc_address;
    bool depth;
    bool stencil;
    bool bottom_left_origin;
    unsigned version_major;
    unsigned version_minor;
    bool cache_context;
    void (*context_destroy)(void);
    bool debug_context;
};

/* ── Libretro memory / format constants ─────────────────────────────── */
#define RETRO_HW_FRAME_BUFFER_VALID  ((void*)-1)
#define RETRO_MEMORY_SAVE_RAM        0
#define RETRO_MEMORY_RTC             1
#define RETRO_MEMORY_SYSTEM_RAM      2
#define RETRO_MEMORY_VIDEO_RAM       3

/* ── Screen dimensions for each supported platform ─────────────────── */
#define GBA_WIDTH    240
#define GBA_HEIGHT   160
#define GB_WIDTH     160
#define GB_HEIGHT    144
#define SGB_WIDTH    256
#define SGB_HEIGHT   224
#define NES_WIDTH    256
#define NES_HEIGHT   240
#define SNES_WIDTH   256
#define SNES_HEIGHT  224
#define SMS_WIDTH    256
#define SMS_HEIGHT   192
#define GG_WIDTH     160
#define GG_HEIGHT    144
#define MD_WIDTH     320
#define MD_HEIGHT    224
#define N64_WIDTH    320
#define N64_HEIGHT   240
#define NGP_WIDTH    160
#define NGP_HEIGHT   152
#define WSWAN_WIDTH  224
#define WSWAN_HEIGHT 144
#define A2600_WIDTH  160
#define A2600_HEIGHT 210
#define VB_WIDTH     384
#define VB_HEIGHT    224
#define TIC80_WIDTH  240
#define TIC80_HEIGHT 136
#define PICO8_WIDTH  128
#define PICO8_HEIGHT 128
/* NDS dual-screen portrait combined framebuffer (256×192 per screen). */
#define NDS_WIDTH    256
#define NDS_HEIGHT   384
#define PSX_WIDTH    320
#define PSX_HEIGHT   240

/* ── Buffer sizes ──────────────────────────────────────────────────── */
#define AUDIO_BUFFER_SIZE   8192
/* 512×384 covers NDS dual-screen (256×384), N64/PS1 HW upscale, and all
 * software-rendered cores.  The initial allocation is cheap (~768 KB); cores
 * with larger geometry grow it via realloc at retro_get_system_av_info time. */
#define VIDEO_BUFFER_SIZE   (512 * 384)

/* ── Android audio constants ─────────────────────────────────────────── */
#define AUDIO_BUFFERS_MAX   8          /* static array upper bound            */
#define AUDIO_BUFFERS_DEFAULT 4        /* runtime default (raised to 6 on TV)  */
#define AUDIO_BUFFER_FRAMES 512
#define RING_BUFFER_SIZE    65536
#define RING_BUFFER_MASK    (RING_BUFFER_SIZE - 1)

/* ── Frame loop timing ───────────────────────────────────────────────── */
#define DISPLAY_INTERVAL_NS  16666667LL   /* 1e9 / 60   */
#define DEFAULT_FRAME_NS     16742706LL   /* 1e9 / 59.7275 (GBA) */

/* ── YageCore struct (full definition shared by all modules) ─────────── */
struct YageCore {
    LibHandle lib;

    retro_init_t                  retro_init;
    retro_deinit_t                retro_deinit;
    retro_reset_t                 retro_reset;
    retro_run_t                   retro_run;
    retro_load_game_t             retro_load_game;
    retro_unload_game_t           retro_unload_game;
    retro_serialize_size_t        retro_serialize_size;
    retro_serialize_t             retro_serialize;
    retro_unserialize_t           retro_unserialize;
    retro_get_system_info_t       retro_get_system_info;
    retro_get_system_av_info_t    retro_get_system_av_info;
    retro_set_environment_t       retro_set_environment;
    retro_set_video_refresh_t     retro_set_video_refresh;
    retro_set_audio_sample_t      retro_set_audio_sample;
    retro_set_audio_sample_batch_t retro_set_audio_sample_batch;
    retro_set_input_poll_t        retro_set_input_poll;
    retro_set_input_state_t       retro_set_input_state;
    retro_get_memory_data_t       retro_get_memory_data;
    retro_get_memory_size_t       retro_get_memory_size;
    retro_cheat_reset_t           retro_cheat_reset;
    retro_cheat_set_t             retro_cheat_set;

    /* melonDS M27 deferred GL2D hooks (NULL unless the core exports them). */
    melonds_m27_set_enabled_t     melonds_m27_set_enabled;
    melonds_m27_has_pending_t     melonds_m27_has_pending;
    melonds_m27_execute_t         melonds_m27_execute;
    melonds_m27_set_cb_t          melonds_m27_set_kick_callback;
    melonds_m27_set_cb_t          melonds_m27_set_wait_callback;

    char*        save_dir;
    char*        system_dir;
    char*        rom_path;
    YagePlatform platform;
    int          initialized;
    int          game_loaded;

    /* ROM image + the retro_game_info handed to retro_load_game. Both MUST
     * stay alive for the whole lifetime of the loaded game: cores cache the
     * retro_game_info pointer and re-read info->data later (melonDS does so
     * on retro_reset()). Freed in yage_core_destroy. On POSIX rom_data is a
     * read-only file-backed mmap, on Windows a malloc'd buffer. */
    void*  rom_data;
    size_t rom_data_size;
    struct retro_game_info game_info;

    void*  state_buffer;
    size_t state_size;
};

/* ══════════════════════════════════════════════════════════════════════
 * Cross-module global declarations (defined in their respective .c files)
 * ══════════════════════════════════════════════════════════════════════ */

/* ── yage_libretro.c globals ─────────────────────────────────────────── */
extern YageCore*  g_current_core;
extern char*      g_core_lib_path;
extern uint32_t*  g_video_buffer;
extern size_t     g_video_buffer_capacity;
extern int16_t*   g_audio_buffer;
extern int        g_audio_samples;
extern int        g_variables_dirty;
extern int        g_sgb_borders_enabled;
extern int        g_log_frame_count;

/* ── yage_input.c globals ────────────────────────────────────────────── */
#ifndef _WIN32
extern _Atomic uint32_t g_keys;
extern _Atomic int16_t  g_touch_x;
extern _Atomic int16_t  g_touch_y;
extern _Atomic int16_t  g_touch_down;
extern _Atomic int16_t  g_analog_x;
extern _Atomic int16_t  g_analog_y;
extern _Atomic int16_t  g_analog_right_x;
extern _Atomic int16_t  g_analog_right_y;
#else
extern volatile uint32_t g_keys;
extern volatile int16_t  g_touch_x;
extern volatile int16_t  g_touch_y;
extern volatile int16_t  g_touch_down;
extern volatile int16_t  g_analog_x;
extern volatile int16_t  g_analog_y;
extern volatile int16_t  g_analog_right_x;
extern volatile int16_t  g_analog_right_y;
#endif

/* ── yage_video.c globals ────────────────────────────────────────────── */
extern int      g_width;
extern int      g_height;
extern int      g_pixel_format;
extern int      g_color_correction_enabled;  /* mirrors "tuning active" */

/* Apply the load-time default color tuning for [platform]
 * (GB family = mild boost, everything else = neutral). */
void yage_video_apply_default_tuning(int platform);
extern int      g_palette_enabled;
extern uint32_t g_palette_colors[4];
extern int      g_video_frames_total;
extern int      g_monitor_frames;
extern int      g_monitor_samples;
extern int      g_frames_since_reinit;
#ifdef __ANDROID__
extern ANativeWindow*  g_native_window;
extern pthread_mutex_t g_nw_mutex;
#endif

/* ── yage_audio.c globals ────────────────────────────────────────────── */
extern float g_volume;
extern int   g_audio_enabled;
extern int   g_in_preroll;        /* set during JIT pre-roll; audio dropped */
#ifdef __ANDROID__
extern double       g_reported_rate;
extern int          g_rate_detected;
extern double       g_detected_rate;
extern int          g_rate_detection_samples;
extern int          g_audio_started;
extern atomic_int   g_ring_read;
extern atomic_int   g_ring_write;
extern int          g_underrun_count;
extern int          g_overflow_count;
extern int          g_audio_batch_count;
extern atomic_int   g_audio_stopping;  /* 1 = frame loop stopped; silence output immediately */
extern int          g_audio_buffer_count; /* runtime OpenSL buffer count (default 4, TV=6) */
#endif

/* ── yage_hw_render.c globals (Android only) ─────────────────────────── */
#ifdef __ANDROID__
extern int                          g_hw_render_enabled;
extern int                          g_hw_context_reset_pending;
extern int                          g_in_load_game;
extern struct retro_hw_render_callback g_hw_render_cb;
extern EGLDisplay                   g_egl_display;
extern EGLContext                   g_egl_context;
extern EGLSurface                   g_egl_surface;
extern unsigned                     g_hw_fb_width;
extern unsigned                     g_hw_fb_height;
#endif

/* ── yage_frame_loop.c globals ───────────────────────────────────────── */
#ifndef _WIN32
extern int64_t          g_core_frame_ns;
extern uint32_t*        g_display_buf;
extern size_t           g_display_buf_capacity;
extern int              g_display_width;
extern int              g_display_height;
extern pthread_mutex_t  g_display_mutex;
extern atomic_int       g_floop_running;
/* Counts every core retro_run executed by the native frame loop. This is
 * intentionally separate from g_video_frames_total, because adaptive
 * frameskip can suppress video callbacks while audio still advances. */
extern atomic_int       g_core_frames_total;
/* EWMA of recent retro_run cost in microseconds. Published by
 * yage_frame_loop.c and read (under relaxed atomic) by yage_audio.c for
 * elastic playback-rate adaptation. */
extern atomic_int       g_retro_run_ewma_us;
/* Frameskip flag: when the frame loop sees retro_run_ewma_ns exceed the
 * core's nominal interval for sustained frames, it asks the core to skip
 * video rendering on alternate retro_runs (audio always stays enabled).
 * Read by env_callback's RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE handler
 * (cmd 0x1002F) so cores that honour the env query can drop the video
 * stage on flagged frames. Direct-present melonDS GL is exempt because its
 * video callback is also the EGL swap trigger. */
extern atomic_int       g_floop_skip_video;
#endif

/* ── yage_state.c globals ────────────────────────────────────────────── */
extern void**  g_rewind_snapshots;
extern int     g_rewind_head;
extern int     g_rewind_count;
extern int     g_rewind_capacity;
extern size_t  g_rewind_state_size;

/* ── yage_callbacks.c globals ────────────────────────────────────────── */
extern uint8_t*  g_io_ptr;
extern uint32_t  g_io_start;
extern uint32_t  g_io_len;

/* Memory region table (also in yage_callbacks.c) */
#define MAX_MEM_REGIONS 32
struct yage_mem_region {
    void*    ptr;
    uint32_t offset;
    uint32_t start;
    uint32_t select;
    uint32_t disconnect;
    uint32_t len;
};
extern struct yage_mem_region g_mem_regions[MAX_MEM_REGIONS];
extern int g_mem_region_count;

/* ══════════════════════════════════════════════════════════════════════
 * Cross-module function prototypes
 * ══════════════════════════════════════════════════════════════════════ */

/* yage_input.c */
void    input_poll_callback(void);
int16_t input_state_callback(unsigned port, unsigned device, unsigned index, unsigned id);

/* yage_callbacks.c */
void     handle_set_memory_maps(const void* data);
void     retro_log_printf_bridge(int level, const char* fmt, ...);
void     yage_env_frame_time_reset(void);
void     yage_env_frame_time_tick(void);
uint8_t* resolve_address(uint32_t addr);

/* yage_core_vars.c */
void        core_vars_clear(void);
void        core_vars_set(const char* key, const char* value);
const char* core_vars_get(const char* key);
void        core_vars_parse_set_variables(const void* vars);
void        core_vars_parse_set_core_options_v2(const void* opts);
extern int  g_core_vars_count;

/* yage_hw_render.c (Android only) */
#ifdef __ANDROID__
uintptr_t             hw_get_current_framebuffer(void);
retro_proc_address_t  hw_get_proc_address(const char* sym);
void                  hw_render_shutdown(void);
int                   hw_render_init(unsigned width, unsigned height);
int                   hw_render_readback(unsigned width, unsigned height, uint32_t* out_abgr);
int                   hw_render_present(void);
int                   hw_render_is_direct_present(void);
/* M27 render-worker shared EGL context: created lazily (shared with the
 * core's context) + bound on the CALLING thread. bind returns 0 on success. */
int                   hw_render_worker_bind(void);
void                  hw_render_worker_unbind(void);
void                  hw_render_worker_destroy(void);
#endif

/* yage_audio.c */
#ifdef __ANDROID__
void   shutdown_opensl_audio(void);
int    init_opensl_audio(double sample_rate);
void   reset_opensl_audio_pipeline(void);
int    ring_buffer_available(void);
#endif
size_t audio_sample_batch_callback(const int16_t* data, size_t frames);
void   audio_sample_callback(int16_t left, int16_t right);

/* yage_video.c */
void    video_refresh_callback(const void* data, unsigned width, unsigned height, size_t pitch);
int     yage_texture_blit(YageCore* core);
int32_t yage_texture_is_attached(YageCore* core);
#ifdef __ANDROID__
int     blit_to_native_window(void);
#endif

/* yage_frame_loop.c */
int      yage_frame_loop_start(YageCore* core, yage_frame_callback_t callback);
void     yage_frame_loop_stop(YageCore* core);
void     yage_frame_loop_set_speed(YageCore* core, int32_t speed_percent);
void     yage_frame_loop_set_rewind(YageCore* core, int32_t enabled, int32_t interval);
void     yage_frame_loop_set_rcheevos(YageCore* core, int32_t enabled);
int32_t  yage_frame_loop_get_fps_x100(YageCore* core);
int32_t  yage_frame_loop_get_run_ewma_us(YageCore* core);
int32_t  yage_frame_loop_get_frame_interval_us(YageCore* core);
uint32_t* yage_frame_loop_get_display_buffer(YageCore* core);
int32_t  yage_frame_loop_get_display_width(YageCore* core);
int32_t  yage_frame_loop_get_display_height(YageCore* core);
void     yage_frame_loop_lock_display(YageCore* core);
void     yage_frame_loop_unlock_display(YageCore* core);
int32_t  yage_frame_loop_is_running(YageCore* core);

/* yage_state.c */
int  yage_core_save_state(YageCore* core, int slot);
int  yage_core_load_state(YageCore* core, int slot);
int  yage_core_rewind_init(YageCore* core, int capacity);
void yage_core_rewind_deinit(YageCore* core);
int  yage_core_rewind_push(YageCore* core);
int  yage_core_rewind_pop(YageCore* core);
int  yage_core_rewind_count(YageCore* core);
int  yage_core_get_sram_size(YageCore* core);
uint8_t* yage_core_get_sram_data(YageCore* core);
int  yage_core_save_sram(YageCore* core, const char* path);
int  yage_core_load_sram(YageCore* core, const char* path);
int  yage_core_cheat_reset(YageCore* core);
int  yage_core_cheat_set(YageCore* core, unsigned index, int enabled, const char* code);

/* yage_env_callback.c */
bool environment_callback(unsigned cmd, void* data);

/* yage_gpu_texture.c — GPU zero-copy texture rendering (Android) */
#ifdef __ANDROID__
int      gpu_hwbuffer_init(unsigned width, unsigned height);
void     gpu_hwbuffer_shutdown(void);
uint32_t gpu_hwbuffer_get_texture_id(void);
int      gpu_hwbuffer_is_ready(void);
unsigned gpu_hwbuffer_get_width(void);
unsigned gpu_hwbuffer_get_height(void);
void     gpu_hwbuffer_mark_dirty(void);
int      gpu_hwbuffer_is_dirty(void);
int      gpu_hwbuffer_resize_if_needed(unsigned width, unsigned height);
int      gpu_hwbuffer_attach_to_fb(uint32_t framebuffer);
#endif

/* yage_options_ui.c — Core options JSON UI schema */
void     options_ui_clear(void);
void     options_ui_set_from_retro_variable(const char* key, const char* value);
void     options_ui_set_from_v2_option(const char* key, const char* description, const char* category, const char* default_val);
const char* options_ui_get_value(const char* key);
int      options_ui_set_value(const char* key, const char* value);
char*    options_ui_build_json(void);
const char* options_ui_get_json(void);
void     options_ui_free_json(const char* json);

/* yage_rcheevos.c */
extern void yage_rc_do_frame(void);

#endif /* YAGE_INTERNAL_H */
