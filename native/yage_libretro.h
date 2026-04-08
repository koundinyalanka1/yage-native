

#ifndef YAGE_LIBRETRO_H
#define YAGE_LIBRETRO_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef _WIN32
    #ifdef YAGE_EXPORTS
        #define YAGE_API __declspec(dllexport)
    #else
        #define YAGE_API __declspec(dllimport)
    #endif
#else
    #define YAGE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif


#define RETRO_PIXEL_FORMAT_0RGB1555 0
#define RETRO_PIXEL_FORMAT_XRGB8888 1
#define RETRO_PIXEL_FORMAT_RGB565   2


#define RETRO_DEVICE_JOYPAD 1
#define RETRO_DEVICE_POINTER 6
#define RETRO_DEVICE_ANALOG 2


#define RETRO_DEVICE_ID_POINTER_X 0
#define RETRO_DEVICE_ID_POINTER_Y 1
#define RETRO_DEVICE_ID_POINTER_PRESSED 2


#define RETRO_DEVICE_ID_ANALOG_X 0
#define RETRO_DEVICE_ID_ANALOG_Y 1


#define RETRO_DEVICE_ID_JOYPAD_B      0
#define RETRO_DEVICE_ID_JOYPAD_Y      1
#define RETRO_DEVICE_ID_JOYPAD_SELECT 2
#define RETRO_DEVICE_ID_JOYPAD_START  3
#define RETRO_DEVICE_ID_JOYPAD_UP     4
#define RETRO_DEVICE_ID_JOYPAD_DOWN   5
#define RETRO_DEVICE_ID_JOYPAD_LEFT   6
#define RETRO_DEVICE_ID_JOYPAD_RIGHT  7
#define RETRO_DEVICE_ID_JOYPAD_A      8
#define RETRO_DEVICE_ID_JOYPAD_X      9
#define RETRO_DEVICE_ID_JOYPAD_L      10
#define RETRO_DEVICE_ID_JOYPAD_R      11
#define RETRO_DEVICE_ID_JOYPAD_MASK   256


typedef enum {
    YAGE_PLATFORM_UNKNOWN = 0,
    YAGE_PLATFORM_GB = 1,
    YAGE_PLATFORM_GBC = 2,
    YAGE_PLATFORM_GBA = 3,
    YAGE_PLATFORM_NES = 4,
    YAGE_PLATFORM_SNES = 5,
    YAGE_PLATFORM_SMS = 6,
    YAGE_PLATFORM_GG = 7,
    YAGE_PLATFORM_MD = 8,
    YAGE_PLATFORM_SG1000 = 9,
    YAGE_PLATFORM_NGP = 10,
    YAGE_PLATFORM_WS = 11,
    YAGE_PLATFORM_WSC = 12,
    YAGE_PLATFORM_N64 = 13
} YagePlatform;


typedef struct YageCore YageCore;


YAGE_API YageCore* yage_core_create(void);
YAGE_API int yage_core_init(YageCore* core);
YAGE_API void yage_core_destroy(YageCore* core);


YAGE_API int yage_core_set_core(const char* path);


YAGE_API int yage_core_load_rom(YageCore* core, const char* path);
YAGE_API int yage_core_load_bios(YageCore* core, const char* path);
YAGE_API void yage_core_set_save_dir(YageCore* core, const char* path);
YAGE_API void yage_core_set_system_dir(YageCore* core, const char* path);


YAGE_API void yage_core_reset(YageCore* core);
YAGE_API void yage_core_run_frame(YageCore* core);
YAGE_API void yage_core_set_keys(YageCore* core, uint32_t keys);
YAGE_API void yage_core_set_touch(YageCore* core, int16_t x, int16_t y, int pressed);


YAGE_API uint32_t* yage_core_get_video_buffer(YageCore* core);
YAGE_API int yage_core_get_width(YageCore* core);
YAGE_API int yage_core_get_height(YageCore* core);


YAGE_API int16_t* yage_core_get_audio_buffer(YageCore* core);
YAGE_API int yage_core_get_audio_samples(YageCore* core);
YAGE_API void yage_core_set_volume(YageCore* core, float volume);
YAGE_API void yage_core_set_audio_enabled(YageCore* core, int enabled);


YAGE_API void yage_core_set_color_palette(YageCore* core, int palette_index,
                                           uint32_t color0, uint32_t color1,
                                           uint32_t color2, uint32_t color3);


YAGE_API void yage_core_set_sgb_borders(YageCore* core, int enabled);


YAGE_API int yage_core_save_state(YageCore* core, int slot);
YAGE_API int yage_core_load_state(YageCore* core, int slot);


YAGE_API int yage_core_rewind_init(YageCore* core, int capacity);
YAGE_API void yage_core_rewind_deinit(YageCore* core);
YAGE_API int yage_core_rewind_push(YageCore* core);
YAGE_API int yage_core_rewind_pop(YageCore* core);
YAGE_API int yage_core_rewind_count(YageCore* core);


YAGE_API int yage_core_get_sram_size(YageCore* core);
YAGE_API uint8_t* yage_core_get_sram_data(YageCore* core);
YAGE_API int yage_core_save_sram(YageCore* core, const char* path);
YAGE_API int yage_core_load_sram(YageCore* core, const char* path);


YAGE_API int yage_core_get_platform(YageCore* core);




YAGE_API int yage_core_link_is_supported(YageCore* core);


YAGE_API int yage_core_link_read_byte(YageCore* core, uint32_t addr);


YAGE_API int yage_core_link_write_byte(YageCore* core, uint32_t addr, uint8_t value);


YAGE_API int yage_core_link_get_transfer_status(YageCore* core);


YAGE_API int yage_core_link_exchange_data(YageCore* core, uint8_t incoming);


YAGE_API int yage_core_read_memory(YageCore* core, uint32_t address,
                                    int32_t count, uint8_t* buffer);


YAGE_API int yage_core_get_memory_size(YageCore* core, int32_t region_id);




typedef void (*yage_frame_callback_t)(int32_t frames_run);


YAGE_API int yage_frame_loop_start(YageCore* core, yage_frame_callback_t callback);


YAGE_API void yage_frame_loop_stop(YageCore* core);


YAGE_API void yage_frame_loop_set_speed(YageCore* core, int32_t speed_percent);


YAGE_API void yage_frame_loop_set_rewind(YageCore* core, int32_t enabled, int32_t interval);


YAGE_API void yage_frame_loop_set_rcheevos(YageCore* core, int32_t enabled);


YAGE_API int32_t yage_frame_loop_get_fps_x100(YageCore* core);


YAGE_API uint32_t* yage_frame_loop_get_display_buffer(YageCore* core);


YAGE_API int32_t yage_frame_loop_get_display_width(YageCore* core);
YAGE_API int32_t yage_frame_loop_get_display_height(YageCore* core);


YAGE_API void yage_frame_loop_lock_display(YageCore* core);
YAGE_API void yage_frame_loop_unlock_display(YageCore* core);


YAGE_API int32_t yage_frame_loop_is_running(YageCore* core);




YAGE_API int yage_texture_blit(YageCore* core);


YAGE_API int32_t yage_texture_is_attached(YageCore* core);


YAGE_API int32_t yage_gpu_texture_is_ready(YageCore* core);


YAGE_API int yage_gpu_texture_init(YageCore* core, uint32_t width, uint32_t height);


YAGE_API void yage_gpu_texture_shutdown(YageCore* core);


YAGE_API uint32_t yage_gpu_texture_get_id(YageCore* core);


YAGE_API int32_t yage_gpu_texture_is_dirty(YageCore* core);




YAGE_API const char* yage_core_get_options_json(YageCore* core);


YAGE_API int yage_core_set_option(YageCore* core, const char* key, const char* value);


YAGE_API const char* yage_core_get_option(YageCore* core, const char* key);


YAGE_API int yage_core_cheat_reset(YageCore* core);
YAGE_API int yage_core_cheat_set(YageCore* core, unsigned index,
                                  int enabled, const char* code);

#ifdef __cplusplus
}
#endif

#endif 

