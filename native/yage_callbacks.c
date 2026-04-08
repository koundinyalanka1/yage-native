#include "yage_internal.h"

struct retro_memory_descriptor_lc {
    uint64_t    flags;
    void*       ptr;
    size_t      offset;
    size_t      start;
    size_t      select;
    size_t      disconnect;
    size_t      len;
    const char* addrspace;
};

struct retro_memory_map_lc {
    const struct retro_memory_descriptor_lc* descriptors;
    unsigned num_descriptors;
};

struct yage_mem_region g_mem_regions[MAX_MEM_REGIONS];
int g_mem_region_count = 0;
uint8_t* g_io_ptr = NULL;
uint32_t g_io_start = 0;
uint32_t g_io_len = 0;

void handle_set_memory_maps(const void* data) {
    if (!data) return;

    const struct retro_memory_map_lc* mmaps = (const struct retro_memory_map_lc*)data;
    g_mem_region_count = 0;
    g_io_ptr = NULL;
    g_io_start = 0;
    g_io_len = 0;

    for (unsigned i = 0; i < mmaps->num_descriptors && g_mem_region_count < MAX_MEM_REGIONS; i++) {
        const struct retro_memory_descriptor_lc* d = &mmaps->descriptors[i];
        if (!d->ptr || d->len == 0) continue;

        struct yage_mem_region* r = &g_mem_regions[g_mem_region_count++];
        r->ptr   = d->ptr;
        r->start = (uint32_t)d->start;
        r->len   = (uint32_t)d->len;

        if (d->start == 0xFF00 || d->start == 0x04000000) {
            g_io_ptr   = (uint8_t*)d->ptr;
            g_io_start = (uint32_t)d->start;
            g_io_len   = (uint32_t)d->len;
            LOGI("Link cable: I/O region found at 0x%08X, len=%u, ptr=%p",
                 g_io_start, g_io_len, g_io_ptr);
        }
    }
    LOGI("Link cable: stored %d memory regions", g_mem_region_count);
}

typedef void (*retro_log_printf_t)(int level, const char* fmt, ...);
struct retro_log_callback {
    retro_log_printf_t log;
};

void retro_log_printf_bridge(int level, const char* fmt, ...) {
    if (!fmt) return;
    char buf[768];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    const char* lvl = "INFO";
    if (level == 0) lvl = "DEBUG";
    else if (level == 2) lvl = "WARN";
    else if (level >= 3) lvl = "ERROR";
    LOGI("[core:%s] %s", lvl, buf);
}

uint8_t* resolve_address(uint32_t addr) {
    
    if (g_io_ptr && addr >= g_io_start && addr < g_io_start + g_io_len)
        return g_io_ptr + (addr - g_io_start);
    
    for (int i = 0; i < g_mem_region_count; i++) {
        struct yage_mem_region* r = &g_mem_regions[i];
        if (addr >= r->start && addr < r->start + r->len)
            return (uint8_t*)r->ptr + (addr - r->start);
    }
    return NULL;
}
