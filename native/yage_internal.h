#ifndef YAGE_INTERNAL_H
#define YAGE_INTERNAL_H

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

#ifdef __ANDROID__
#  include <stdatomic.h>
#  include <SLES/OpenSLES.h>
#  include <SLES/OpenSLES_Android.h>
#  include <EGL/egl.h>
#  include <GLES2/gl2.h>
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

struct retro_game_info;
struct retro_system_info;
struct retro_system_av_info;

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

#define RETRO_HW_FRAME_BUFFER_VALID  ((void*)-1)
#define RETRO_MEMORY_SAVE_RAM        0
#define RETRO_MEMORY_RTC             1
#define RETRO_MEMORY_SYSTEM_RAM      2
#define RETRO_MEMORY_VIDEO_RAM       3

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

#define AUDIO_BUFFER_SIZE   8192
#define VIDEO_BUFFER_SIZE   (320 * 240)   

#define AUDIO_BUFFERS       4
#define AUDIO_BUFFER_FRAMES 512
#define RING_BUFFER_SIZE    65536
#define RING_BUFFER_MASK    (RING_BUFFER_SIZE - 1)

#define DISPLAY_INTERVAL_NS  16666667LL   
#define DEFAULT_FRAME_NS     16742706LL   

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

    char*        save_dir;
    char*        system_dir;
    char*        rom_path;
    YagePlatform platform;
    int          initialized;
    int          game_loaded;

    void*  state_buffer;
    size_t state_size;
};

extern YageCore*  g_current_core;
extern char*      g_core_lib_path;
extern uint32_t*  g_video_buffer;
extern size_t     g_video_buffer_capacity;
extern int16_t*   g_audio_buffer;
extern int        g_audio_samples;
extern int        g_variables_dirty;
extern int        g_sgb_borders_enabled;
extern int        g_log_frame_count;

#ifndef _WIN32
extern _Atomic uint32_t g_keys;
extern _Atomic int16_t  g_touch_x;
extern _Atomic int16_t  g_touch_y;
extern _Atomic int16_t  g_touch_down;
extern _Atomic int16_t  g_analog_x;
extern _Atomic int16_t  g_analog_y;
#else
extern volatile uint32_t g_keys;
extern volatile int16_t  g_touch_x;
extern volatile int16_t  g_touch_y;
extern volatile int16_t  g_touch_down;
extern volatile int16_t  g_analog_x;
extern volatile int16_t  g_analog_y;
#endif

extern int      g_width;
extern int      g_height;
extern int      g_pixel_format;
extern int      g_color_correction_enabled;
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

extern float g_volume;
extern int   g_audio_enabled;
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
#endif

#ifdef __ANDROID__
extern int                          g_hw_render_enabled;
extern int                          g_hw_context_reset_pending;
extern struct retro_hw_render_callback g_hw_render_cb;
extern EGLDisplay                   g_egl_display;
extern EGLContext                   g_egl_context;
extern EGLSurface                   g_egl_surface;
extern unsigned                     g_hw_fb_width;
extern unsigned                     g_hw_fb_height;
#endif

#ifndef _WIN32
extern int64_t          g_core_frame_ns;
extern uint32_t*        g_display_buf;
extern size_t           g_display_buf_capacity;
extern int              g_display_width;
extern int              g_display_height;
extern pthread_mutex_t  g_display_mutex;
extern atomic_int       g_floop_running;
#endif

extern void**  g_rewind_snapshots;
extern int     g_rewind_head;
extern int     g_rewind_count;
extern int     g_rewind_capacity;
extern size_t  g_rewind_state_size;

extern uint8_t*  g_io_ptr;
extern uint32_t  g_io_start;
extern uint32_t  g_io_len;

#define MAX_MEM_REGIONS 32
struct yage_mem_region {
    void*    ptr;
    uint32_t start;
    uint32_t len;
};
extern struct yage_mem_region g_mem_regions[MAX_MEM_REGIONS];
extern int g_mem_region_count;

void    input_poll_callback(void);
int16_t input_state_callback(unsigned port, unsigned device, unsigned index, unsigned id);

void     handle_set_memory_maps(const void* data);
void     retro_log_printf_bridge(int level, const char* fmt, ...);
uint8_t* resolve_address(uint32_t addr);

void        core_vars_clear(void);
void        core_vars_set(const char* key, const char* value);
const char* core_vars_get(const char* key);
void        core_vars_parse_set_variables(const void* vars);
void        core_vars_parse_set_core_options_v2(const void* opts);
extern int  g_core_vars_count;

#ifdef __ANDROID__
uintptr_t             hw_get_current_framebuffer(void);
retro_proc_address_t  hw_get_proc_address(const char* sym);
void                  hw_render_shutdown(void);
int                   hw_render_init(unsigned width, unsigned height);
int                   hw_render_readback(unsigned width, unsigned height, uint32_t* out_abgr);
int                   hw_render_present(void);
int                   hw_render_is_direct_present(void);
#endif

#ifdef __ANDROID__
void   shutdown_opensl_audio(void);
int    init_opensl_audio(double sample_rate);
int    ring_buffer_available(void);
#endif
size_t audio_sample_batch_callback(const int16_t* data, size_t frames);
void   audio_sample_callback(int16_t left, int16_t right);

void    video_refresh_callback(const void* data, unsigned width, unsigned height, size_t pitch);
int     yage_texture_blit(YageCore* core);
int32_t yage_texture_is_attached(YageCore* core);
#ifdef __ANDROID__
int     blit_to_native_window(void);
#endif

int      yage_frame_loop_start(YageCore* core, yage_frame_callback_t callback);
void     yage_frame_loop_stop(YageCore* core);
void     yage_frame_loop_set_speed(YageCore* core, int32_t speed_percent);
void     yage_frame_loop_set_rewind(YageCore* core, int32_t enabled, int32_t interval);
void     yage_frame_loop_set_rcheevos(YageCore* core, int32_t enabled);
int32_t  yage_frame_loop_get_fps_x100(YageCore* core);
uint32_t* yage_frame_loop_get_display_buffer(YageCore* core);
int32_t  yage_frame_loop_get_display_width(YageCore* core);
int32_t  yage_frame_loop_get_display_height(YageCore* core);
void     yage_frame_loop_lock_display(YageCore* core);
void     yage_frame_loop_unlock_display(YageCore* core);
int32_t  yage_frame_loop_is_running(YageCore* core);

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

bool environment_callback(unsigned cmd, void* data);

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

void     options_ui_clear(void);
void     options_ui_set_from_retro_variable(const char* key, const char* value);
void     options_ui_set_from_v2_option(const char* key, const char* description, const char* category, const char* default_val);
const char* options_ui_get_value(const char* key);
int      options_ui_set_value(const char* key, const char* value);
char*    options_ui_build_json(void);
const char* options_ui_get_json(void);
void     options_ui_free_json(const char* json);

extern void yage_rc_do_frame(void);

#endif 
