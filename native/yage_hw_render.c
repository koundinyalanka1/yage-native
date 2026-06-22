/*
 * YAGE HW Render Module
 *
 * EGL/OpenGL ES context management for hardware-rendered cores (Android only).
 * Handles EGL context creation, teardown, and pixel readback for cores like
 * mupen64plus-next that render via OpenGL ES rather than software buffers.
 */

#include "yage_internal.h"

#ifdef __ANDROID__

/* ── EGL / HW render state ───────────────────────────────────────────── */
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
    return 0; /* default framebuffer */
}

retro_proc_address_t hw_get_proc_address(const char* sym) {
    if (!sym) return NULL;
    retro_proc_address_t p = (retro_proc_address_t)eglGetProcAddress(sym);
    if (p) return p;
    return (retro_proc_address_t)dlsym(RTLD_DEFAULT, sym);
}

void hw_render_shutdown(void) {
    /* M27: tear down the worker's shared context first (the frame loop has
     * already stopped + joined the worker thread at this point). */
    hw_render_worker_destroy();

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

/* Cached EGL config so surface-only re-creation uses the same format as the
 * context (otherwise eglMakeCurrent fails with EGL_BAD_MATCH). */
static EGLConfig g_egl_cfg = NULL;

/* Build the EGL surface (window if a native window is attached, pbuffer
 * fallback otherwise). Caller owns the choice of when to call this. */
static EGLSurface hw_render_create_surface(unsigned width, unsigned height,
                                           int* out_is_window,
                                           ANativeWindow** out_win_ref) {
    *out_is_window = 0;
    *out_win_ref   = NULL;

    pthread_mutex_lock(&g_nw_mutex);
    ANativeWindow* win = g_native_window;
    if (win) ANativeWindow_acquire(win);
    pthread_mutex_unlock(&g_nw_mutex);

    EGLSurface surf = EGL_NO_SURFACE;

    if (win) {
        ANativeWindow_setBuffersGeometry(win, (int)width, (int)height,
                                         WINDOW_FORMAT_RGBA_8888);
        surf = eglCreateWindowSurface(g_egl_display, g_egl_cfg,
                                      (EGLNativeWindowType)win, NULL);
        if (surf != EGL_NO_SURFACE) {
            *out_is_window = 1;
            *out_win_ref   = win;
            LOGI("HW render: created EGL window surface (%ux%u)", width, height);
            /* ── Preserved swap behaviour (anti-flicker) ────────────────
             * The core renders straight into FBO 0 of this window surface
             * (hw_get_current_framebuffer returns 0) and we eglSwapBuffers
             * after each rendered frame.  With the default BUFFER_DESTROYED
             * behaviour the back buffer content is undefined after a swap,
             * so any game frame that does NOT fully redraw FBO 0 presents
             * stale garbage from 2-3 swaps ago.  GLideN64 does exactly that
             * on framebuffer-effect screens (Pokemon Stadium 1/2 press-
             * start screen, battle transitions): the visible result is the
             * screen "blinking" between the real image and a stale buffer.
             * RetroArch is immune because cores render into an off-screen
             * FBO there; for our direct-to-window path, BUFFER_PRESERVED
             * gives the same guarantee — after a swap the back buffer
             * keeps the previous frame, so partial redraws compose
             * correctly.  Cost: one GPU-internal copy per swap at the
             * render resolution (≤ 640×480 for N64) — negligible.
             * If the driver/config rejects it we just log and continue
             * with the default behaviour. */
            if (eglSurfaceAttrib(g_egl_display, surf,
                                 EGL_SWAP_BEHAVIOR, EGL_BUFFER_PRESERVED)) {
                LOGI("HW render: EGL_BUFFER_PRESERVED enabled on window surface");
            } else {
                LOGI("HW render: EGL_BUFFER_PRESERVED not supported "
                     "(err=0x%x) — using default swap behaviour",
                     (unsigned)eglGetError());
            }
            return surf;
        }
        LOGE("HW render: eglCreateWindowSurface failed (err=0x%x), "
             "falling back to pbuffer", (unsigned)eglGetError());
        ANativeWindow_release(win);
    }

    EGLint surf_attrs[] = {
        EGL_WIDTH,  (EGLint)width,
        EGL_HEIGHT, (EGLint)height,
        EGL_NONE
    };
    surf = eglCreatePbufferSurface(g_egl_display, g_egl_cfg, surf_attrs);
    if (surf != EGL_NO_SURFACE) {
        LOGI("HW render: created EGL pbuffer surface (%ux%u)", width, height);
    } else {
        LOGE("HW render: eglCreatePbufferSurface failed (%ux%u, err=0x%x)",
             width, height, (unsigned)eglGetError());
    }
    return surf;
}

int hw_render_init(unsigned width, unsigned height) {
    if (width == 0) width = N64_WIDTH;
    if (height == 0) height = N64_HEIGHT;

    /* ── FAST PATH: context already alive, swap surface only ──────────────
     *
     * Destroying the EGL context invalidates every GL object the core
     * created in context_reset (FBOs, VAOs, shaders, textures, UBOs).
     * Recreating those via a second context_reset is fragile — the core's
     * static GL handle globals (melonDS: shader[], vao, vbo) might be left
     * pointing at handles from the dead context, and glsm's internal state
     * (gl_state.vao, bind_textures.ids) is only partially refreshed by
     * STATE_SETUP. To keep the GL state across resizes / pbuffer→window
     * promotion / window→window resize, we preserve the EGL context and
     * just swap the surface. The core never sees a context_destroy and
     * never needs a second context_reset. */
    if (g_egl_display != EGL_NO_DISPLAY && g_egl_context != EGL_NO_CONTEXT) {
        /* Already the right surface type and size — no-op (caller may still
         * need to eglMakeCurrent on its own thread; that's handled below). */
        ANativeWindow* cur_native_window = NULL;
        pthread_mutex_lock(&g_nw_mutex);
        cur_native_window = g_native_window;
        pthread_mutex_unlock(&g_nw_mutex);
        int want_window = (cur_native_window != NULL) ? 1 : 0;

        /* Fast-path no-op ONLY when size, surface type, AND the backing native
         * window all still match. The window-identity check is critical: after
         * an app background→foreground (or any SurfaceTexture recreation) the
         * Java side calls nativeSetSurface(), which builds a brand-new
         * ANativeWindow via ANativeWindow_fromSurface() while width/height and
         * the window-vs-pbuffer type are unchanged. Without comparing the actual
         * window we kept the old EGL window surface, whose BufferQueue had been
         * abandoned, so every eglSwapBuffers failed (EGL_BAD_SURFACE 0x300d) and
         * glBindFramebuffer raised GL_INVALID_OPERATION — emulation (and audio)
         * kept running but not a single frame was ever presented. Detecting the
         * window change here falls through to the surface-swap path below, which
         * destroys the stale surface and recreates it against the live window. */
        if (width == g_hw_fb_width && height == g_hw_fb_height &&
            want_window == g_hw_using_window_surface &&
            (!want_window || cur_native_window == g_hw_window_ref)) {
            /* Same config — only bind the context to the calling thread if
             * it isn't already current here. */
            if (eglGetCurrentContext() != g_egl_context) {
                if (!eglMakeCurrent(g_egl_display, g_egl_surface,
                                    g_egl_surface, g_egl_context)) {
                    LOGE("HW render: eglMakeCurrent failed on no-op rebind "
                         "(err=0x%x)", (unsigned)eglGetError());
                    return -1;
                }
            }
            return 0;
        }

        /* Surface needs to change. CRITICAL: destroy the old surface
         * BEFORE trying to create the new one, otherwise
         * eglCreateWindowSurface returns EGL_BAD_ALLOC (0x3003) because
         * EGL forbids two window surfaces on the same ANativeWindow.
         * That used to send us into a pbuffer-fallback + glReadPixels
         * loop every frame (which then also failed).
         *
         * Order:
         *   1. eglMakeCurrent(NO_CONTEXT) — release the surface from
         *      whichever thread holds it.
         *   2. eglDestroySurface(old) + ANativeWindow_release(old_win) —
         *      free the native window slot.
         *   3. Create the new surface (window if g_native_window present,
         *      pbuffer fallback otherwise).
         *   4. eglMakeCurrent(new, ..., context) — rebind preserved context. */
        eglMakeCurrent(g_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       EGL_NO_CONTEXT);

        if (g_egl_surface != EGL_NO_SURFACE) {
            eglDestroySurface(g_egl_display, g_egl_surface);
            g_egl_surface = EGL_NO_SURFACE;
        }
        if (g_hw_window_ref) {
            ANativeWindow_release(g_hw_window_ref);
            g_hw_window_ref = NULL;
        }
        g_hw_using_window_surface = 0;

        int is_window = 0;
        ANativeWindow* win_ref = NULL;
        EGLSurface new_surface = hw_render_create_surface(
            width, height, &is_window, &win_ref);
        if (new_surface == EGL_NO_SURFACE) {
            /* Both window and pbuffer creation failed — we have NO surface
             * now (old was already destroyed). The context is orphaned;
             * caller will see -1 and abort. This is a hard failure but
             * extremely rare (out of GPU memory). */
            LOGE("HW render: surface swap failed — context now has no "
                 "surface and is unusable");
            return -1;
        }

        if (!eglMakeCurrent(g_egl_display, new_surface, new_surface,
                            g_egl_context)) {
            LOGE("HW render: eglMakeCurrent failed on new surface "
                 "(err=0x%x)", (unsigned)eglGetError());
            eglDestroySurface(g_egl_display, new_surface);
            if (win_ref) ANativeWindow_release(win_ref);
            return -1;
        }

        g_egl_surface             = new_surface;
        g_hw_using_window_surface = is_window;
        g_hw_window_ref           = win_ref;
        g_hw_fb_width             = width;
        g_hw_fb_height            = height;

        LOGI("HW render: swapped EGL surface to %ux%u (direct=%d) without "
             "destroying context", width, height, is_window);
        return 0;
    }

    /* ── SLOW PATH: first-time init — create display, config, context ────
     * Followed by the first surface and an initial eglMakeCurrent.  The
     * context_reset callback is set to pending; whoever calls hw_render_init
     * is responsible for firing it at the libretro-spec-safe moment
     * (env_callback if outside retro_load_game, frame loop otherwise). */
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
    if (g_hw_render_cb.context_type == RETRO_HW_CONTEXT_OPENGLES3 ||
        g_hw_render_cb.context_type == RETRO_HW_CONTEXT_OPENGL_CORE) {
        /* OPENGL_CORE is mapped to a GLES3 context on Android (glsm design).
         * EGL configs for GLES3 contexts require ES3_BIT_KHR; without it
         * eglCreateContext with CLIENT_VERSION=3 will return NO_CONTEXT. */
        renderable |= EGL_OPENGL_ES3_BIT_KHR;
    }

    /* Adreno (and several other mobile GPUs) only ship EGL configs with
     * depth+stencil **packed** together (24/8 or 16/0).  Requesting
     * EGL_DEPTH_SIZE=24 with EGL_STENCIL_SIZE=0 either picks a config that
     * leaves the default framebuffer's stencil bitplane in an undefined
     * state (so FBO 0 reports GL_FRAMEBUFFER_INCOMPLETE on the very first
     * draw — every clear/draw silently fails with GL_INVALID_OPERATION),
     * or it picks no config at all.  Always request stencil = 8 whenever
     * depth is requested.  The core doesn't have to use stencil, but
     * having the bitplane present is what Adreno needs to consider the
     * default framebuffer complete. */
    EGLint stencil_bits = g_hw_render_cb.stencil ? 8 : 0;
    if (g_hw_render_cb.depth && stencil_bits == 0) {
        stencil_bits = 8;
    }

    /* EGL_SWAP_BEHAVIOR_PRESERVED_BIT: request a config whose window
     * surfaces support EGL_BUFFER_PRESERVED (see hw_render_create_surface
     * — required to stop partial-redraw games like Pokemon Stadium from
     * blinking).  Some drivers don't advertise it; fall back to a config
     * without the bit rather than failing the whole init. */
    EGLint cfg_attrs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT | EGL_WINDOW_BIT |
                          EGL_SWAP_BEHAVIOR_PRESERVED_BIT,
        EGL_RENDERABLE_TYPE, renderable,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, g_hw_render_cb.depth ? 24 : 0,
        EGL_STENCIL_SIZE, stencil_bits,
        EGL_NONE
    };

    EGLint num_cfg = 0;
    if (!eglChooseConfig(g_egl_display, cfg_attrs, &g_egl_cfg, 1, &num_cfg) ||
        num_cfg < 1) {
        LOGI("HW render: no EGL config with SWAP_BEHAVIOR_PRESERVED_BIT — "
             "retrying without it");
        cfg_attrs[1] = EGL_PBUFFER_BIT | EGL_WINDOW_BIT;
        num_cfg = 0;
        if (!eglChooseConfig(g_egl_display, cfg_attrs, &g_egl_cfg, 1,
                             &num_cfg) || num_cfg < 1) {
            LOGE("HW render: eglChooseConfig failed");
            hw_render_shutdown();
            return -1;
        }
    }

    int is_window = 0;
    ANativeWindow* win_ref = NULL;
    g_egl_surface = hw_render_create_surface(width, height,
                                             &is_window, &win_ref);
    if (g_egl_surface == EGL_NO_SURFACE) {
        hw_render_shutdown();
        return -1;
    }
    g_hw_using_window_surface = is_window;
    g_hw_window_ref           = win_ref;

    if (!eglBindAPI(EGL_OPENGL_ES_API)) {
        LOGE("HW render: eglBindAPI failed");
        hw_render_shutdown();
        return -1;
    }

    int requested_major = (g_hw_render_cb.version_major >= 3 ||
                           g_hw_render_cb.context_type == RETRO_HW_CONTEXT_OPENGLES3 ||
                           g_hw_render_cb.context_type == RETRO_HW_CONTEXT_OPENGL_CORE)
        ? 3
        : 2;

    EGLint ctx_attrs[] = {
        EGL_CONTEXT_CLIENT_VERSION, requested_major,
        EGL_NONE
    };
    g_egl_context = eglCreateContext(g_egl_display, g_egl_cfg,
                                     EGL_NO_CONTEXT, ctx_attrs);
    if (g_egl_context == EGL_NO_CONTEXT && requested_major == 3) {
        EGLint fallback_ctx_attrs[] = {
            EGL_CONTEXT_CLIENT_VERSION, 2,
            EGL_NONE
        };
        g_egl_context = eglCreateContext(g_egl_display, g_egl_cfg,
                                         EGL_NO_CONTEXT, fallback_ctx_attrs);
    }
    if (g_egl_context == EGL_NO_CONTEXT) {
        LOGE("HW render: eglCreateContext failed");
        hw_render_shutdown();
        return -1;
    }

    if (!eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface,
                        g_egl_context)) {
        LOGE("HW render: eglMakeCurrent failed");
        hw_render_shutdown();
        return -1;
    }

    /* Defer context_reset; see comment block above for rules. */
    g_hw_context_reset_pending = 1;

    g_hw_render_enabled = 1;
    g_hw_fb_width  = width;
    g_hw_fb_height = height;
    LOGI("HW render: EGL context ready (%ux%u, requested GLES %d, direct=%d)",
         width, height, requested_major, g_hw_using_window_surface);
    return 0;
}

int hw_render_is_direct_present(void) {
    return (g_hw_render_enabled && g_hw_using_window_surface) ? 1 : 0;
}

/* ── M27 render-worker shared EGL context ─────────────────────────────────
 * The render worker executes the core's deferred GL2D composite on its own
 * EGL context, created in the SAME share group as the core's context so
 * textures/buffers/programs are shared (FBOs/VAOs are not — the core builds
 * worker-local clones of those). A 1×1 pbuffer satisfies "a surface must be
 * current"; the worker only ever renders into FBOs. */
static EGLContext g_worker_egl_context = EGL_NO_CONTEXT;
static EGLSurface g_worker_egl_surface = EGL_NO_SURFACE;

int hw_render_worker_bind(void) {
    if (g_egl_display == EGL_NO_DISPLAY || g_egl_context == EGL_NO_CONTEXT ||
        g_egl_cfg == NULL) {
        return -1;
    }

    if (g_worker_egl_context != EGL_NO_CONTEXT &&
        eglGetCurrentContext() == g_worker_egl_context) {
        return 0;   /* already bound on this thread */
    }

    if (g_worker_egl_context == EGL_NO_CONTEXT) {
        /* Match the main context's client version (3 with a 2 fallback,
         * mirroring hw_render_init). A version mismatch inside one share
         * group is invalid on several drivers. */
        EGLint ctx3[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
        g_worker_egl_context = eglCreateContext(g_egl_display, g_egl_cfg,
                                                g_egl_context, ctx3);
        if (g_worker_egl_context == EGL_NO_CONTEXT) {
            EGLint ctx2[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
            g_worker_egl_context = eglCreateContext(g_egl_display, g_egl_cfg,
                                                    g_egl_context, ctx2);
        }
        if (g_worker_egl_context == EGL_NO_CONTEXT) {
            LOGE("M27: eglCreateContext (shared, worker) failed (err=0x%x)",
                 (unsigned)eglGetError());
            return -1;
        }

        EGLint sattrs[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
        g_worker_egl_surface = eglCreatePbufferSurface(g_egl_display, g_egl_cfg, sattrs);
        if (g_worker_egl_surface == EGL_NO_SURFACE) {
            LOGE("M27: worker pbuffer surface failed (err=0x%x)",
                 (unsigned)eglGetError());
            eglDestroyContext(g_egl_display, g_worker_egl_context);
            g_worker_egl_context = EGL_NO_CONTEXT;
            return -1;
        }
        LOGI("M27: worker shared EGL context + 1x1 pbuffer created");
    }

    if (!eglMakeCurrent(g_egl_display, g_worker_egl_surface,
                        g_worker_egl_surface, g_worker_egl_context)) {
        LOGE("M27: eglMakeCurrent (worker) failed (err=0x%x)", (unsigned)eglGetError());
        return -1;
    }
    return 0;
}

void hw_render_worker_unbind(void) {
    if (g_egl_display != EGL_NO_DISPLAY &&
        g_worker_egl_context != EGL_NO_CONTEXT &&
        eglGetCurrentContext() == g_worker_egl_context) {
        eglMakeCurrent(g_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
}

void hw_render_worker_destroy(void) {
    if (g_egl_display == EGL_NO_DISPLAY) {
        g_worker_egl_context = EGL_NO_CONTEXT;
        g_worker_egl_surface = EGL_NO_SURFACE;
        return;
    }
    if (g_worker_egl_context != EGL_NO_CONTEXT) {
        eglDestroyContext(g_egl_display, g_worker_egl_context);
        g_worker_egl_context = EGL_NO_CONTEXT;
    }
    if (g_worker_egl_surface != EGL_NO_SURFACE) {
        eglDestroySurface(g_egl_display, g_worker_egl_surface);
        g_worker_egl_surface = EGL_NO_SURFACE;
    }
}

int hw_render_present(void) {
    if (!g_hw_render_enabled || !g_hw_using_window_surface) return -1;
    if (g_egl_display == EGL_NO_DISPLAY || g_egl_surface == EGL_NO_SURFACE ||
        g_egl_context == EGL_NO_CONTEXT) return -1;

    /* After pause/resume the frame loop starts a new thread.  The "defer"
     * path in frame_loop_thread skips eglMakeCurrent because it expects
     * hw_render_readback to handle re-init.  But when g_hw_using_window_surface
     * is already 1 (window surface from the previous session), hw_render_readback
     * skips re-init and calls us directly — and the context is not yet current
     * on this thread.  Lazily bind here; eglGetCurrentContext() is a cheap TLS
     * read when the context is already current, so this adds no cost to the
     * normal (already-bound) case. */
    if (eglGetCurrentContext() != g_egl_context) {
        if (!eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface, g_egl_context)) {
            LOGE("HW render: eglMakeCurrent failed in present (err=0x%x)", (unsigned)eglGetError());
            return -1;
        }
        LOGI("HW render: EGL context lazily bound to frame thread in present");
    }

    /* Drain any GL errors that leaked out of the core's render path.  The
     * core's own CHECK_GL macros catch most call sites but not all, and any
     * leftover error here would be misattributed to YAGE's own GL calls
     * below.  Capture the last-seen code so the per-60-frame diagnostic can
     * still surface what's leaking without spamming every frame. */
    unsigned drained_errors = 0;
    GLenum   drained_last   = GL_NO_ERROR;
    for (GLenum e; (e = glGetError()) != GL_NO_ERROR; ) {
        drained_last = e;
        drained_errors++;
    }

    /* Flush any pending commands before swapping (critical for some Mali/Adreno drivers) */
    glFlush();

    /* Ensure we are actually presenting FBO 0 */
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    /* Diagnostic: read SEVERAL pixels to figure out what's rendered where.
     * For a 1024x1536 NDS layout the EGL surface is split:
     *   top screen    ≈ y in [0, h/2)    — center sample at (w/2, h/4)
     *   gap/middle    ≈ y ≈ h/2          — center sample at (w/2, h/2)
     *   bottom screen ≈ y in (h/2, h)    — center sample at (w/2, 3h/4)
     *
     * The readback path is compiled OUT in normal builds: each glReadPixels
     * on Mali tilers forces a pipeline flush + GPU→CPU sync that can stall
     * the frame for 5–20 ms.  TV captures on the Sony BRAVIA showed this
     * single throttled probe (5+ readbacks every 60 frames) holding the
     * core at ~30 fps when it could otherwise run at 60.  Re-enable with
     * -DYAGE_HW_PRESENT_DIAG=1 when investigating a render regression. */
#ifdef YAGE_HW_PRESENT_DIAG
    static int    diag_count    = 0;
    static GLenum diag_last_err = GL_NO_ERROR;
    if (drained_errors > 0) diag_last_err = drained_last;
    if (diag_count % 60 == 0) {
        uint8_t top[4] = {0}, mid[4] = {0}, bot[4] = {0}, corner[4] = {0};
        glReadPixels(g_hw_fb_width / 2, g_hw_fb_height / 4, 1, 1,
                     GL_RGBA, GL_UNSIGNED_BYTE, top);
        glReadPixels(g_hw_fb_width / 2, g_hw_fb_height / 2, 1, 1,
                     GL_RGBA, GL_UNSIGNED_BYTE, mid);
        glReadPixels(g_hw_fb_width / 2, (g_hw_fb_height * 3) / 4, 1, 1,
                     GL_RGBA, GL_UNSIGNED_BYTE, bot);
        glReadPixels(10, 10, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, corner);
        LOGI("HW present [%d]: surface=%ux%u top=(%d,%d,%d,%d) "
             "mid=(%d,%d,%d,%d) bot=(%d,%d,%d,%d) corner10x10=(%d,%d,%d,%d) "
             "drained=%u (last=0x%04x)",
             diag_count, g_hw_fb_width, g_hw_fb_height,
             top[0], top[1], top[2], top[3],
             mid[0], mid[1], mid[2], mid[3],
             bot[0], bot[1], bot[2], bot[3],
             corner[0], corner[1], corner[2], corner[3],
             drained_errors, (unsigned)diag_last_err);

        /* ── Sanity probe: can we write to FBO 0 at all? ──────────────────
         * The diagnostic above keeps reading (0,0,0,0) — including alpha
         * 0 — which means the fragment shader never ran for any pixel of
         * the EGL surface.  Before concluding the bug is in the core's
         * draw path, prove the surface itself is writable.  We use
         * glScissor + glClear to paint a tiny 8x8 patch in the bottom-
         * right corner of the surface (which is otherwise undrawn by the
         * NDS layout), read it back, and dump current GL state so we can
         * see what the core left bound when the draw didn't produce
         * fragments. */
        GLint  prev_scissor[4]    = {0,0,0,0};
        GLint  prev_viewport[4]   = {0,0,0,0};
        GLint  prev_fbo           = -1;
        GLint  prev_program       = -1;
        GLboolean prev_scissor_on = GL_FALSE;
        GLboolean prev_cmask[4]   = {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE};
        GLfloat prev_clear[4]     = {0,0,0,0};
        glGetIntegerv(GL_SCISSOR_BOX, prev_scissor);
        glGetIntegerv(GL_VIEWPORT, prev_viewport);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_fbo);
        glGetIntegerv(GL_CURRENT_PROGRAM, &prev_program);
        prev_scissor_on = glIsEnabled(GL_SCISSOR_TEST);
        glGetBooleanv(GL_COLOR_WRITEMASK, prev_cmask);
        glGetFloatv(GL_COLOR_CLEAR_VALUE, prev_clear);

        /* Probe (visible patch DISABLED 2026-05-28 — surface presentation
         * has been verified working).  The diagnostic readback + state-
         * dump is KEPT so we still have visibility if anything regresses.
         *
         * Re-enable the visible cycling patch by defining
         * YAGE_HW_PRESENT_VISIBLE_PROBE at compile time. */
        const GLint probe_w = 256, probe_h = 256;
        const GLint probe_x = (GLint)g_hw_fb_width  - probe_w;
        const GLint probe_y = (GLint)g_hw_fb_height - probe_h;

        while (glGetError() != GL_NO_ERROR) {}

        GLenum fbo_status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        GLenum err_after_status = glGetError();

        GLint impl_fmt = 0, impl_type = 0;
        glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_FORMAT, &impl_fmt);
        glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_TYPE,   &impl_type);

        GLenum err_after_cmask = GL_NO_ERROR;
        GLenum err_after_scissor = GL_NO_ERROR;
        GLenum err_after_clear   = GL_NO_ERROR;
        float pr = 0.0f, pg = 0.0f, pb = 0.0f;

#ifdef YAGE_HW_PRESENT_VISIBLE_PROBE
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        err_after_cmask = glGetError();
        glEnable(GL_SCISSOR_TEST);
        glScissor(probe_x, probe_y, probe_w, probe_h);
        static int probe_color_phase = 0;
        pr = (probe_color_phase % 3) == 0 ? 1.0f : 0.0f;
        pg = (probe_color_phase % 3) == 1 ? 1.0f : 0.0f;
        pb = (probe_color_phase % 3) == 2 ? 1.0f : 0.0f;
        probe_color_phase++;
        glClearColor(pr, pg, pb, 1.0f);
        err_after_scissor = glGetError();
        glClear(GL_COLOR_BUFFER_BIT);
        err_after_clear = glGetError();
#endif

        /* Try the implementation-preferred format first; if it errors,
         * fall back to the spec-guaranteed GL_RGBA + GL_UNSIGNED_BYTE. */
        uint8_t probe_px[4] = {0,0,0,0};
        glReadPixels(probe_x + probe_w / 2, probe_y + probe_h / 2, 1, 1,
                     impl_fmt, impl_type, probe_px);
        GLenum err_read_impl = glGetError();
        GLenum err_read_spec = GL_NO_ERROR;
        if (err_read_impl != GL_NO_ERROR) {
            uint8_t fb_probe[4] = {0,0,0,0};
            glReadPixels(probe_x + probe_w / 2, probe_y + probe_h / 2, 1, 1,
                         GL_RGBA, GL_UNSIGNED_BYTE, fb_probe);
            err_read_spec = glGetError();
            memcpy(probe_px, fb_probe, sizeof(probe_px));
        }

        LOGI("HW present probe steps: fbo_status=0x%04x (COMPLETE=0x8CD5) "
             "impl_fmt=0x%04x impl_type=0x%04x "
             "err_status=0x%04x err_cmask=0x%04x err_scissor=0x%04x "
             "err_clear=0x%04x err_read_impl=0x%04x err_read_spec=0x%04x "
             "clear=(%.2f,%.2f,%.2f) probe_xy=(%d,%d) %dx%d",
             fbo_status, impl_fmt, impl_type,
             err_after_status, err_after_cmask,
             err_after_scissor, err_after_clear,
             err_read_impl, err_read_spec,
             pr, pg, pb, probe_x, probe_y, probe_w, probe_h);
        GLenum probe_err = err_read_impl != GL_NO_ERROR ? err_read_spec : err_read_impl;

        /* Restore previous state so the next frame's blit is unaffected.
         * Only needed if the visible probe modified state. */
#ifdef YAGE_HW_PRESENT_VISIBLE_PROBE
        if (!prev_scissor_on) glDisable(GL_SCISSOR_TEST);
        glScissor(prev_scissor[0], prev_scissor[1],
                  prev_scissor[2], prev_scissor[3]);
        glColorMask(prev_cmask[0], prev_cmask[1], prev_cmask[2], prev_cmask[3]);
        glClearColor(prev_clear[0], prev_clear[1], prev_clear[2], prev_clear[3]);
#endif

        LOGI("HW present probe: clear-then-read=(%d,%d,%d,%d) err=0x%04x "
             "fbo=%d prog=%d viewport=(%d,%d,%d,%d) "
             "scissor_on=%d scissor=(%d,%d,%d,%d) "
             "cmask=(%d,%d,%d,%d) clear=(%.2f,%.2f,%.2f,%.2f)",
             probe_px[0], probe_px[1], probe_px[2], probe_px[3],
             (unsigned)probe_err,
             prev_fbo, prev_program,
             prev_viewport[0], prev_viewport[1],
             prev_viewport[2], prev_viewport[3],
             (int)prev_scissor_on,
             prev_scissor[0], prev_scissor[1],
             prev_scissor[2], prev_scissor[3],
             (int)prev_cmask[0], (int)prev_cmask[1],
             (int)prev_cmask[2], (int)prev_cmask[3],
             prev_clear[0], prev_clear[1], prev_clear[2], prev_clear[3]);

        diag_last_err = GL_NO_ERROR;
        while (glGetError() != GL_NO_ERROR) { /* discard */ }
    }
    diag_count++;
#else
    (void)drained_last;
    (void)drained_errors;
#endif /* YAGE_HW_PRESENT_DIAG */

    /* Errors from OUR glFlush / glBindFramebuffer here would be a real bug. */
    GLenum our_err = glGetError();
    if (our_err != GL_NO_ERROR) {
        LOGE("HW present: unexpected OpenGL error 0x%04x in YAGE present path",
             our_err);
    }

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
        /* hw_render_init now preserves the EGL context across surface
         * resizes — it only swaps the underlying EGLSurface. The core's
         * GL objects (FBOs, VAOs, shaders, textures) stay valid, so no
         * second context_reset is required. Firing it again would call
         * context_destroy → context_reset on a still-live context, which
         * leaves melonDS's static GL handle globals (shader[], vao, vbo,
         * screen_framebuffer_texture) pointing at stale IDs and produces
         * GL_INVALID_FRAMEBUFFER_OPERATION on the next glBindFramebuffer. */

        if (g_hw_using_window_surface) {
            /* ── Direct-present resize: present first, THEN resize ────────
             *
             * The core just rendered this frame into FBO 0 on the CURRENT
             * surface. If we destroy the surface first (hw_render_init) we
             * lose that rendered content and present a blank/garbage frame.
             *
             * Fix: present (eglSwapBuffers) the current frame on the OLD
             * surface — the submitted buffer stays in the queue and reaches
             * the SurfaceTexture consumer even after the EGL surface object
             * is destroyed. Then resize for the NEXT frame.
             *
             * The one-frame dimension mismatch (rendered at viewport W×H
             * on a surface that might be larger/smaller) is acceptable:
             *  - If surface > viewport: extra area was cleared to black
             *    (see glClear below after resize). The SurfaceTexture/Flutter
             *    compositor stretches or letterboxes as configured.
             *  - If surface < viewport: bottom/right edges get clipped by
             *    the physical buffer (GPU silently discards OOB writes).
             *    Still better than presenting a blank surface.
             */
            hw_render_present();
            if (hw_render_init(width, height) != 0) {
                return -1;
            }
            /* Clear the new surface so any area outside the core's viewport
             * is black rather than uninitialized garbage (the "yellow and
             * red lines" artifact).  The depth buffer is also cleared so the
             * next frame's depth test starts clean. */
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
            glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
            glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
            return 0; /* frame already presented above */
        }

        if (hw_render_init(width, height) != 0) {
            return -1;
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

    /* Drain any GL errors leaked from the core's render path so the
     * post-glReadPixels check only sees errors actually caused by the
     * readback itself.  Without this, an unchecked GL_INVALID_OPERATION
     * from melonDS's compositor would be misattributed to glReadPixels
     * and abort every frame. */
    while (glGetError() != GL_NO_ERROR) { /* discard */ }

    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, (GLsizei)width, (GLsizei)height, GL_RGBA, GL_UNSIGNED_BYTE,
                 g_hw_readback_rgba);
    GLenum readback_err = glGetError();
    if (readback_err != GL_NO_ERROR) {
        LOGE("HW render: glReadPixels failed (err=0x%04x, %ux%u)",
             (unsigned)readback_err, width, height);
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

#endif /* __ANDROID__ */
