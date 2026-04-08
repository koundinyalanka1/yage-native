#include "yage_internal.h"

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

typedef void (*retro_log_printf_t)(int level, const char* fmt, ...);
struct retro_log_callback {
    retro_log_printf_t log;
};

bool environment_callback(unsigned cmd, void* data) {
    const unsigned base_cmd = cmd & 0xFFFF;

    switch (cmd) {
        case 14: { 
            if (!data) return false;
#ifdef __ANDROID__
            struct retro_hw_render_callback* cb = (struct retro_hw_render_callback*)data;

            if (cb->context_type != RETRO_HW_CONTEXT_OPENGLES2 &&
                cb->context_type != RETRO_HW_CONTEXT_OPENGLES3) {
                LOGE("HW render: unsupported context type %d", (int)cb->context_type);
                return false;
            }

            cb->get_current_framebuffer = hw_get_current_framebuffer;
            cb->get_proc_address        = hw_get_proc_address;
            g_hw_render_cb = *cb;

            if (hw_render_init((unsigned)g_width, (unsigned)g_height) != 0) {
                LOGE("HW render: initialization failed");
                return false;
            }

            LOGI("HW render negotiated: type=%d v%u.%u depth=%d stencil=%d",
                 (int)cb->context_type, cb->version_major, cb->version_minor,
                 cb->depth ? 1 : 0, cb->stencil ? 1 : 0);
            return true;
#else
            return false;
#endif
        }
        case 10: 
            if (data) {
                int requested = *(int*)data;
                LOGI("Core requested pixel format: %d", requested);
                g_pixel_format = requested;
            }
            return true;
        case 3: 
            if (data) *(bool*)data = true;
            return true;
        case 6: 
            return true;
        case 8: 
            return true;
        case 23: 
            return false;
        case 9: 
            if (data) {
                *(const char**)data = (g_current_core && g_current_core->system_dir)
                    ? g_current_core->system_dir : ".";
            }
            return true;
        case 15: { 
            if (!data) return false;
            struct retro_variable* var = (struct retro_variable*)data;
            if (!var->key) return false;

            if (strcmp(var->key, "mgba_sgb_borders") == 0) {
                var->value = g_sgb_borders_enabled ? "ON" : "OFF";
                return true;
            }

            const char* stored = core_vars_get(var->key);
            if (stored) { var->value = stored; return true; }

            
            var->value = "";
            return true;
        }
        case 16: 
            if (data) {
                core_vars_parse_set_variables((const struct retro_variable*)data);
                LOGI("SET_VARIABLES: stored %d variable defaults", g_core_vars_count);
            }
            return true;
        case 67: { 
            if (data) {
                core_vars_parse_set_core_options_v2(data);
                LOGI("SET_CORE_OPTIONS_V2: stored %d variable defaults", g_core_vars_count);
            }
            return true;
        }
        case 68: { 
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
        case 17: { 
            if (data) {
                *(bool*)data = g_variables_dirty ? true : false;
                g_variables_dirty = 0;
            }
            return true;
        }
        case 27: 
            if (data) {
                struct retro_log_callback* cb = (struct retro_log_callback*)data;
                cb->log = retro_log_printf_bridge;
                return true;
            }
            return false;
        case 31: 
            if (data) {
                *(const char**)data = (g_current_core && g_current_core->save_dir)
                    ? g_current_core->save_dir : ".";
            }
            return true;
        case 36:      
        case 0x10024: 
            handle_set_memory_maps(data);
            return true;
        case 32: { 
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
        case 37: { 
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
        case 38: 
            if (data) *(const char**)data = "yage";
            return true;
        case 39: 
            if (data) *(unsigned*)data = 0; 
            return true;
        case 0x10033: 
            return true;
        default: {
            int is_multi_core = (g_core_lib_path &&
                (strstr(g_core_lib_path, "fceumm") ||
                 strstr(g_core_lib_path, "snes9x") ||
                 strstr(g_core_lib_path, "genesis_plus_gx") ||
                 strstr(g_core_lib_path, "mupen64plus_next")));

            if (is_multi_core) {
                switch (cmd) {
                    case 52: if (data) *(unsigned*)data = 0; return true; 
                    case 59: if (data) *(unsigned*)data = 1; return true; 
                    case 61: if (data) *(unsigned*)data = 1; return true; 
                    case 0x10028: return false; 
                    case 11: case 34: case 35: case 44:
                    case 53: case 54: case 55: case 60:
                    case 62: case 63: case 64: case 65:
                        return true;
                    case 67: case 68:
                        return true;
                    case 69: case 70: case 28: return true;
                    case 0x1002A: return true; 
                    default: break;
                }

                switch (base_cmd) {
                    case 3:  if (data) *(bool*)data = true; return true;
                    case 40: return false;
                    case 45: case 71: case 72: case 73: case 74:
                    case 75: case 77: case 79: case 80: case 81:
                    case 82: return false;
                    default: break;
                }
            }

            if (g_log_frame_count < 5) LOGI("Unhandled env cmd: %u (0x%X)", cmd, cmd);
            return false;
        }
    }
}
