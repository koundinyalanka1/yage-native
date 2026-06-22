/*
 * YAGE State Module
 *
 * Save state, rewind ring-buffer, SRAM (battery save), and cheat codes.
 */

#include "yage_internal.h"

/* ── Rewind ring-buffer globals ──────────────────────────────────────── */
void** g_rewind_snapshots  = NULL;
int    g_rewind_head       = 0;
int    g_rewind_count      = 0;
int    g_rewind_capacity   = 0;
size_t g_rewind_state_size = 0;

/* ══════════════════════════════════════════════════════════════════════
 * Save state (file-based, per-slot)
 * ══════════════════════════════════════════════════════════════════════ */

static int yage_is_melonds_nds(YageCore* core) {
    return core &&
           core->platform == YAGE_PLATFORM_NDS &&
           g_core_lib_path &&
           strstr(g_core_lib_path, "melonds");
}

#ifdef __ANDROID__
static int yage_state_bind_hw_context(const char* op) {
    int quiet = (op && strstr(op, "rewind") != NULL) ? 1 : 0;
    if (!g_hw_render_enabled) {
        if (!quiet) {
            LOGI("Save state: %s does not need EGL bind (hw_render=0)",
                 op ? op : "state op");
        }
        return 0;
    }
    if (g_egl_display == EGL_NO_DISPLAY ||
        g_egl_surface == EGL_NO_SURFACE ||
        g_egl_context == EGL_NO_CONTEXT) {
        if (!quiet) {
            LOGI("Save state: %s cannot bind EGL yet (display=%p surface=%p ctx=%p)",
                 op ? op : "state op",
                 (void*)g_egl_display, (void*)g_egl_surface, (void*)g_egl_context);
        }
        return 0;
    }

    EGLContext current = eglGetCurrentContext();
    if (current == g_egl_context) {
        if (!quiet) {
            LOGI("Save state: EGL context already current for %s (ctx=%p)",
                 op ? op : "state op", (void*)current);
        }
        return 0;
    }

    if (!eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface,
                        g_egl_context)) {
        LOGE("Save state: eglMakeCurrent failed before %s "
             "(err=0x%x current=%p target=%p)",
             op ? op : "state op", (unsigned)eglGetError(),
             (void*)current, (void*)g_egl_context);
        return -1;
    }

    if (!quiet) {
        LOGI("Save state: EGL context bound for %s (prev=%p target=%p)",
             op ? op : "state op", (void*)current, (void*)g_egl_context);
    }
    return quiet ? 2 : 1;
}

static void yage_state_release_hw_context(int bind_result) {
    if (bind_result > 0 &&
        g_egl_display != EGL_NO_DISPLAY &&
        eglGetCurrentContext() == g_egl_context) {
        eglMakeCurrent(g_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       EGL_NO_CONTEXT);
        if (bind_result == 1) {
            LOGI("Save state: EGL context released after state op (ctx=%p)",
                 (void*)g_egl_context);
        }
    } else if (bind_result > 0) {
        if (bind_result == 1) {
            LOGI("Save state: EGL release skipped; context changed before release");
        }
    }
}
#else
static int yage_state_bind_hw_context(const char* op) {
    (void)op;
    return 0;
}

static void yage_state_release_hw_context(int bind_result) {
    (void)bind_result;
}
#endif

int yage_core_save_state(YageCore* core, int slot) {
    if (!core || !core->game_loaded || !core->state_buffer) return -1;
    if (!core->retro_serialize) return -1;

    LOGI("Save state: begin save slot=%d platform=%d size=%zu core=%s",
         slot, core->platform, core->state_size,
         g_core_lib_path ? g_core_lib_path : "(unknown)");

    int hw_bind = yage_state_bind_hw_context("serialize");
    if (hw_bind < 0) return -1;

    int serialized = core->retro_serialize(core->state_buffer, core->state_size) ? 1 : 0;
    yage_state_release_hw_context(hw_bind);
    if (!serialized) {
        LOGE("Save state: retro_serialize failed slot=%d size=%zu", slot, core->state_size);
        return -1;
    }

    if (core->save_dir && core->rom_path) {
        char path[1024];
        const char* rom_name = strrchr(core->rom_path, '/');
        if (!rom_name) rom_name = strrchr(core->rom_path, '\\');
        if (!rom_name) rom_name = core->rom_path; else rom_name++;
        snprintf(path, sizeof(path), "%s/%s.ss%d", core->save_dir, rom_name, slot);

        FILE* f = fopen(path, "wb");
        if (f) {
            LOGI("Save state: writing slot=%d path=%s", slot, path);
            size_t written = fwrite(core->state_buffer, 1, core->state_size, f);
            fclose(f);
            if (written == core->state_size) {
                LOGI("Save state: wrote %s (%zu bytes)", path, core->state_size);
                return 0;
            }
            LOGE("Save state: partial write (%zu of %zu bytes)", written, core->state_size);
        } else {
            LOGE("Save state: failed to open state file for write: %s", path);
        }
    } else {
        LOGE("Save state: missing save_dir or rom_path for slot=%d", slot);
    }
    return -1;
}

int yage_core_load_state(YageCore* core, int slot) {
    if (!core || !core->game_loaded || !core->state_buffer) return -1;
    if (!core->retro_unserialize) return -1;

    LOGI("Save state: begin load slot=%d platform=%d size=%zu core=%s",
         slot, core->platform, core->state_size,
         g_core_lib_path ? g_core_lib_path : "(unknown)");

    if (core->save_dir && core->rom_path) {
        char path[1024];
        const char* rom_name = strrchr(core->rom_path, '/');
        if (!rom_name) rom_name = strrchr(core->rom_path, '\\');
        if (!rom_name) rom_name = core->rom_path; else rom_name++;
        snprintf(path, sizeof(path), "%s/%s.ss%d", core->save_dir, rom_name, slot);

        FILE* f = fopen(path, "rb");
        if (f) {
            LOGI("Save state: reading slot=%d path=%s", slot, path);
            size_t read_count = fread(core->state_buffer, 1, core->state_size, f);
            fclose(f);
            if (read_count == core->state_size) {
                int hw_bind = yage_state_bind_hw_context("unserialize");
                if (hw_bind < 0) return -1;

                int loaded = core->retro_unserialize(core->state_buffer, core->state_size) ? 1 : 0;
                yage_state_release_hw_context(hw_bind);
                if (loaded) {
                    LOGI("Save state: loaded %s (%zu bytes)", path, core->state_size);
                    return 0;
                }
                LOGE("Save state: retro_unserialize failed slot=%d path=%s", slot, path);
            } else {
                LOGE("Load state: size mismatch for slot %d (%zu of %zu bytes)",
                     slot, read_count, core->state_size);
            }
        } else {
            LOGE("Save state: failed to open state file for read: %s", path);
        }
    } else {
        LOGE("Save state: missing save_dir or rom_path for slot=%d", slot);
    }
    return -1;
}

/* ══════════════════════════════════════════════════════════════════════
 * Rewind ring-buffer
 * ══════════════════════════════════════════════════════════════════════ */

int yage_core_rewind_init(YageCore* core, int capacity) {
    if (!core || !core->game_loaded || !core->retro_serialize_size) return -1;

    yage_core_rewind_deinit(core);

    int hw_bind = yage_state_bind_hw_context("rewind serialize_size");
    if (hw_bind < 0) return -1;

    g_rewind_state_size = core->retro_serialize_size();
    yage_state_release_hw_context(hw_bind);
    if (g_rewind_state_size == 0) return -1;

    if (capacity <= 0 || capacity > 1024) capacity = 36;

    g_rewind_snapshots = (void**)calloc(capacity, sizeof(void*));
    if (!g_rewind_snapshots) return -1;

    for (int i = 0; i < capacity; i++) {
        g_rewind_snapshots[i] = malloc(g_rewind_state_size);
        if (!g_rewind_snapshots[i]) {
            for (int j = 0; j < i; j++) free(g_rewind_snapshots[j]);
            free(g_rewind_snapshots);
            g_rewind_snapshots = NULL;
            return -1;
        }
    }

    g_rewind_capacity = capacity;
    g_rewind_head     = 0;
    g_rewind_count    = 0;

    LOGI("Rewind initialized: %d slots x %zu bytes = %.1f MB",
         capacity, g_rewind_state_size,
         (capacity * g_rewind_state_size) / (1024.0 * 1024.0));
    return 0;
}

void yage_core_rewind_deinit(YageCore* core) {
    (void)core;
    if (g_rewind_snapshots) {
        for (int i = 0; i < g_rewind_capacity; i++) {
            if (g_rewind_snapshots[i]) free(g_rewind_snapshots[i]);
        }
        free(g_rewind_snapshots);
        g_rewind_snapshots = NULL;
    }
    g_rewind_head       = 0;
    g_rewind_count      = 0;
    g_rewind_capacity   = 0;
    g_rewind_state_size = 0;
}

int yage_core_rewind_push(YageCore* core) {
    if (!core || !core->retro_serialize || !g_rewind_snapshots) return -1;
    if (g_rewind_capacity == 0 || g_rewind_state_size == 0) return -1;

    int hw_bind = yage_state_bind_hw_context("rewind serialize");
    if (hw_bind < 0) return -1;

    int serialized =
        core->retro_serialize(g_rewind_snapshots[g_rewind_head], g_rewind_state_size)
            ? 1
            : 0;
    yage_state_release_hw_context(hw_bind);
    if (!serialized)
        return -1;

    g_rewind_head = (g_rewind_head + 1) % g_rewind_capacity;
    if (g_rewind_count < g_rewind_capacity) g_rewind_count++;
    return 0;
}

int yage_core_rewind_pop(YageCore* core) {
    if (!core || !core->retro_unserialize || !g_rewind_snapshots) return -1;
    if (g_rewind_count == 0) return -1;

    int target = (g_rewind_head - 1 + g_rewind_capacity) % g_rewind_capacity;

    int hw_bind = yage_state_bind_hw_context("rewind unserialize");
    if (hw_bind < 0) return -1;

    int loaded =
        core->retro_unserialize(g_rewind_snapshots[target], g_rewind_state_size)
            ? 1
            : 0;
    yage_state_release_hw_context(hw_bind);
    if (!loaded)
        return -1;

    g_rewind_head = target;
    g_rewind_count--;
    return 0;
}

int yage_core_rewind_count(YageCore* core) {
    (void)core;
    return g_rewind_count;
}

/* ══════════════════════════════════════════════════════════════════════
 * SRAM (battery save)
 * ══════════════════════════════════════════════════════════════════════ */

int yage_core_get_sram_size(YageCore* core) {
    if (!core || !core->initialized || !core->retro_get_memory_size) return 0;
    return (int)core->retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
}

uint8_t* yage_core_get_sram_data(YageCore* core) {
    if (!core || !core->initialized || !core->retro_get_memory_data) return NULL;
    return (uint8_t*)core->retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
}

int yage_core_save_sram(YageCore* core, const char* path) {
    if (!core || !core->initialized || !path) return -1;
    if (!core->retro_get_memory_size || !core->retro_get_memory_data) return -1;

    LOGI("NDS SRAM: save request platform=%d path=%s core=%s",
         core->platform, path, g_core_lib_path ? g_core_lib_path : "(unknown)");

    if (yage_is_melonds_nds(core)) {
        LOGI("NDS SRAM: melonDS manages this .sav internally; frontend bridge is a no-op: %s",
             path);
        return 0;
    }

    size_t size = core->retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    LOGI("NDS SRAM: generic save RAM size=%zu path=%s", size, path);
    if (size == 0) { LOGI("No SRAM to save (size=0)"); return 0; }

    void* data = core->retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!data) { LOGE("Failed to get SRAM data pointer"); return -1; }

    /* Diagnostic: a save that is entirely 0x00 (or 0xFF) means the core's SRAM
     * buffer was never populated by an in-game save — writing it would make the
     * title screen show "New Game". Surface that here instead of silently
     * persisting an empty file. */
    size_t nonzero = 0;
    const uint8_t* sb = (const uint8_t*)data;
    for (size_t i = 0; i < size; i++) { if (sb[i] != 0x00 && sb[i] != 0xFF) { nonzero++; } }
    LOGI("SRAM save content: %zu/%zu meaningful bytes (first=0x%02x)",
         nonzero, size, sb[0]);

    FILE* file = fopen(path, "wb");
    if (!file) { LOGE("Failed to open save file: %s", path); return -1; }

    size_t written = fwrite(data, 1, size, file);
    fclose(file);
    if (written == size) { LOGI("Saved SRAM to %s (%zu bytes)", path, size); return 0; }
    LOGE("Failed to write SRAM (wrote %zu of %zu bytes)", written, size);
    return -1;
}

int yage_core_load_sram(YageCore* core, const char* path) {
    if (!core || !core->initialized || !path) return -1;
    if (!core->retro_get_memory_size || !core->retro_get_memory_data) return -1;

    LOGI("NDS SRAM: load request platform=%d path=%s core=%s",
         core->platform, path, g_core_lib_path ? g_core_lib_path : "(unknown)");

    if (yage_is_melonds_nds(core)) {
        LOGI("NDS SRAM: melonDS loaded this .sav during ROM load/reset; "
             "frontend bridge is a no-op: %s", path);
        return 0;
    }

    size_t size = core->retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    LOGI("NDS SRAM: generic load RAM size=%zu path=%s", size, path);
    if (size == 0) { LOGI("No SRAM expected (size=0)"); return 0; }

    void* data = core->retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!data) { LOGE("Failed to get SRAM data pointer"); return -1; }

    FILE* file = fopen(path, "rb");
    if (!file) { LOGI("No save file found: %s (starting fresh)", path); return 0; }

    size_t read_size = fread(data, 1, size, file);
    fclose(file);
    if (read_size > 0) {
        /* Diagnostic: if the restored buffer is all 0x00/0xFF the .sav on disk
         * is empty — the game will boot to "New Game" even though a file exists.
         * This distinguishes a save-load bug from an empty-.sav (save-side) bug. */
        size_t nonzero = 0;
        const uint8_t* lb = (const uint8_t*)data;
        for (size_t i = 0; i < read_size; i++) { if (lb[i] != 0x00 && lb[i] != 0xFF) { nonzero++; } }
        LOGI("Loaded SRAM from %s (%zu bytes, %zu meaningful)", path, read_size, nonzero);
        return 0;
    }
    LOGE("Failed to read SRAM data");
    return -1;
}

/* ══════════════════════════════════════════════════════════════════════
 * Cheat codes
 * ══════════════════════════════════════════════════════════════════════ */

int yage_core_cheat_reset(YageCore* core) {
    if (!core || !core->game_loaded || !core->retro_cheat_reset) return -1;
    core->retro_cheat_reset();
    return 0;
}

int yage_core_cheat_set(YageCore* core, unsigned index, int enabled, const char* code) {
    if (!core || !core->game_loaded || !core->retro_cheat_set) return -1;
    if (!code) return -1;
    core->retro_cheat_set(index, enabled != 0, code);
    return 0;
}
