/*
 * YAGE GPU Texture Module (Android-specific)
 *
 * Implements zero-copy GPU rendering pipeline using AHardwareBuffer.
 * Allows N64 core to render directly to a texture that Flutter composites
 * without frame data ever leaving the GPU.
 *
 * Workflow:
 *   1. Create AHardwareBuffer for target resolution
 *   2. Bind to OpenGL as texture
 *   3. Core renders directly to this texture via GPU framebuffer
 *   4. Mark texture "dirty" after each frame
 *   5. Flutter's Texture widget reads directly from GPU (no CPU copy)
 */

#include "yage_internal.h"

#ifdef __ANDROID__

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>  /* GL_TEXTURE_EXTERNAL_OES and OES extension types */
#include <android/hardware_buffer.h>
#include <android/hardware_buffer_jni.h>

#if __ANDROID_API__ >= 26

/* ── AHardwareBuffer state (file-private) ─────────────────────────── */
static AHardwareBuffer*    g_gpu_hwbuffer         = NULL;
static EGLClientBuffer     g_gpu_egl_client_buf   = NULL;
static EGLImage            g_gpu_egl_image        = EGL_NO_IMAGE;
static GLuint              g_gpu_texture_id       = 0;
static unsigned            g_gpu_buf_width        = 0;
static unsigned            g_gpu_buf_height       = 0;
static int                 g_gpu_texture_dirty    = 0;
static pthread_mutex_t     g_gpu_hwbuffer_mutex   = PTHREAD_MUTEX_INITIALIZER;

/* ── Function pointer for eglCreateImageKHR (may not exist in base EGL) ─ */
static PFNEGLCREATEIMAGEKHRPROC eglCreateImageKHR   = NULL;
static PFNEGLDESTROYIMAGEKHRPROC eglDestroyImageKHR = NULL;
static PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC eglGetNativeClientBufferANDROIDProc = NULL;
static PFNGLEGLIMAGETARGETTEXTURE2DOESPROC glEGLImageTargetTexture2DOESProc = NULL;

/* ══════════════════════════════════════════════════════════════════════
 * Init / Shutdown — AHardwareBuffer and EGL Image lifecycle
 * ══════════════════════════════════════════════════════════════════════ */

int gpu_hwbuffer_init(unsigned width, unsigned height) {
    pthread_mutex_lock(&g_gpu_hwbuffer_mutex);

    if (g_gpu_hwbuffer != NULL) {
        LOGI("GPU texture: buffer already initialized (%ux%u)", g_gpu_buf_width, g_gpu_buf_height);
        pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
        return 0;
    }

    if (width == 0) width = N64_WIDTH;
    if (height == 0) height = N64_HEIGHT;

    /* Load EGL image extension functions (may fail on older devices) */
    eglCreateImageKHR = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
    eglDestroyImageKHR = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
    eglGetNativeClientBufferANDROIDProc =
        (PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC)eglGetProcAddress("eglGetNativeClientBufferANDROID");
    glEGLImageTargetTexture2DOESProc =
        (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");

    if (!eglCreateImageKHR || !eglDestroyImageKHR ||
        !eglGetNativeClientBufferANDROIDProc || !glEGLImageTargetTexture2DOESProc) {
        LOGE("GPU texture: EGL KHR image extensions not available");
        pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
        return -1;
    }

    /* Create AHardwareBuffer with RGBA8 format, GPU render + GPU read */
    AHardwareBuffer_Desc desc = {
        .width = width,
        .height = height,
        .layers = 1,
        .format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM,
        .usage = AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT | AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE,
        .stride = 0,
    };

    int result = AHardwareBuffer_allocate(&desc, &g_gpu_hwbuffer);
    if (result != 0 || g_gpu_hwbuffer == NULL) {
        LOGE("GPU texture: AHardwareBuffer_allocate failed (result=%d)", result);
        pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
        return -1;
    }

    /* Get EGL client buffer from AHardwareBuffer */
    g_gpu_egl_client_buf = eglGetNativeClientBufferANDROIDProc(g_gpu_hwbuffer);
    if (!g_gpu_egl_client_buf) {
        LOGE("GPU texture: eglGetNativeClientBufferANDROID failed");
        AHardwareBuffer_release(g_gpu_hwbuffer);
        g_gpu_hwbuffer = NULL;
        pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
        return -1;
    }

    /* Create EGL Image from client buffer (for OpenGL binding) */
    EGLint egl_img_attrs[] = { EGL_NONE };
    g_gpu_egl_image = eglCreateImageKHR(
        g_egl_display,
        EGL_NO_CONTEXT,
        EGL_NATIVE_BUFFER_ANDROID,
        g_gpu_egl_client_buf,
        egl_img_attrs
    );

    if (g_gpu_egl_image == EGL_NO_IMAGE) {
        LOGE("GPU texture: eglCreateImageKHR failed");
        AHardwareBuffer_release(g_gpu_hwbuffer);
        g_gpu_hwbuffer = NULL;
        g_gpu_egl_client_buf = NULL;
        pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
        return -1;
    }

    /* Create OpenGL texture from EGL image */
    glGenTextures(1, &g_gpu_texture_id);
    glBindTexture(GL_TEXTURE_2D, g_gpu_texture_id);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glEGLImageTargetTexture2DOESProc(GL_TEXTURE_2D, g_gpu_egl_image);

    GLenum gl_err = glGetError();
    if (gl_err != GL_NO_ERROR) {
        LOGE("GPU texture: glEGLImageTargetTexture2DOES failed (0x%04X)", gl_err);
        glDeleteTextures(1, &g_gpu_texture_id);
        g_gpu_texture_id = 0;
        eglDestroyImageKHR(g_egl_display, g_gpu_egl_image);
        g_gpu_egl_image = EGL_NO_IMAGE;
        AHardwareBuffer_release(g_gpu_hwbuffer);
        g_gpu_hwbuffer = NULL;
        pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
        return -1;
    }

    glBindTexture(GL_TEXTURE_2D, 0);

    g_gpu_buf_width = width;
    g_gpu_buf_height = height;
    g_gpu_texture_dirty = 0;

    LOGI("GPU texture: AHardwareBuffer initialized (%ux%u, texture=%u)", width, height, g_gpu_texture_id);

    pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
    return 0;
}

void gpu_hwbuffer_shutdown(void) {
    pthread_mutex_lock(&g_gpu_hwbuffer_mutex);

    if (g_gpu_texture_id != 0) {
        glDeleteTextures(1, &g_gpu_texture_id);
        g_gpu_texture_id = 0;
    }

    if (g_gpu_egl_image != EGL_NO_IMAGE) {
        if (eglDestroyImageKHR) {
            eglDestroyImageKHR(g_egl_display, g_gpu_egl_image);
        }
        g_gpu_egl_image = EGL_NO_IMAGE;
    }

    if (g_gpu_hwbuffer != NULL) {
        AHardwareBuffer_release(g_gpu_hwbuffer);
        g_gpu_hwbuffer = NULL;
    }

    g_gpu_egl_client_buf = NULL;
    g_gpu_buf_width = 0;
    g_gpu_buf_height = 0;
    g_gpu_texture_dirty = 0;

    LOGI("GPU texture: AHardwareBuffer shutdown");

    pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
}

/* ══════════════════════════════════════════════════════════════════════
 * Accessors — Texture ID and status
 * ══════════════════════════════════════════════════════════════════════ */

uint32_t gpu_hwbuffer_get_texture_id(void) {
    pthread_mutex_lock(&g_gpu_hwbuffer_mutex);
    uint32_t tex_id = (uint32_t)g_gpu_texture_id;
    pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
    return tex_id;
}

int gpu_hwbuffer_is_ready(void) {
    pthread_mutex_lock(&g_gpu_hwbuffer_mutex);
    int ready = (g_gpu_hwbuffer != NULL && g_gpu_texture_id != 0) ? 1 : 0;
    pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
    return ready;
}

unsigned gpu_hwbuffer_get_width(void) {
    pthread_mutex_lock(&g_gpu_hwbuffer_mutex);
    unsigned w = g_gpu_buf_width;
    pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
    return w;
}

unsigned gpu_hwbuffer_get_height(void) {
    pthread_mutex_lock(&g_gpu_hwbuffer_mutex);
    unsigned h = g_gpu_buf_height;
    pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
    return h;
}

/* ══════════════════════════════════════════════════════════════════════
 * Mark texture dirty / signal frame ready
 * ══════════════════════════════════════════════════════════════════════ */

void gpu_hwbuffer_mark_dirty(void) {
    pthread_mutex_lock(&g_gpu_hwbuffer_mutex);
    g_gpu_texture_dirty = 1;
    pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
}

int gpu_hwbuffer_is_dirty(void) {
    pthread_mutex_lock(&g_gpu_hwbuffer_mutex);
    int dirty = g_gpu_texture_dirty;
    g_gpu_texture_dirty = 0; /* Clear flag after reading */
    pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
    return dirty;
}

/* ══════════════════════════════════════════════════════════════════════
 * Utility — Resize buffer if needed
 * ══════════════════════════════════════════════════════════════════════ */

int gpu_hwbuffer_resize_if_needed(unsigned new_width, unsigned new_height) {
    pthread_mutex_lock(&g_gpu_hwbuffer_mutex);

    if (g_gpu_hwbuffer != NULL &&
        g_gpu_buf_width == new_width &&
        g_gpu_buf_height == new_height) {
        pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
        return 0; /* No resize needed */
    }

    pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);

    /* Shutdown and reinit with new size */
    gpu_hwbuffer_shutdown();
    return gpu_hwbuffer_init(new_width, new_height);
}

/* ══════════════════════════════════════════════════════════════════════
 * Framebuffer attachment — Bind GPU texture as render target
 * ══════════════════════════════════════════════════════════════════════ */

int gpu_hwbuffer_attach_to_fb(uint32_t framebuffer) {
    pthread_mutex_lock(&g_gpu_hwbuffer_mutex);

    if (g_gpu_texture_id == 0) {
        LOGE("GPU texture: attach_to_fb called but texture_id is 0");
        pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);
        return -1;
    }

    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, g_gpu_texture_id, 0);

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    pthread_mutex_unlock(&g_gpu_hwbuffer_mutex);

    if (status != GL_FRAMEBUFFER_COMPLETE) {
        LOGE("GPU texture: framebuffer incomplete (status=0x%04X)", status);
        return -1;
    }

    return 0;
}

#else

/* API < 26: AHardwareBuffer APIs are unavailable at compile time. */

int gpu_hwbuffer_init(unsigned width, unsigned height) {
    (void)width;
    (void)height;
    return -1;
}

void gpu_hwbuffer_shutdown(void) {
    /* No-op */
}

uint32_t gpu_hwbuffer_get_texture_id(void) {
    return 0;
}

int gpu_hwbuffer_is_ready(void) {
    return 0;
}

unsigned gpu_hwbuffer_get_width(void) {
    return 0;
}

unsigned gpu_hwbuffer_get_height(void) {
    return 0;
}

void gpu_hwbuffer_mark_dirty(void) {
    /* No-op */
}

int gpu_hwbuffer_is_dirty(void) {
    return 0;
}

int gpu_hwbuffer_resize_if_needed(unsigned new_width, unsigned new_height) {
    (void)new_width;
    (void)new_height;
    return -1;
}

int gpu_hwbuffer_attach_to_fb(uint32_t framebuffer) {
    (void)framebuffer;
    return -1;
}

#endif /* __ANDROID_API__ >= 26 */

#else

/* ── Stub implementations for non-Android platforms ──────────────────── */

int gpu_hwbuffer_init(unsigned width, unsigned height) {
    (void)width;
    (void)height;
    return -1; /* Not supported on this platform */
}

void gpu_hwbuffer_shutdown(void) {
    /* No-op on non-Android */
}

uint32_t gpu_hwbuffer_get_texture_id(void) {
    return 0;
}

int gpu_hwbuffer_is_ready(void) {
    return 0;
}

unsigned gpu_hwbuffer_get_width(void) {
    return 0;
}

unsigned gpu_hwbuffer_get_height(void) {
    return 0;
}

void gpu_hwbuffer_mark_dirty(void) {
    /* No-op */
}

int gpu_hwbuffer_is_dirty(void) {
    return 0;
}

int gpu_hwbuffer_resize_if_needed(unsigned new_width, unsigned new_height) {
    (void)new_width;
    (void)new_height;
    return -1;
}

int gpu_hwbuffer_attach_to_fb(uint32_t framebuffer) {
    (void)framebuffer;
    return -1;
}

#endif /* __ANDROID__ */
