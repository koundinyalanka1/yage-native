/*
 * YAGE Environment Callback Module
 *
 * Implements the libretro environment_callback — the main negotiation
 * channel between the frontend and the emulation core.
 *
 * Handles HW render setup, pixel format, variable system, memory maps,
 * logging, AV info, geometry, and extended multi-core commands.
 */

#include "yage_internal.h"


/* ── Libretro options structs (only needed for env callback parsing) ─── */
struct retro_variable {
    const char *key;
    const char *value;
};

struct retro_core_option_value {
    const char *value;
    const char *label;
};

#define RETRO_NUM_CORE_OPTION_VALUES_MAX 128
struct retro_core_option_v2_definition {
    const char *key;
    const char *desc;
    const char *desc_categorized;
    const char *info;
    const char *info_categorized;
    const char *category_key;
    struct retro_core_option_value values[RETRO_NUM_CORE_OPTION_VALUES_MAX];
    const char *default_value;
};

struct retro_core_option_v2_category {
    const char *key;
    const char *desc;
    const char *info;
};

struct retro_core_options_v2 {
    struct retro_core_option_v2_category *categories;
    struct retro_core_option_v2_definition *definitions;
};

struct retro_core_options_v2_intl {
    const struct retro_core_options_v2 *us;
    const struct retro_core_options_v2 *local;
};

/* ── Log callback struct (needed for GET_LOG_INTERFACE) ─────────────── */
typedef void (*retro_log_printf_t)(int level, const char* fmt, ...);
struct retro_log_callback {
    retro_log_printf_t log;
};

typedef int64_t retro_usec_t;
typedef void (*retro_frame_time_callback_t)(retro_usec_t usec);
struct retro_frame_time_callback {
    retro_frame_time_callback_t callback;
    retro_usec_t reference;
};

static retro_frame_time_callback_t g_frame_time_callback = NULL;
static retro_usec_t g_frame_time_reference = 0;

/* ── RetroArch-private environment commands ───────────────────────────
 * RETRO_ENVIRONMENT_RETROARCH_START_BLOCK (0x800000) marks frontend-
 * private commands.  mupen64plus-next requests
 * GET_CLEAR_ALL_THREAD_WAITS_CB (3 | 0x800000) during
 * retro_set_environment and stores the result as a FUNCTION POINTER that
 * it later calls UNCONDITIONALLY (no NULL check!) from retro_unload_game
 * and retro_serialize/unserialize whenever ThreadedRenderer is enabled.
 *
 * Two hard rules follow:
 *   1. We MUST install a valid callback here — returning false leaves the
 *      pointer NULL and the core crashes on unload (SIGSEGV at pc=0).
 *   2. The generic base_cmd fallback below must NEVER write through the
 *      data pointer of a private command.  That exact bug shipped once:
 *      0x800003 & 0xFFFF == 3 matched the GET_CAN_DUPE arm, wrote the
 *      bool `true` into the low byte of the function pointer, and the
 *      core later jumped to address 0x1 (SIGBUS BUS_ADRALN in
 *      retro_unload_game) every time the user exited an N64 game.
 *
 * RetroArch's implementation pauses/resumes its blocking audio driver
 * around thread-stopping operations.  Our audio path is a lock-free ring
 * buffer that never blocks the GL thread, so a no-op satisfies the
 * contract. */
#define YAGE_ENV_RETROARCH_PRIVATE_BLOCK        0x800000u
#define YAGE_ENV_GET_CLEAR_ALL_THREAD_WAITS_CB  (3u | YAGE_ENV_RETROARCH_PRIVATE_BLOCK)

typedef bool (*yage_retro_environment_t)(unsigned cmd, void* data);

static bool yage_clear_all_thread_waits(unsigned clear_threads, void* data) {
    (void)clear_threads;
    (void)data;
    /* No blocking audio/video threads to wake — nothing to do. */
    return true;
}

void yage_env_frame_time_reset(void) {
    g_frame_time_callback = NULL;
    g_frame_time_reference = 0;
}

void yage_env_frame_time_tick(void) {
    if (!g_frame_time_callback) return;
    retro_usec_t usec = g_frame_time_reference;
#ifndef _WIN32
    if (usec <= 0 && g_core_frame_ns > 0) {
        usec = (retro_usec_t)(g_core_frame_ns / 1000);
    }
#endif
    if (usec <= 0) usec = 16667;
    g_frame_time_callback(usec);
}

/* ══════════════════════════════════════════════════════════════════════
 * environment_callback
 * ══════════════════════════════════════════════════════════════════════ */

bool environment_callback(unsigned cmd, void* data) {
    const unsigned base_cmd = cmd & 0xFFFF;

    switch (cmd) {
        case 14: { /* RETRO_ENVIRONMENT_SET_HW_RENDER */
            if (!data) return false;
#ifdef __ANDROID__
            struct retro_hw_render_callback* cb = (struct retro_hw_render_callback*)data;

            /* Accept GLES2, GLES3, AND OpenGL Core (= 3).
             * melonDS libretro requests RETRO_HW_CONTEXT_OPENGL_CORE (3) via
             * glsm_ctl(GLSM_CTL_STATE_CONTEXT_INIT).  glsm is designed to run
             * on top of GLES3 on Android — we create a GLES3 context and lie
             * that it's OpenGL Core.  This is identical to what RetroArch does
             * on Android for all desktop-GL cores. */
            if (cb->context_type != RETRO_HW_CONTEXT_OPENGLES2 &&
                cb->context_type != RETRO_HW_CONTEXT_OPENGLES3 &&
                cb->context_type != RETRO_HW_CONTEXT_OPENGL_CORE) {
                LOGE("HW render: unsupported context type %d", (int)cb->context_type);
                return false;
            }

            cb->get_current_framebuffer = hw_get_current_framebuffer;
            cb->get_proc_address        = hw_get_proc_address;

            /* Idempotent re-negotiation.
             *
             * Some cores (notably melonDS) call SET_HW_RENDER multiple times
             * across the load+first-run boundary: once from retro_load_game,
             * then again from render_frame() when current_renderer is None.
             * If we honour every call with a full hw_render_init() we tear
             * down and recreate the EGL context the frame loop already
             * promoted to a window surface and successfully ran context_reset
             * against — corrupting the static shader[]/vao/ubo handles that
             * the core's render_opengl_frame is about to use.
             *
             * If HW render is already enabled and the context_type matches
             * the new request, just refresh the (identical) callback pointers
             * and return true.  No context recreation, no second context_reset,
             * GL handles stay valid. */
            if (g_hw_render_enabled &&
                g_egl_context != EGL_NO_CONTEXT &&
                g_hw_render_cb.context_type == cb->context_type) {
                g_hw_render_cb.context_reset    = cb->context_reset;
                g_hw_render_cb.context_destroy  = cb->context_destroy;
                g_hw_render_cb.version_major    = cb->version_major;
                g_hw_render_cb.version_minor    = cb->version_minor;
                g_hw_render_cb.depth            = cb->depth;
                g_hw_render_cb.stencil          = cb->stencil;
                g_hw_render_cb.bottom_left_origin = cb->bottom_left_origin;
                LOGI("HW render: SET_HW_RENDER re-negotiation accepted as "
                     "no-op (context already initialised)");
                return true;
            }

            g_hw_render_cb = *cb;

            if (hw_render_init((unsigned)g_width, (unsigned)g_height) != 0) {
                LOGE("HW render: initialization failed");
                return false;
            }

            LOGI("HW render negotiated: type=%d v%u.%u depth=%d stencil=%d",
                 (int)cb->context_type, cb->version_major, cb->version_minor,
                 cb->depth ? 1 : 0, cb->stencil ? 1 : 0);

            /* If SET_HW_RENDER fires outside retro_load_game, fire
             * context_reset synchronously so glsm_state_setup runs and the
             * core's setup_opengl creates shaders/VAOs/UBOs before the
             * caller's very next instruction. */
            if (!g_in_load_game && g_hw_context_reset_pending &&
                g_hw_render_cb.context_reset) {
                g_hw_context_reset_pending = 0;
                LOGI("HW render: firing context_reset synchronously "
                     "(SET_HW_RENDER outside retro_load_game)");
                g_hw_render_cb.context_reset();
            }
            return true;
#else
            return false;
#endif
        }
        case 10: /* RETRO_ENVIRONMENT_SET_PIXEL_FORMAT */
            if (data) {
                int requested = *(int*)data;
                LOGI("Core requested pixel format: %d", requested);
                g_pixel_format = requested;
            }
            return true;
        case 3: /* RETRO_ENVIRONMENT_GET_CAN_DUPE */
            if (data) *(bool*)data = true;
            return true;
        case 6: /* RETRO_ENVIRONMENT_SET_MESSAGE */
            return true;
        case 8: /* RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL */
            return true;
        case 23: /* RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE — not supported */
            return false;
        case 21: { /* RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK */
            if (!data) return false;
            const struct retro_frame_time_callback* cb =
                (const struct retro_frame_time_callback*)data;
            g_frame_time_callback = cb->callback;
            g_frame_time_reference = cb->reference;
            LOGI("SET_FRAME_TIME_CALLBACK: reference=%lld us",
                 (long long)g_frame_time_reference);
            return g_frame_time_callback != NULL;
        }
        case 9: /* RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY */
            if (data) {
                const char* sd = (g_current_core && g_current_core->system_dir)
                    ? g_current_core->system_dir : ".";
                *(const char**)data = sd;
                /* Diag: log what we hand back so we can see (a) whether the
                 * path matches the Dart-side BIOS upload location, and (b)
                 * whether the call even fires after a BIOS upload (vs the
                 * core caching its first-seen value).  Fires once per core
                 * load, not per frame. */
                static const char* last_logged = NULL;
                if (sd != last_logged) {
                    LOGI("GET_SYSTEM_DIRECTORY -> \"%s\"", sd);
                    last_logged = sd;
                }
            }
            return true;
        case 15: { /* RETRO_ENVIRONMENT_GET_VARIABLE */
            if (!data) return false;
            struct retro_variable* var = (struct retro_variable*)data;
            if (!var->key) return false;

            if (strcmp(var->key, "mgba_sgb_borders") == 0) {
                var->value = g_sgb_borders_enabled ? "ON" : "OFF";
                return true;
            }

            const char* stored = core_vars_get(var->key);
            if (stored) {
                /* Log OpenGL-critical variable reads to diagnose renderer init. */
                if (strstr(var->key, "opengl") || strstr(var->key, "renderer") ||
                    strstr(var->key, "hw_render")) {
                    LOGI("GET_VARIABLE: key=%s -> \"%s\"", var->key, stored);
                }
                var->value = stored;
                return true;
            }

            /* Return empty string instead of NULL to avoid core SIGSEGV. */
            var->value = "";
            return true;
        }
        case 16: /* RETRO_ENVIRONMENT_SET_VARIABLES */
            if (data) {
                core_vars_parse_set_variables((const struct retro_variable*)data);
                LOGI("SET_VARIABLES: stored %d variable defaults", g_core_vars_count);
            }
            return true;
        case 67: { /* RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2 */
            if (data) {
                core_vars_parse_set_core_options_v2(data);
                LOGI("SET_CORE_OPTIONS_V2: stored %d variable defaults", g_core_vars_count);
            }
            return true;
        }
        case 68: { /* RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL */
            if (data) {
                const struct retro_core_options_v2_intl* intl =
                    (const struct retro_core_options_v2_intl*)data;
                if (intl->local) {
                    core_vars_parse_set_core_options_v2(intl->local);
                } else if (intl->us) {
                    core_vars_parse_set_core_options_v2(intl->us);
                }
                LOGI("SET_CORE_OPTIONS_V2_INTL: stored %d variable defaults", g_core_vars_count);
            }
            return true;
        }
        case 17: { /* RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE */
            if (data) {
                *(bool*)data = g_variables_dirty ? true : false;
                g_variables_dirty = 0;
            }
            return true;
        }
        case 27: /* RETRO_ENVIRONMENT_GET_LOG_INTERFACE */
            if (data) {
                struct retro_log_callback* cb = (struct retro_log_callback*)data;
                cb->log = retro_log_printf_bridge;
                return true;
            }
            return false;
        case 31: /* RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY */
            if (data) {
                *(const char**)data = (g_current_core && g_current_core->save_dir)
                    ? g_current_core->save_dir : ".";
            }
            return true;
        case 36:      /* RETRO_ENVIRONMENT_SET_MEMORY_MAPS */
        case 0x10024: /* RETRO_ENVIRONMENT_SET_MEMORY_MAPS | EXPERIMENTAL */
            handle_set_memory_maps(data);
            return true;
        case 32: { /* RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO */
            if (data) {
                const struct retro_system_av_info* av =
                    (const struct retro_system_av_info*)data;
                if (av->geometry.base_width > 0)  g_width  = (int)av->geometry.base_width;
                if (av->geometry.base_height > 0) g_height = (int)av->geometry.base_height;
#ifdef __ANDROID__
                if (av->timing.sample_rate > 0.0)  g_reported_rate = av->timing.sample_rate;
#endif
#ifndef _WIN32
                if (av->timing.fps > 1.0 && av->timing.fps < 240.0)
                    g_core_frame_ns = (int64_t)(1000000000.0 / av->timing.fps);
#endif
                LOGI("SET_SYSTEM_AV_INFO: %ux%u fps=%.2f sr=%.0f",
                     av->geometry.base_width, av->geometry.base_height,
                     av->timing.fps, av->timing.sample_rate);
            }
            return true;
        }
        case 37: { /* RETRO_ENVIRONMENT_SET_GEOMETRY */
            if (data) {
                const struct retro_game_geometry* geom =
                    (const struct retro_game_geometry*)data;
                if (geom->base_width > 0)  g_width  = (int)geom->base_width;
                if (geom->base_height > 0) g_height = (int)geom->base_height;
                LOGI("SET_GEOMETRY: %ux%u (max %ux%u)",
                     geom->base_width, geom->base_height,
                     geom->max_width, geom->max_height);
            }
            return true;
        }
        case 38: /* RETRO_ENVIRONMENT_GET_USERNAME */
            if (data) *(const char**)data = "yage";
            return true;
        case 39: /* RETRO_ENVIRONMENT_GET_LANGUAGE */
            if (data) *(unsigned*)data = 0; /* RETRO_LANGUAGE_ENGLISH */
            return true;
        case 0x10033: /* RETRO_ENVIRONMENT_GET_INPUT_BITMASKS | EXPERIMENTAL */
            return true;
        case 44: /* RETRO_ENVIRONMENT_SET_HW_SHARED_CONTEXT
                 * Required by melonDS OpenGL renderer to share the EGL context
                 * between the two NDS screen framebuffers.  Must return true
                 * unconditionally — returning false causes the core to abort
                 * GL initialisation and fall back to software silently. */
            return true;
        case YAGE_ENV_GET_CLEAR_ALL_THREAD_WAITS_CB: {
            /* 0x800003 — see comment block above environment_callback.
             * mupen64plus-next (GLideN64 + ThreadedRenderer) calls the
             * returned pointer with no NULL check from retro_unload_game
             * and the savestate paths, so a real function must be
             * provided. */
            if (data) {
                *(yage_retro_environment_t*)data = yage_clear_all_thread_waits;
            }
            return true;
        }
        case 0x1002F: { /* RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE (47|EXPERIMENTAL)
                         * Frame loop sets g_floop_skip_video=1 on retro_runs
                         * that should drop video work (CPU-bound emulation
                         * frameskip). Bit 0 = video enabled, bit 1 = audio
                         * enabled, bit 2 = fast-savestates, bit 3 = hard
                         * audio mute. We always keep audio on so the elastic
                         * playback rate stays fed; video drops only on
                         * flagged frames.
                         *
                         * GL direct-present path: skip IS now allowed.
                         * GPU::SkipFrameRendering=true omits GPU2D scanlines,
                         * GPU3D VCount215 GL rasterisation, and the GL
                         * composite, saving ~7-17% of frame time. The FBO
                         * retains last-rendered content; the EGL surface holds
                         * the last swap so the display shows the previous
                         * frame cleanly. CPU-side GPU3D::Run() geometry is
                         * unconditional and unaffected by SkipFrameRendering. */
            if (data) {
                int flags = 2; /* ENABLE_AUDIO always on */
                int skip = atomic_load_explicit(&g_floop_skip_video,
                                                memory_order_relaxed);
                if (!skip) flags |= 1; /* ENABLE_VIDEO unless skipping */
                *(int*)data = flags;
            }
            return true;
        }
        default: {
            int is_multi_core = (g_core_lib_path &&
                (strstr(g_core_lib_path, "fceumm") ||
                 strstr(g_core_lib_path, "snes9x") ||
                 strstr(g_core_lib_path, "genesis_plus_gx") ||
                 strstr(g_core_lib_path, "mupen64plus_next") ||
                 strstr(g_core_lib_path, "mednafen_psx")));

            if (is_multi_core) {
                switch (cmd) {
                    case 52: if (data) *(unsigned*)data = 0; return true; /* GET_CORE_OPTIONS_VERSION */
                    case 59: if (data) *(unsigned*)data = 1; return true; /* GET_MESSAGE_INTERFACE_VERSION */
                    case 61: if (data) *(unsigned*)data = 1; return true; /* GET_INPUT_MAX_USERS */
                    case 0x10028: return false; /* GET_CURRENT_SOFTWARE_FRAMEBUFFER */
                    case 11: case 34: case 35: case 44:
                    case 53: case 54: case 55: case 60:
                    case 62: case 63: case 64: case 65:
                        return true;
                    case 67: case 68:
                        return true;
                    case 69: case 70: case 28: return true;
                    case 0x1002A: return true; /* SET_SUPPORT_ACHIEVEMENTS */
                    default: break;
                }

                /* The base_cmd fallback exists for EXPERIMENTAL-flagged
                 * variants (cmd | 0x10000) of standard commands.  It must
                 * NOT match RetroArch-private commands (cmd & 0x800000):
                 * their base ids alias unrelated standard ids and their
                 * data pointers have completely different types — e.g.
                 * GET_CLEAR_ALL_THREAD_WAITS_CB (0x800003) aliases
                 * GET_CAN_DUPE (3), and writing a bool into its function
                 * pointer made the core jump to address 0x1 on unload. */
                if (!(cmd & YAGE_ENV_RETROARCH_PRIVATE_BLOCK)) {
                    switch (base_cmd) {
                        case 3:  if (data) *(bool*)data = true; return true;
                        case 40: return false;
                        case 45: case 71: case 72: case 73: case 74:
                        case 75: case 77: case 79: case 80: case 81:
                        case 82: return false;
                        default: break;
                    }
                }
            }

            if (g_log_frame_count < 5) LOGI("Unhandled env cmd: %u (0x%X)", cmd, cmd);
            return false;
        }
    }
}
