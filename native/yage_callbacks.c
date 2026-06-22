/*
 * YAGE Libretro Callbacks Module
 * 
 * Handles libretro environment callbacks, memory mapping, and logging.
 * Implements the core libretro API contract for environment negotiation.
 */

#include "yage_internal.h"

/* ──────────────────────────────────────────────────────────────────
 * Memory Map + Link Cable Support
 * ────────────────────────────────────────────────────────────────── */

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
        r->ptr        = d->ptr;
        r->offset     = (uint32_t)d->offset;
        r->start      = (uint32_t)d->start;
        r->select     = (uint32_t)d->select;
        r->disconnect = (uint32_t)d->disconnect;
        r->len        = (uint32_t)d->len;

        if (d->start == 0xFF00 || d->start == 0x04000000) {
            g_io_ptr   = (uint8_t*)d->ptr + (uint32_t)d->offset;
            g_io_start = (uint32_t)d->start;
            g_io_len   = (uint32_t)d->len;
            LOGI("Link cable: I/O region found at 0x%08X, len=%u, ptr=%p",
                 g_io_start, g_io_len, g_io_ptr);
        }
    }
    LOGI("Link cable: stored %d memory regions", g_mem_region_count);
}

/* ──────────────────────────────────────────────────────────────────
 * Libretro Logging
 * ────────────────────────────────────────────────────────────────── */

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

/* ──────────────────────────────────────────────────────────────────
 * Address resolution (used by link-cable + memory-read API)
 * ────────────────────────────────────────────────────────────────── */

static uint8_t* resolve_descriptor_address(const struct yage_mem_region* r,
                                           uint32_t addr) {
    uint32_t reduced_address;

    if (!r || !r->ptr || r->len == 0) return NULL;

    if (r->select == 0) {
        uint64_t start = r->start;
        uint64_t end = start + r->len;
        if ((uint64_t)addr < start || (uint64_t)addr >= end) return NULL;
        reduced_address = addr - r->start;
    } else {
        if (((r->start ^ addr) & r->select) != 0) return NULL;

        reduced_address = addr - r->start;
        uint32_t disconnect_mask = r->disconnect;
        while (disconnect_mask) {
            const uint32_t tmp = (disconnect_mask - 1) & ~disconnect_mask;
            reduced_address =
                (reduced_address & tmp) | ((reduced_address >> 1) & ~tmp);
            disconnect_mask = (disconnect_mask & (disconnect_mask - 1)) >> 1;
        }

        if (reduced_address >= r->len) return NULL;
    }

    return (uint8_t*)r->ptr + r->offset + reduced_address;
}

uint8_t* resolve_address(uint32_t addr) {
    for (int i = 0; i < g_mem_region_count; i++) {
        struct yage_mem_region* r = &g_mem_regions[i];
        uint8_t* p = resolve_descriptor_address(r, addr);
        if (p) return p;
    }
    return NULL;
}
