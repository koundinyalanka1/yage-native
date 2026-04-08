#include "yage_internal.h"

int g_width  = GBA_WIDTH;
int g_height = GBA_HEIGHT;

int      g_pixel_format              = RETRO_PIXEL_FORMAT_RGB565;
int      g_color_correction_enabled  = 1;   
int      g_palette_enabled           = 0;   
uint32_t g_palette_colors[4] = {
    0xFF0FBC9B, 
    0xFF0FAC8B, 
    0xFF306230, 
    0xFF0F380F  
};

int g_video_frames_total  = 0;

#ifdef __ANDROID__
ANativeWindow*  g_native_window    = NULL;
static int      g_nw_configured_w  = 0;
static int      g_nw_configured_h  = 0;
static int      g_blit_diag_count  = 0;
pthread_mutex_t g_nw_mutex         = PTHREAD_MUTEX_INITIALIZER;
#endif

static inline uint32_t apply_color_correction(uint8_t r, uint8_t g, uint8_t b) {
    int ri = r, gi = g, bi = b;
    ri = (ri - 128) * 110 / 100 + 128;
    gi = (gi - 128) * 110 / 100 + 128;
    bi = (bi - 128) * 110 / 100 + 128;
    if (ri < 0) ri = 0; if (ri > 255) ri = 255;
    if (gi < 0) gi = 0; if (gi > 255) gi = 255;
    if (bi < 0) bi = 0; if (bi > 255) bi = 255;
    return 0xFF000000 | ((uint32_t)bi << 16) | ((uint32_t)gi << 8) | (uint32_t)ri;
}

static inline uint32_t apply_gb_palette(uint8_t r, uint8_t g, uint8_t b) {
    int lum = (r * 2 + g * 5 + b) >> 3;
    if (lum >= 192) return g_palette_colors[0];
    else if (lum >= 128) return g_palette_colors[1];
    else if (lum >= 64)  return g_palette_colors[2];
    else                 return g_palette_colors[3];
}

static inline uint32_t process_pixel(uint8_t r, uint8_t g, uint8_t b) {
    if (g_palette_enabled)           return apply_gb_palette(r, g, b);
    if (g_color_correction_enabled)  return apply_color_correction(r, g, b);
    return 0xFF000000 | ((uint32_t)b << 16) | ((uint32_t)g << 8) | (uint32_t)r;
}

void video_refresh_callback(const void* data, unsigned width,
                             unsigned height, size_t pitch) {
    if (!g_video_buffer) return;

    if (data == RETRO_HW_FRAME_BUFFER_VALID) {
        g_width  = (int)width;
        g_height = (int)height;
        g_video_frames_total++;

        size_t needed = (size_t)width * height;
        if (needed > g_video_buffer_capacity) {
            uint32_t* new_buf = (uint32_t*)realloc(g_video_buffer,
                                                    needed * sizeof(uint32_t));
            if (!new_buf) {
                LOGE("HW frame: failed to reallocate video buffer for %ux%u", width, height);
                return;
            }
            g_video_buffer = new_buf;
            g_video_buffer_capacity = needed;
        }

#ifdef __ANDROID__
        if (hw_render_readback(width, height, g_video_buffer) != 0 &&
            g_log_frame_count < 20) {
            LOGE("HW frame readback failed (%ux%u)", width, height);
            g_log_frame_count++;
        }
#endif
        return;
    }

    if (!data) return;

    g_width  = (int)width;
    g_height = (int)height;
    g_video_frames_total++;

    if (g_log_frame_count < 5) {
        const uint8_t* raw = (const uint8_t*)data;
        uint32_t p0 = 0, pM = 0;
        if (g_pixel_format == RETRO_PIXEL_FORMAT_XRGB8888 && pitch >= 4) {
            p0 = *(const uint32_t*)(raw);
            pM = *(const uint32_t*)(raw + (height / 2) * pitch + (width / 2) * 4);
        }
        LOGI("Video: %ux%u, pitch=%zu, format=%d, px[0,0]=0x%08X, px[mid]=0x%08X",
             width, height, pitch, g_pixel_format, p0, pM);
        g_log_frame_count++;
    }

    size_t needed = (size_t)width * height;
    if (needed > g_video_buffer_capacity) {
        uint32_t* new_buf = (uint32_t*)realloc(g_video_buffer,
                                                needed * sizeof(uint32_t));
        if (!new_buf) {
            LOGE("Failed to reallocate video buffer for %ux%u", width, height);
            return;
        }
        g_video_buffer = new_buf;
        g_video_buffer_capacity = needed;
        LOGI("Video buffer reallocated for %ux%u (%zu pixels)", width, height, needed);
    }

    if (g_pixel_format == RETRO_PIXEL_FORMAT_XRGB8888) {
        const uint8_t* src = (const uint8_t*)data;
        for (unsigned y = 0; y < height; y++) {
            const uint32_t* row = (const uint32_t*)(src + y * pitch);
            for (unsigned x = 0; x < width; x++) {
                uint32_t pixel = row[x];
                g_video_buffer[y * width + x] = process_pixel(
                    (pixel >> 16) & 0xFF, (pixel >> 8) & 0xFF, pixel & 0xFF);
            }
        }
    } else if (g_pixel_format == RETRO_PIXEL_FORMAT_RGB565) {
        const uint8_t* src = (const uint8_t*)data;
        for (unsigned y = 0; y < height; y++) {
            const uint16_t* row = (const uint16_t*)(src + y * pitch);
            for (unsigned x = 0; x < width; x++) {
                uint16_t p = row[x];
                uint8_t r = (p >> 11) & 0x1F; r = (r << 3) | (r >> 2);
                uint8_t g = (p >>  5) & 0x3F; g = (g << 2) | (g >> 4);
                uint8_t b =  p        & 0x1F; b = (b << 3) | (b >> 2);
                g_video_buffer[y * width + x] = process_pixel(r, g, b);
            }
        }
    } else if (g_pixel_format == RETRO_PIXEL_FORMAT_0RGB1555) {
        const uint8_t* src = (const uint8_t*)data;
        for (unsigned y = 0; y < height; y++) {
            const uint16_t* row = (const uint16_t*)(src + y * pitch);
            for (unsigned x = 0; x < width; x++) {
                uint16_t p = row[x];
                uint8_t r = (p >> 10) & 0x1F; r = (r << 3) | (r >> 2);
                uint8_t g = (p >>  5) & 0x1F; g = (g << 3) | (g >> 2);
                uint8_t b =  p        & 0x1F; b = (b << 3) | (b >> 2);
                g_video_buffer[y * width + x] = process_pixel(r, g, b);
            }
        }
    } else {
        LOGI("Unknown pixel format %d, trying auto-detect", g_pixel_format);
        if (pitch >= width * 4) {
            const uint8_t* src = (const uint8_t*)data;
            for (unsigned y = 0; y < height; y++) {
                const uint32_t* row = (const uint32_t*)(src + y * pitch);
                for (unsigned x = 0; x < width; x++) {
                    uint32_t pixel = row[x];
                    g_video_buffer[y * width + x] = process_pixel(
                        (pixel >> 16) & 0xFF, (pixel >> 8) & 0xFF, pixel & 0xFF);
                }
            }
        } else {
            const uint8_t* src = (const uint8_t*)data;
            for (unsigned y = 0; y < height; y++) {
                const uint16_t* row = (const uint16_t*)(src + y * pitch);
                for (unsigned x = 0; x < width; x++) {
                    uint16_t p = row[x];
                    uint8_t r = (p >> 11) & 0x1F; r = (r << 3) | (r >> 2);
                    uint8_t g = (p >>  5) & 0x3F; g = (g << 2) | (g >> 4);
                    uint8_t b =  p        & 0x1F; b = (b << 3) | (b >> 2);
                    g_video_buffer[y * width + x] = process_pixel(r, g, b);
                }
            }
        }
    }
}

#ifdef __ANDROID__

int blit_to_native_window(void) {
    if (g_hw_render_enabled && hw_render_is_direct_present()) {
        return 0;
    }

    pthread_mutex_lock(&g_nw_mutex);
    ANativeWindow* win = g_native_window;
    if (!win || !g_video_buffer) {
        pthread_mutex_unlock(&g_nw_mutex);
        return -1;
    }

    int w = g_width;
    int h = g_height;
    if (w <= 0 || h <= 0) {
        pthread_mutex_unlock(&g_nw_mutex);
        return -1;
    }

    if (w != g_nw_configured_w || h != g_nw_configured_h) {
        ANativeWindow_setBuffersGeometry(win, w, h, WINDOW_FORMAT_RGBA_8888);
        g_nw_configured_w = w;
        g_nw_configured_h = h;
        LOGI("ANativeWindow geometry set to %dx%d", w, h);
    }

    ANativeWindow_Buffer buf;
    if (ANativeWindow_lock(win, &buf, NULL) != 0) {
        pthread_mutex_unlock(&g_nw_mutex);
        return -1;
    }

    uint32_t* dst = (uint32_t*)buf.bits;
    uint32_t* src = g_video_buffer;

    if (buf.stride == w) {
        memcpy(dst, src, (size_t)w * h * sizeof(uint32_t));
    } else {
        for (int y = 0; y < h; y++) {
            memcpy(dst + y * buf.stride, src + y * w, (size_t)w * sizeof(uint32_t));
        }
    }

    if (g_blit_diag_count < 3) {
        LOGI("Blit #%d: %dx%d stride=%d, src[0]=0x%08X src[mid]=0x%08X dst[0]=0x%08X",
             g_blit_diag_count, w, h, buf.stride,
             src[0], src[(h / 2) * w + w / 2], dst[0]);
        g_blit_diag_count++;
    }

    ANativeWindow_unlockAndPost(win);
    pthread_mutex_unlock(&g_nw_mutex);
    return 0;
}

JNIEXPORT void JNICALL
Java_com_yourmateapps_retropal_YageTextureBridge_nativeSetSurface(
        JNIEnv* env, jclass clazz, jobject surface) {
    (void)clazz;

    pthread_mutex_lock(&g_nw_mutex);
    if (g_native_window) {
        ANativeWindow_release(g_native_window);
        g_native_window   = NULL;
        g_nw_configured_w = 0;
        g_nw_configured_h = 0;
    }

    if (surface) {
        g_native_window = ANativeWindow_fromSurface(env, surface);
        g_blit_diag_count = 0;
        if (g_native_window) {
            ANativeWindow_setBuffersGeometry(
                g_native_window, g_width, g_height, WINDOW_FORMAT_RGBA_8888);
            g_nw_configured_w = g_width;
            g_nw_configured_h = g_height;
            LOGI("ANativeWindow attached (%dx%d)", g_width, g_height);
        } else {
            LOGE("ANativeWindow_fromSurface returned NULL");
        }
    }
    pthread_mutex_unlock(&g_nw_mutex);
}

JNIEXPORT void JNICALL
Java_com_yourmateapps_retropal_YageTextureBridge_nativeReleaseSurface(
        JNIEnv* env, jclass clazz) {
    (void)env; (void)clazz;

    pthread_mutex_lock(&g_nw_mutex);
    if (g_native_window) {
        ANativeWindow* old = g_native_window;
        g_native_window   = NULL;
        g_nw_configured_w = 0;
        g_nw_configured_h = 0;
        pthread_mutex_unlock(&g_nw_mutex);
        ANativeWindow_release(old);
        LOGI("ANativeWindow released");
    } else {
        pthread_mutex_unlock(&g_nw_mutex);
    }
}

#endif 

YAGE_API int yage_texture_blit(YageCore* core) {
    (void)core;
#ifdef __ANDROID__
    return blit_to_native_window();
#else
    return -1;
#endif
}

YAGE_API int32_t yage_texture_is_attached(YageCore* core) {
    (void)core;
#ifdef __ANDROID__
    return g_native_window != NULL ? 1 : 0;
#else
    return 0;
#endif
}
