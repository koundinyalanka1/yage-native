#include "yage_internal.h"

void** g_rewind_snapshots  = NULL;
int    g_rewind_head       = 0;
int    g_rewind_count      = 0;
int    g_rewind_capacity   = 0;
size_t g_rewind_state_size = 0;

int yage_core_save_state(YageCore* core, int slot) {
    if (!core || !core->game_loaded || !core->state_buffer) return -1;
    if (!core->retro_serialize) return -1;

    if (!core->retro_serialize(core->state_buffer, core->state_size)) return -1;

    if (core->save_dir && core->rom_path) {
        char path[1024];
        const char* rom_name = strrchr(core->rom_path, '/');
        if (!rom_name) rom_name = strrchr(core->rom_path, '\\');
        if (!rom_name) rom_name = core->rom_path; else rom_name++;
        snprintf(path, sizeof(path), "%s/%s.ss%d", core->save_dir, rom_name, slot);

        FILE* f = fopen(path, "wb");
        if (f) {
            size_t written = fwrite(core->state_buffer, 1, core->state_size, f);
            fclose(f);
            if (written == core->state_size) return 0;
            LOGE("Save state: partial write (%zu of %zu bytes)", written, core->state_size);
        }
    }
    return -1;
}

int yage_core_load_state(YageCore* core, int slot) {
    if (!core || !core->game_loaded || !core->state_buffer) return -1;
    if (!core->retro_unserialize) return -1;

    if (core->save_dir && core->rom_path) {
        char path[1024];
        const char* rom_name = strrchr(core->rom_path, '/');
        if (!rom_name) rom_name = strrchr(core->rom_path, '\\');
        if (!rom_name) rom_name = core->rom_path; else rom_name++;
        snprintf(path, sizeof(path), "%s/%s.ss%d", core->save_dir, rom_name, slot);

        FILE* f = fopen(path, "rb");
        if (f) {
            size_t read_count = fread(core->state_buffer, 1, core->state_size, f);
            fclose(f);
            if (read_count == core->state_size &&
                core->retro_unserialize(core->state_buffer, core->state_size)) {
                return 0;
            }
        }
    }
    return -1;
}

int yage_core_rewind_init(YageCore* core, int capacity) {
    if (!core || !core->game_loaded || !core->retro_serialize_size) return -1;

    yage_core_rewind_deinit(core);

    g_rewind_state_size = core->retro_serialize_size();
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

    if (!core->retro_serialize(g_rewind_snapshots[g_rewind_head], g_rewind_state_size))
        return -1;

    g_rewind_head = (g_rewind_head + 1) % g_rewind_capacity;
    if (g_rewind_count < g_rewind_capacity) g_rewind_count++;
    return 0;
}

int yage_core_rewind_pop(YageCore* core) {
    if (!core || !core->retro_unserialize || !g_rewind_snapshots) return -1;
    if (g_rewind_count == 0) return -1;

    g_rewind_head = (g_rewind_head - 1 + g_rewind_capacity) % g_rewind_capacity;
    g_rewind_count--;

    if (!core->retro_unserialize(g_rewind_snapshots[g_rewind_head], g_rewind_state_size))
        return -1;
    return 0;
}

int yage_core_rewind_count(YageCore* core) {
    (void)core;
    return g_rewind_count;
}

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

    size_t size = core->retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (size == 0) { LOGI("No SRAM to save (size=0)"); return 0; }

    void* data = core->retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!data) { LOGE("Failed to get SRAM data pointer"); return -1; }

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

    size_t size = core->retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (size == 0) { LOGI("No SRAM expected (size=0)"); return 0; }

    void* data = core->retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!data) { LOGE("Failed to get SRAM data pointer"); return -1; }

    FILE* file = fopen(path, "rb");
    if (!file) { LOGI("No save file found: %s (starting fresh)", path); return 0; }

    size_t read_size = fread(data, 1, size, file);
    fclose(file);
    if (read_size > 0) { LOGI("Loaded SRAM from %s (%zu bytes)", path, read_size); return 0; }
    LOGE("Failed to read SRAM data");
    return -1;
}

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
