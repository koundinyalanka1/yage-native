#include "yage_internal.h"

#ifdef __ANDROID__

int                            g_hw_render_enabled         = 0;
int                            g_hw_context_reset_pending  = 0;
struct retro_hw_render_callback g_hw_render_cb;
EGLDisplay                     g_egl_display               = EGL_NO_DISPLAY;
EGLContext                     g_egl_context               = EGL_NO_CONTEXT;
EGLSurface                     g_egl_surface               = EGL_NO_SURFACE;
unsigned                       g_hw_fb_width               = 0;
unsigned                       g_hw_fb_height              = 0;
static int                     g_hw_using_window_surface   = 0;
static ANativeWindow*          g_hw_window_ref             = NULL;
uint8_t*                       g_hw_readback_rgba          = NULL;
size_t                         g_hw_readback_rgba_capacity = 0;

uintptr_t hw_get_current_framebuffer(void) {
    return 0; 
}

retro_proc_address_t hw_get_proc_address(const char* sym) {
    if (!sym) return NULL;
    retro_proc_address_t p = (retro_proc_address_t)eglGetProcAddress(sym);
    if (p) return p;
    return (retro_proc_address_t)dlsym(RTLD_DEFAULT, sym);
}

void hw_render_shutdown(void) {
    if (g_egl_display != EGL_NO_DISPLAY && g_egl_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface, g_egl_context);
        if (g_hw_render_cb.context_destroy) {
            g_hw_render_cb.context_destroy();
        }
    }

    if (g_egl_display != EGL_NO_DISPLAY) {
        eglMakeCurrent(g_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (g_egl_context != EGL_NO_CONTEXT) {
            eglDestroyContext(g_egl_display, g_egl_context);
        }
        if (g_egl_surface != EGL_NO_SURFACE) {
            eglDestroySurface(g_egl_display, g_egl_surface);
        }
        eglTerminate(g_egl_display);
    }

    g_egl_display = EGL_NO_DISPLAY;
    g_egl_context = EGL_NO_CONTEXT;
    g_egl_surface = EGL_NO_SURFACE;
    g_hw_render_enabled = 0;
    g_hw_fb_width = 0;
    g_hw_fb_height = 0;
    g_hw_using_window_surface = 0;

    if (g_hw_window_ref) {
        ANativeWindow_release(g_hw_window_ref);
        g_hw_window_ref = NULL;
    }

    if (g_hw_readback_rgba) {
        free(g_hw_readback_rgba);
        g_hw_readback_rgba = NULL;
        g_hw_readback_rgba_capacity = 0;
    }
}

int hw_render_init(unsigned width, unsigned height) {
    if (width == 0) width = N64_WIDTH;
    if (height == 0) height = N64_HEIGHT;

    hw_render_shutdown();

    g_egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_egl_display == EGL_NO_DISPLAY) {
        LOGE("HW render: eglGetDisplay failed");
        return -1;
    }

    EGLint major = 0, minor = 0;
    if (!eglInitialize(g_egl_display, &major, &minor)) {
        LOGE("HW render: eglInitialize failed");
        hw_render_shutdown();
        return -1;
    }

    EGLint renderable = EGL_OPENGL_ES2_BIT;
    if (g_hw_render_cb.context_type == RETRO_HW_CONTEXT_OPENGLES3) {
        renderable |= EGL_OPENGL_ES3_BIT_KHR;
    }

    EGLint cfg_attrs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT | EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, renderable,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, g_hw_render_cb.depth ? 24 : 0,
        EGL_STENCIL_SIZE, g_hw_render_cb.stencil ? 8 : 0,
        EGL_NONE
    };

    EGLConfig cfg = NULL;
    EGLint num_cfg = 0;
    if (!eglChooseConfig(g_egl_display, cfg_attrs, &cfg, 1, &num_cfg) || num_cfg < 1) {
        LOGE("HW render: eglChooseConfig failed");
        hw_render_shutdown();
        return -1;
    }

    g_hw_using_window_surface = 0;
    g_hw_window_ref = NULL;

    pthread_mutex_lock(&g_nw_mutex);
    ANativeWindow* win = g_native_window;
    if (win) {
        ANativeWindow_acquire(win);
    }
    pthread_mutex_unlock(&g_nw_mutex);

    if (win) {
        ANativeWindow_setBuffersGeometry(win, (int)width, (int)height, WINDOW_FORMAT_RGBA_8888);
        g_egl_surface = eglCreateWindowSurface(g_egl_display, cfg, (EGLNativeWindowType)win, NULL);
        if (g_egl_surface != EGL_NO_SURFACE) {
            g_hw_using_window_surface = 1;
            g_hw_window_ref = win;
            LOGI("HW render: using EGL window surface (%ux%u)", width, height);
        } else {
            LOGE("HW render: eglCreateWindowSurface failed, falling back to pbuffer");
            ANativeWindow_release(win);
        }
    }

    if (g_egl_surface == EGL_NO_SURFACE) {
        EGLint surf_attrs[] = {
            EGL_WIDTH, (EGLint)width,
            EGL_HEIGHT, (EGLint)height,
            EGL_NONE
        };
        g_egl_surface = eglCreatePbufferSurface(g_egl_display, cfg, surf_attrs);
        if (g_egl_surface == EGL_NO_SURFACE) {
            LOGE("HW render: eglCreatePbufferSurface failed (%ux%u)", width, height);
            hw_render_shutdown();
            return -1;
        }
    }

    if (!eglBindAPI(EGL_OPENGL_ES_API)) {
        LOGE("HW render: eglBindAPI failed");
        hw_render_shutdown();
        return -1;
    }

    int requested_major = (g_hw_render_cb.version_major >= 3 ||
                           g_hw_render_cb.context_type == RETRO_HW_CONTEXT_OPENGLES3)
        ? 3
        : 2;

    EGLint ctx_attrs[] = {
        EGL_CONTEXT_CLIENT_VERSION, requested_major,
        EGL_NONE
    };
    g_egl_context = eglCreateContext(g_egl_display, cfg, EGL_NO_CONTEXT, ctx_attrs);
    if (g_egl_context == EGL_NO_CONTEXT && requested_major == 3) {
        EGLint fallback_ctx_attrs[] = {
            EGL_CONTEXT_CLIENT_VERSION, 2,
            EGL_NONE
        };
        g_egl_context = eglCreateContext(g_egl_display, cfg, EGL_NO_CONTEXT, fallback_ctx_attrs);
    }
    if (g_egl_context == EGL_NO_CONTEXT) {
        LOGE("HW render: eglCreateContext failed");
        hw_render_shutdown();
        return -1;
    }

    if (!eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface, g_egl_context)) {
        LOGE("HW render: eglMakeCurrent failed");
        hw_render_shutdown();
        return -1;
    }

    
    g_hw_context_reset_pending = 1;

    g_hw_render_enabled = 1;
    g_hw_fb_width = width;
    g_hw_fb_height = height;
    LOGI("HW render: EGL context ready (%ux%u, requested GLES %d, direct=%d)",
         width, height, requested_major, g_hw_using_window_surface);
    return 0;
}

int hw_render_is_direct_present(void) {
    return (g_hw_render_enabled && g_hw_using_window_surface) ? 1 : 0;
}

int hw_render_present(void) {
    if (!g_hw_render_enabled || !g_hw_using_window_surface) return -1;
    if (g_egl_display == EGL_NO_DISPLAY || g_egl_surface == EGL_NO_SURFACE) return -1;

    if (!eglSwapBuffers(g_egl_display, g_egl_surface)) {
        LOGE("HW render: eglSwapBuffers failed (err=0x%x)", (unsigned)eglGetError());
        return -1;
    }
    return 0;
}

int hw_render_readback(unsigned width, unsigned height, uint32_t* out_abgr) {
    if (!g_hw_render_enabled || !out_abgr || width == 0 || height == 0) return -1;
    if (g_egl_display == EGL_NO_DISPLAY || g_egl_context == EGL_NO_CONTEXT ||
        g_egl_surface == EGL_NO_SURFACE) {
        return -1;
    }

    int has_native_surface = 0;
    pthread_mutex_lock(&g_nw_mutex);
    has_native_surface = (g_native_window != NULL) ? 1 : 0;
    pthread_mutex_unlock(&g_nw_mutex);

    if (width != g_hw_fb_width || height != g_hw_fb_height ||
        (!g_hw_using_window_surface && has_native_surface)) {
        if (hw_render_init(width, height) != 0) {
            return -1;
        }
        
        if (g_hw_render_cb.context_reset) {
            g_hw_context_reset_pending = 0;
            LOGI("HW render: context_reset after resize (%ux%u)", width, height);
            g_hw_render_cb.context_reset();
        }
    }

    if (g_hw_using_window_surface) {
        return hw_render_present();
    }

    if (!eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface, g_egl_context)) {
        LOGE("HW render: eglMakeCurrent failed before readback");
        return -1;
    }

    size_t rgba_needed = (size_t)width * height * 4;
    if (rgba_needed > g_hw_readback_rgba_capacity) {
        uint8_t* new_buf = (uint8_t*)realloc(g_hw_readback_rgba, rgba_needed);
        if (!new_buf) return -1;
        g_hw_readback_rgba = new_buf;
        g_hw_readback_rgba_capacity = rgba_needed;
    }

    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, (GLsizei)width, (GLsizei)height, GL_RGBA, GL_UNSIGNED_BYTE,
                 g_hw_readback_rgba);
    if (glGetError() != GL_NO_ERROR) {
        LOGE("HW render: glReadPixels failed");
        return -1;
    }

    for (unsigned y = 0; y < height; y++) {
        unsigned src_y = g_hw_render_cb.bottom_left_origin ? (height - 1 - y) : y;
        const uint8_t* src_row = g_hw_readback_rgba + ((size_t)src_y * width * 4);
        uint32_t* dst_row = out_abgr + ((size_t)y * width);
        for (unsigned x = 0; x < width; x++) {
            const uint8_t* px = src_row + ((size_t)x * 4);
            uint8_t r = px[0];
            uint8_t g = px[1];
            uint8_t b = px[2];
            dst_row[x] = 0xFF000000 | ((uint32_t)b << 16) | ((uint32_t)g << 8) | r;
        }
    }

    return 0;
}

#endif 
