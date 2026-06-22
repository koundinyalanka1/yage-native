/*
 * YAGE rcheevos Integration — Implementation
 *
 * Bridges the official rcheevos rc_client library to Dart via FFI.
 * Uses a polling-based HTTP bridge and event queue.
 */

#include "yage_rcheevos.h"
#include "yage_internal.h"  /* For YageCore, memory maps, and memory read */
#include "rcheevos/include/rc_client.h"
#include "rcheevos/include/rc_consoles.h"
#include "rcheevos/include/rc_hash.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef __ANDROID__
#include <android/log.h>
#define RC_LOGI(...) __android_log_print(ANDROID_LOG_INFO, "YAGE_RC", __VA_ARGS__)
#define RC_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "YAGE_RC", __VA_ARGS__)
#else
#define RC_LOGI(...) do { printf("[YAGE_RC] "); printf(__VA_ARGS__); printf("\n"); } while(0)
#define RC_LOGE(...) do { printf("[YAGE_RC ERROR] "); printf(__VA_ARGS__); printf("\n"); } while(0)
#endif

/* ═══════════════════════════════════════════════════════════════════════
 *  Global State
 * ═══════════════════════════════════════════════════════════════════════ */

static rc_client_t* g_rc_client = NULL;
static YageCore* g_yage_core = NULL;

/* Cached console memory regions and resolved core memory blocks.
 * rcheevos evaluates a linear console-specific address space. libretro cores
 * expose either a memory map or coarse memory blocks (SYSTEM_RAM/SAVE_RAM/etc).
 * We build a linear table once per loaded game so every supported core can
 * answer rc_client memory reads without hard-coded per-console translation. */
static const rc_memory_regions_t* g_console_memory_regions = NULL;

#define MAX_RC_MEMORY_BLOCKS 64

/* How a linear block resolves to real bytes.
 *
 * CORE blocks are resolved from the LIVE core memory base on every read
 * (retro_get_memory_data + retro_get_memory_size). They must NEVER cache an
 * absolute host pointer: melonDS (and other cores) free / remap their RAM on
 * reset, reload, save-state load or fastmem re-init, which would leave a
 * cached pointer dangling -> use-after-free (the SIGSEGV this path fixes).
 *
 * RAW blocks come from a libretro SET_MEMORY_MAPS descriptor and keep an
 * absolute pointer; those are guarded by the descriptor snapshot below and by
 * resetting the descriptor table on core teardown. */
typedef enum {
    RC_BLOCK_NULL = 0,   /* unmapped / padding                              */
    RC_BLOCK_CORE,       /* resolved live: retro memory type + offset       */
    RC_BLOCK_RAW         /* absolute host pointer (libretro descriptor map) */
} yage_rc_block_kind_t;

typedef struct {
    yage_rc_block_kind_t kind;
    uint32_t size;        /* span within the linear rcheevos address space   */
    uint32_t mem_type;    /* RC_BLOCK_CORE: RETRO_MEMORY_*                    */
    uint32_t mem_offset;  /* RC_BLOCK_CORE: byte offset within that core mem  */
    uint8_t* raw_ptr;     /* RC_BLOCK_RAW: absolute base pointer              */
} yage_rc_memory_block_t;

static yage_rc_memory_block_t g_rc_memory_blocks[MAX_RC_MEMORY_BLOCKS];
static uint32_t g_rc_memory_block_count = 0;
static uint32_t g_rc_memory_total_size = 0;
static uint32_t g_rc_memory_console_id = 0;
static int g_rc_memory_valid = 0;

/* Snapshot of the libretro descriptor pointers the map was built from, so a
 * core swap that changes them forces a rebuild instead of reading freed RAM. */
static void* g_rc_built_desc_ptr[MAX_MEM_REGIONS];
static int   g_rc_built_desc_count = 0;

/* ═══════════════════════════════════════════════════════════════════════
 *  HTTP Request Queue
 *
 *  rc_client calls our server_call function with a request.
 *  We store it here for Dart to pick up and fulfill.
 * ═══════════════════════════════════════════════════════════════════════ */

#define MAX_PENDING_REQUESTS 32

typedef struct {
    int active;                            /* 1 if this slot is in use */
    uint32_t id;                           /* Unique request ID */
    char* url;                             /* URL to request (heap copy) */
    char* post_data;                       /* POST body or NULL (heap copy) */
    char* content_type;                    /* Content-Type or NULL (heap copy) */
    rc_client_server_callback_t callback;  /* rc_client's response handler */
    void* callback_data;                   /* Opaque data for callback */
} pending_request_t;

static pending_request_t g_requests[MAX_PENDING_REQUESTS];
static uint32_t g_next_request_id = 1;

/* ═══════════════════════════════════════════════════════════════════════
 *  Event Queue
 *
 *  rc_client fires events via callback.  We enqueue them here
 *  for Dart to poll.
 * ═══════════════════════════════════════════════════════════════════════ */

#define MAX_PENDING_EVENTS 64

static yage_rc_event_t g_events[MAX_PENDING_EVENTS];
static int g_event_read = 0;
static int g_event_write = 0;

static int event_queue_count(void) {
    return (g_event_write - g_event_read + MAX_PENDING_EVENTS) % MAX_PENDING_EVENTS;
}

static void enqueue_event(const yage_rc_event_t* ev) {
    int next = (g_event_write + 1) % MAX_PENDING_EVENTS;
    if (next == g_event_read) {
        /* Queue full — drop oldest */
        g_event_read = (g_event_read + 1) % MAX_PENDING_EVENTS;
        RC_LOGE("Event queue full — dropping oldest event");
    }
    g_events[g_event_write] = *ev;
    g_event_write = next;
}

static void enqueue_simple_event(uint32_t type) {
    yage_rc_event_t ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = type;
    enqueue_event(&ev);
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Memory Mapping
 * ═══════════════════════════════════════════════════════════════════════ */

static void rc_memory_clear(void) {
    memset(g_rc_memory_blocks, 0, sizeof(g_rc_memory_blocks));
    g_rc_memory_block_count = 0;
    g_rc_memory_total_size = 0;
    g_rc_memory_console_id = 0;
    g_rc_memory_valid = 0;
    g_console_memory_regions = NULL;
    g_rc_built_desc_count = 0;
}

static uint32_t rc_console_region_to_retro_memory_type(uint8_t region_type) {
    switch (region_type) {
        case RC_MEMORY_TYPE_SAVE_RAM:
            return RETRO_MEMORY_SAVE_RAM;
        case RC_MEMORY_TYPE_VIDEO_RAM:
            return RETRO_MEMORY_VIDEO_RAM;
        default:
            return RETRO_MEMORY_SYSTEM_RAM;
    }
}

static void rc_memory_push_block(yage_rc_block_kind_t kind,
                                 uint32_t mem_type,
                                 uint32_t mem_offset,
                                 uint8_t* raw_ptr,
                                 uint32_t size) {
    if (size == 0) return;

    /* Coalesce with the previous block when they are contiguous and of the
     * same kind — keeps the block count low and the read loop short. */
    if (g_rc_memory_block_count > 0) {
        yage_rc_memory_block_t* prev =
            &g_rc_memory_blocks[g_rc_memory_block_count - 1];
        if (prev->kind == kind) {
            int merge = 0;
            if (kind == RC_BLOCK_NULL) {
                merge = 1;
            } else if (kind == RC_BLOCK_CORE) {
                merge = (prev->mem_type == mem_type &&
                         prev->mem_offset + prev->size == mem_offset);
            } else if (kind == RC_BLOCK_RAW) {
                merge = (raw_ptr && prev->raw_ptr &&
                         raw_ptr == prev->raw_ptr + prev->size);
            }
            if (merge) {
                prev->size += size;
                g_rc_memory_total_size += size;
                return;
            }
        }
    }

    if (g_rc_memory_block_count >= MAX_RC_MEMORY_BLOCKS) {
        RC_LOGE("RA memory map has too many blocks; dropping %u bytes", size);
        return;
    }

    yage_rc_memory_block_t* b = &g_rc_memory_blocks[g_rc_memory_block_count++];
    b->kind       = kind;
    b->size       = size;
    b->mem_type   = mem_type;
    b->mem_offset = mem_offset;
    b->raw_ptr    = raw_ptr;
    g_rc_memory_total_size += size;
}

/* Padding: a hole in the linear space with no backing bytes. */
static void rc_memory_register_null(uint32_t size) {
    rc_memory_push_block(RC_BLOCK_NULL, 0, 0, NULL, size);
}

/* Bytes that live in a libretro core memory region (SYSTEM/SAVE/VIDEO RAM).
 * Stored as type + offset and resolved live on every read. */
static void rc_memory_register_core(uint32_t mem_type,
                                    uint32_t mem_offset,
                                    uint32_t size) {
    rc_memory_push_block(RC_BLOCK_CORE, mem_type, mem_offset, NULL, size);
}

/* Bytes addressed by an absolute pointer from a libretro memory descriptor. */
static void rc_memory_register_raw(uint8_t* ptr, uint32_t size) {
    if (!ptr) { rc_memory_register_null(size); return; }
    rc_memory_push_block(RC_BLOCK_RAW, 0, 0, ptr, size);
}

static void get_core_memory_info(uint32_t type,
                                 uint8_t** data,
                                 uint32_t* size) {
    *data = NULL;
    *size = 0;

    YageCore* core = g_yage_core;
    if (!core || !core->retro_get_memory_size || !core->retro_get_memory_data)
        return;

    size_t mem_size = core->retro_get_memory_size((unsigned)type);
    if (mem_size == 0) return;
    if (mem_size > UINT32_MAX) mem_size = UINT32_MAX;

    *data = (uint8_t*)core->retro_get_memory_data((unsigned)type);
    *size = (uint32_t)mem_size;
}

static const struct yage_mem_region* find_core_memory_descriptor(
    uint32_t real_address,
    uint32_t* offset
) {
    for (int i = 0; i < g_mem_region_count; i++) {
        const struct yage_mem_region* desc = &g_mem_regions[i];

        if (desc->select == 0) {
            uint64_t start = desc->start;
            uint64_t end = start + desc->len;
            if ((uint64_t)real_address >= start &&
                (uint64_t)real_address < end) {
                *offset = real_address - desc->start;
                return desc;
            }
        } else if (((desc->start ^ real_address) & desc->select) == 0) {
            uint32_t reduced_address = real_address - desc->start;
            uint32_t disconnect_mask = desc->disconnect;

            while (disconnect_mask) {
                const uint32_t tmp = (disconnect_mask - 1) & ~disconnect_mask;
                reduced_address =
                    (reduced_address & tmp) |
                    ((reduced_address >> 1) & ~tmp);
                disconnect_mask = (disconnect_mask & (disconnect_mask - 1)) >> 1;
            }

            if (reduced_address < desc->len) {
                *offset = reduced_address;
                return desc;
            }
        }
    }

    *offset = 0;
    return NULL;
}

static void rc_memory_init_without_console_regions(void) {
    uint8_t* data;
    uint32_t size;

    get_core_memory_info(RETRO_MEMORY_SYSTEM_RAM, &data, &size);
    if (data && size) rc_memory_register_core(RETRO_MEMORY_SYSTEM_RAM, 0, size);

    get_core_memory_info(RETRO_MEMORY_SAVE_RAM, &data, &size);
    if (data && size) rc_memory_register_core(RETRO_MEMORY_SAVE_RAM, 0, size);
}

static void rc_memory_init_from_core_memory_map(
    const rc_memory_regions_t* console_regions
) {
    for (uint32_t i = 0; i < console_regions->num_regions; i++) {
        const rc_memory_region_t* console_region =
            &console_regions->region[i];
        uint32_t remaining =
            console_region->end_address - console_region->start_address + 1;
        uint32_t real_address = console_region->real_address;

        while (remaining > 0) {
            uint32_t offset = 0;
            const struct yage_mem_region* desc =
                find_core_memory_descriptor(real_address, &offset);
            if (!desc) {
                rc_memory_register_null(remaining);
                break;
            }

            uint8_t* region_start = NULL;
            if (desc->ptr) {
                region_start = (uint8_t*)desc->ptr + desc->offset + offset;
            }

            uint32_t desc_size = desc->len - offset;
            if (desc->disconnect && desc_size > desc->disconnect) {
                uint32_t disconnect_size =
                    desc->disconnect & (uint32_t)(-(int32_t)desc->disconnect);
                desc_size = disconnect_size -
                    (real_address & (disconnect_size - 1));
            }
            if (desc_size == 0) {
                rc_memory_register_null(remaining);
                break;
            }

            uint32_t take = remaining < desc_size ? remaining : desc_size;
            rc_memory_register_raw(region_start, take);
            remaining -= take;
            real_address += take;
        }
    }
}

static void rc_memory_init_from_unmapped_core_memory(
    const rc_memory_regions_t* console_regions
) {
    int found_aligning_padding = 0;

    for (uint32_t i = 0; i < console_regions->num_regions; i++) {
        const rc_memory_region_t* console_region =
            &console_regions->region[i];
        const uint32_t console_size =
            console_region->end_address - console_region->start_address + 1;
        const uint32_t type =
            rc_console_region_to_retro_memory_type(console_region->type);
        uint32_t base_address = 0;
        uint8_t* data = NULL;
        uint32_t size = 0;

        if (console_region->type == RC_MEMORY_TYPE_UNUSED &&
            console_size >= 0x10000 &&
            !found_aligning_padding &&
            console_regions->region[console_regions->num_regions - 1]
                    .end_address > 0x01000000) {
            found_aligning_padding = 1;
        }

        for (uint32_t j = 0; j <= i; j++) {
            const rc_memory_region_t* scan = &console_regions->region[j];
            if (rc_console_region_to_retro_memory_type(scan->type) == type) {
                base_address = scan->start_address;
                break;
            }
        }

        if (!found_aligning_padding) {
            get_core_memory_info(type, &data, &size);
        } else {
            size = console_size;
        }

        const uint32_t offset = console_region->start_address - base_address;
        uint32_t core_offset = 0;
        if (offset < size) {
            core_offset = offset;   /* byte offset within the core memory */
            size -= offset;
        } else {
            data = NULL;
            size = 0;
        }

        /* Bytes actually backed by live core memory; data != NULL only when
         * get_core_memory_info() found a real region above. Anything past it
         * is registered as padding. Resolved live on read, never cached. */
        uint32_t mapped = console_size < size ? console_size : size;
        if (data && mapped) {
            rc_memory_register_core(type, core_offset, mapped);
            if (console_size > mapped)
                rc_memory_register_null(console_size - mapped);
        } else {
            rc_memory_register_null(console_size);
        }
    }
}

static void rc_memory_ensure_for_client(rc_client_t* client) {
    if (!client) return;

    const rc_client_game_t* game = rc_client_get_game_info(client);
    if (!game || game->console_id == 0) return;

    if (g_rc_memory_valid && g_rc_memory_console_id == game->console_id)
        return;

    rc_memory_clear();
    g_rc_memory_console_id = game->console_id;
    g_console_memory_regions = rc_console_memory_regions(game->console_id);

    if (!g_console_memory_regions ||
        g_console_memory_regions->num_regions == 0) {
        rc_memory_init_without_console_regions();
    } else if (g_mem_region_count > 0) {
        rc_memory_init_from_core_memory_map(g_console_memory_regions);
    } else {
        rc_memory_init_from_unmapped_core_memory(g_console_memory_regions);
    }

    for (uint32_t i = 0; i < g_rc_memory_block_count; i++) {
        if (g_rc_memory_blocks[i].kind != RC_BLOCK_NULL) {
            g_rc_memory_valid = 1;
            break;
        }
    }

    /* Remember which libretro descriptor pointers this map was built from, so
     * a later core swap that changes them can be detected and force a rebuild
     * (RAW blocks hold absolute pointers into those descriptors). */
    g_rc_built_desc_count = g_mem_region_count;
    for (int i = 0; i < g_mem_region_count && i < MAX_MEM_REGIONS; i++)
        g_rc_built_desc_ptr[i] = g_mem_regions[i].ptr;

    RC_LOGI("RA memory map: console=%u, blocks=%u, total=%u, valid=%s",
            game->console_id,
            g_rc_memory_block_count,
            g_rc_memory_total_size,
            g_rc_memory_valid ? "yes" : "no");
}

/* True if the libretro descriptor table differs from the snapshot taken when
 * the map was built — i.e. the core was swapped or re-sent its memory map and
 * any cached RAW pointer may now be dangling. */
static int rc_memory_descriptors_changed(void) {
    if (g_mem_region_count != g_rc_built_desc_count) return 1;
    for (int i = 0; i < g_mem_region_count && i < MAX_MEM_REGIONS; i++)
        if (g_mem_regions[i].ptr != g_rc_built_desc_ptr[i]) return 1;
    return 0;
}

static uint32_t rc_memory_read_linear(uint32_t address,
                                      uint8_t* buffer,
                                      uint32_t num_bytes) {
    uint32_t bytes_read = 0;

    for (uint32_t i = 0; i < g_rc_memory_block_count && num_bytes > 0; i++) {
        yage_rc_memory_block_t* block = &g_rc_memory_blocks[i];

        if (address >= block->size) {
            address -= block->size;
            continue;
        }

        /* Padding (or anything we can't resolve) ends the contiguous run:
         * stop and let the caller fall back to the unmapped reader. */
        if (block->kind == RC_BLOCK_NULL) break;

        const uint32_t block_remaining = block->size - address;
        uint32_t avail = block_remaining;
        uint8_t* src;

        if (block->kind == RC_BLOCK_CORE) {
            /* Resolve from the LIVE core memory every read. If the core freed
             * or remapped this RAM (reset / reload / fastmem) we get the new
             * base (or NULL) here instead of dereferencing a stale pointer. */
            uint8_t* base = NULL;
            uint32_t live_size = 0;
            get_core_memory_info(block->mem_type, &base, &live_size);
            if (!base) break;

            const uint64_t start = (uint64_t)block->mem_offset + address;
            if (start >= live_size) break;          /* outside live memory */

            const uint32_t live_avail = live_size - (uint32_t)start;
            if (live_avail < avail) avail = live_avail;  /* clamp to live size */
            src = base + (uint32_t)start;
        } else { /* RC_BLOCK_RAW */
            if (!block->raw_ptr) break;
            src = block->raw_ptr + address;
        }

        const uint32_t take = avail < num_bytes ? avail : num_bytes;
        if (take == 0) break;
        memcpy(buffer, src, take);

        bytes_read += take;
        buffer     += take;
        num_bytes  -= take;

        /* Short read of this block (a clamp/hole) — the next block is no
         * longer contiguous with the request, so stop here. */
        if (take < block_remaining) break;
        address = 0;
    }

    return bytes_read;
}

static uint32_t rc_memory_read_core_block(uint32_t type,
                                          uint32_t offset,
                                          uint8_t* buffer,
                                          uint32_t num_bytes) {
    uint8_t* data = NULL;
    uint32_t size = 0;

    get_core_memory_info(type, &data, &size);
    if (!data || offset >= size) return 0;

    uint32_t avail = size - offset;
    uint32_t take = avail < num_bytes ? avail : num_bytes;
    memcpy(buffer, data + offset, take);
    return take;
}

static uint32_t rc_memory_read_unmapped_linear(uint32_t address,
                                               uint8_t* buffer,
                                               uint32_t num_bytes) {
    const rc_memory_regions_t* console_regions = g_console_memory_regions;
    uint32_t bytes_read = 0;

    if (!console_regions || console_regions->num_regions == 0) {
        uint8_t* data;
        uint32_t size;

        get_core_memory_info(RETRO_MEMORY_SYSTEM_RAM, &data, &size);
        if (address < size && data) {
            uint32_t take = (size - address) < num_bytes
                ? (size - address)
                : num_bytes;
            memcpy(buffer, data + address, take);
            bytes_read += take;
            buffer += take;
            num_bytes -= take;
            address = 0;
        } else if (address >= size) {
            address -= size;
        } else {
            return bytes_read;
        }

        if (num_bytes == 0) return bytes_read;

        get_core_memory_info(RETRO_MEMORY_SAVE_RAM, &data, &size);
        if (address < size && data) {
            uint32_t take = (size - address) < num_bytes
                ? (size - address)
                : num_bytes;
            memcpy(buffer, data + address, take);
            bytes_read += take;
        }
        return bytes_read;
    }

    while (num_bytes > 0) {
        const rc_memory_region_t* region = NULL;
        uint32_t region_index = 0;

        for (uint32_t i = 0; i < console_regions->num_regions; i++) {
            const rc_memory_region_t* candidate = &console_regions->region[i];
            if (address >= candidate->start_address &&
                address <= candidate->end_address) {
                region = candidate;
                region_index = i;
                break;
            }
        }

        if (!region || region->type == RC_MEMORY_TYPE_UNUSED) break;

        const uint32_t type =
            rc_console_region_to_retro_memory_type(region->type);
        uint32_t base_address = 0;
        for (uint32_t i = 0; i <= region_index; i++) {
            const rc_memory_region_t* scan = &console_regions->region[i];
            if (rc_console_region_to_retro_memory_type(scan->type) == type) {
                base_address = scan->start_address;
                break;
            }
        }

        const uint32_t region_offset = address - region->start_address;
        const uint32_t core_offset =
            (region->start_address - base_address) + region_offset;
        uint32_t remaining_in_region =
            region->end_address - address + 1;
        uint32_t wanted =
            remaining_in_region < num_bytes ? remaining_in_region : num_bytes;
        uint32_t read = rc_memory_read_core_block(
            type,
            core_offset,
            buffer,
            wanted
        );
        if (read == 0) break;

        bytes_read += read;
        buffer += read;
        num_bytes -= read;
        address += read;

        if (read < wanted) break;
    }

    return bytes_read;
}

/* ═══════════════════════════════════════════════════════════════════════
 *  rc_client Callbacks
 * ═══════════════════════════════════════════════════════════════════════ */

/**
 * Memory reader callback for rc_client.
 *
 * rc_client reads the linear rcheevos address space. Build a per-game view
 * from libretro memory descriptors so all cores can use the same path.
 */
static uint32_t RC_CCONV memory_reader(uint32_t address, uint8_t* buffer,
                                        uint32_t num_bytes, rc_client_t* client) {
    /* Snapshot globals into locals so a concurrent yage_rc_destroy /
     * yage_rc_unload_game on the Dart thread cannot NULL them mid-read.
     * The core pointer remains valid because the frame loop (our caller)
     * is joined before the core is freed. */
    YageCore* core = g_yage_core;
    if (!core || !buffer || num_bytes == 0) return 0;

    /* If the libretro descriptor table changed under us (core swapped, or it
     * re-sent its memory map), drop the cached view so it is rebuilt against
     * the current core instead of reading through freed RAW pointers. */
    if (g_rc_memory_valid && rc_memory_descriptors_changed()) {
        g_rc_memory_valid = 0;
        g_rc_memory_console_id = 0;
    }

    rc_memory_ensure_for_client(client);
    if (g_rc_memory_valid) {
        uint32_t result = rc_memory_read_linear(address, buffer, num_bytes);
        if (result == num_bytes) return result;

        uint32_t fallback = rc_memory_read_unmapped_linear(
            address,
            buffer,
            num_bytes
        );
        if (fallback > result) return fallback;
        return result;
    }

    uint32_t fallback = rc_memory_read_unmapped_linear(
        address,
        buffer,
        num_bytes
    );
    if (fallback > 0) return fallback;

    int result = yage_core_read_memory(core, address, (int32_t)num_bytes, buffer);
    return (result > 0) ? (uint32_t)result : 0;
}

/**
 * Server call callback for rc_client.
 *
 * Called when rc_client needs to make an HTTP request.
 * We store the request for Dart to pick up and fulfill.
 */
static void RC_CCONV server_call(const rc_api_request_t* request,
                                  rc_client_server_callback_t callback,
                                  void* callback_data,
                                  rc_client_t* client) {
    (void)client;

    /* Find a free slot */
    int slot = -1;
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (!g_requests[i].active) {
            slot = i;
            break;
        }
    }

    if (slot < 0) {
        RC_LOGE("HTTP request queue full — dropping request!");
        /* Send an error response back to rc_client */
        rc_api_server_response_t response;
        memset(&response, 0, sizeof(response));
        response.http_status_code = RC_API_SERVER_RESPONSE_CLIENT_ERROR;
        callback(&response, callback_data);
        return;
    }

    pending_request_t* req = &g_requests[slot];
    req->active = 1;
    req->id = g_next_request_id++;
    req->url = request->url ? strdup(request->url) : NULL;
    req->post_data = request->post_data ? strdup(request->post_data) : NULL;
    req->content_type = request->content_type ? strdup(request->content_type) : NULL;
    req->callback = callback;
    req->callback_data = callback_data;

    RC_LOGI("HTTP request queued: id=%u, url=%s", req->id,
            req->url ? req->url : "(null)");
}

/**
 * Event handler callback for rc_client.
 *
 * Called when achievements are triggered, leaderboards change, etc.
 */
static void RC_CCONV event_handler(const rc_client_event_t* event,
                                    rc_client_t* client) {
    (void)client;
    if (!event) return;

    yage_rc_event_t ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = event->type;

    /* Copy achievement data if present */
    if (event->achievement) {
        ev.achievement_id = event->achievement->id;
        ev.achievement_points = event->achievement->points;
        ev.achievement_rarity = event->achievement->rarity;
        ev.achievement_rarity_hardcore = event->achievement->rarity_hardcore;
        ev.achievement_type = event->achievement->type;

        if (event->achievement->title) {
            strncpy(ev.achievement_title, event->achievement->title,
                    sizeof(ev.achievement_title) - 1);
        }
        if (event->achievement->description) {
            strncpy(ev.achievement_description, event->achievement->description,
                    sizeof(ev.achievement_description) - 1);
        }
        if (event->achievement->badge_url) {
            strncpy(ev.achievement_badge_url, event->achievement->badge_url,
                    sizeof(ev.achievement_badge_url) - 1);
        }
    }

    /* Copy server error data if present */
    if (event->server_error) {
        ev.error_code = event->server_error->result;
        if (event->server_error->error_message) {
            strncpy(ev.error_message, event->server_error->error_message,
                    sizeof(ev.error_message) - 1);
        }
    }

    switch (event->type) {
        case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED:
            RC_LOGI("Achievement triggered: \"%s\" (%u pts)",
                    ev.achievement_title, ev.achievement_points);
            enqueue_event(&ev);
            break;
        case RC_CLIENT_EVENT_GAME_COMPLETED:
            RC_LOGI("Game completed!");
            enqueue_event(&ev);
            break;
        case RC_CLIENT_EVENT_SERVER_ERROR:
            RC_LOGE("Server error: %s", ev.error_message);
            enqueue_event(&ev);
            break;
        case RC_CLIENT_EVENT_DISCONNECTED:
            RC_LOGI("Disconnected from server");
            enqueue_event(&ev);
            break;
        case RC_CLIENT_EVENT_RECONNECTED:
            RC_LOGI("Reconnected to server");
            enqueue_event(&ev);
            break;
        case RC_CLIENT_EVENT_SUBSET_COMPLETED:
            RC_LOGI("Subset completed!");
            enqueue_event(&ev);
            break;

        /* ── Events we intentionally do NOT forward to Dart ──
         * Challenge / progress indicators carry achievement data for
         * UNEARNED achievements.  Forwarding them caused spurious
         * "achievement unlocked" toasts on GB/GBC games. */
        case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_SHOW:
        case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_HIDE:
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_SHOW:
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_HIDE:
        case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_UPDATE:
        case RC_CLIENT_EVENT_LEADERBOARD_STARTED:
        case RC_CLIENT_EVENT_LEADERBOARD_FAILED:
        case RC_CLIENT_EVENT_LEADERBOARD_SUBMITTED:
        case RC_CLIENT_EVENT_LEADERBOARD_TRACKER_SHOW:
        case RC_CLIENT_EVENT_LEADERBOARD_TRACKER_HIDE:
        case RC_CLIENT_EVENT_LEADERBOARD_TRACKER_UPDATE:
        case RC_CLIENT_EVENT_LEADERBOARD_SCOREBOARD:
        case RC_CLIENT_EVENT_RESET:
            RC_LOGI("Event (not forwarded): type=%u", event->type);
            break;

        default:
            RC_LOGI("Unknown event: type=%u", event->type);
            break;
    }
}

/**
 * Log message callback for rc_client.
 */
static void RC_CCONV log_message(const char* message, const rc_client_t* client) {
    (void)client;
    RC_LOGI("rc_client: %s", message ? message : "(null)");
}

static void RC_CCONV hash_verbose_message(const char* message,
                                           const rc_hash_iterator_t* iterator) {
    (void)iterator;
    if (message) RC_LOGI("rc_hash: %s", message);
}

static void RC_CCONV hash_error_message(const char* message,
                                         const rc_hash_iterator_t* iterator) {
    (void)iterator;
    if (message) RC_LOGE("rc_hash: %s", message);
}

/**
 * Login completion callback.
 */
static void RC_CCONV login_callback(int result, const char* error_message,
                                     rc_client_t* client, void* userdata) {
    (void)client;
    (void)userdata;

    if (result == RC_OK) {
        const rc_client_user_t* user = rc_client_get_user_info(g_rc_client);
        RC_LOGI("Login successful: %s", user ? user->display_name : "unknown");
        enqueue_simple_event(YAGE_RC_EVENT_LOGIN_SUCCESS);
    } else {
        RC_LOGE("Login failed: %s (code %d)",
                error_message ? error_message : "unknown", result);
        yage_rc_event_t ev;
        memset(&ev, 0, sizeof(ev));
        ev.type = YAGE_RC_EVENT_LOGIN_FAILED;
        ev.error_code = result;
        if (error_message) {
            strncpy(ev.error_message, error_message, sizeof(ev.error_message) - 1);
        }
        enqueue_event(&ev);
    }
}

/**
 * Game load completion callback.
 */
static void RC_CCONV load_game_callback(int result, const char* error_message,
                                          rc_client_t* client, void* userdata) {
    (void)client;
    (void)userdata;

    if (result == RC_OK) {
        const rc_client_game_t* game = rc_client_get_game_info(g_rc_client);
        RC_LOGI("Game loaded: \"%s\" (ID=%u, console=%u)",
                game ? game->title : "unknown",
                game ? game->id : 0,
                game ? game->console_id : 0);

        rc_memory_ensure_for_client(g_rc_client);

        enqueue_simple_event(YAGE_RC_EVENT_GAME_LOAD_SUCCESS);
    } else {
        RC_LOGE("Game load failed: %s (code %d)",
                error_message ? error_message : "unknown", result);
        yage_rc_event_t ev;
        memset(&ev, 0, sizeof(ev));
        ev.type = YAGE_RC_EVENT_GAME_LOAD_FAILED;
        ev.error_code = result;
        if (error_message) {
            strncpy(ev.error_message, error_message, sizeof(ev.error_message) - 1);
        }
        enqueue_event(&ev);
    }
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — Lifecycle
 * ═══════════════════════════════════════════════════════════════════════ */

int yage_rc_init(void* yage_core) {
    if (g_rc_client) {
        RC_LOGI("rc_client already initialized — destroying first");
        yage_rc_destroy();
    }

    g_yage_core = (YageCore*)yage_core;

    /* Clear queues */
    memset(g_requests, 0, sizeof(g_requests));
    g_next_request_id = 1;
    g_event_read = 0;
    g_event_write = 0;

    /* Create rc_client with our memory reader and server call handler */
    g_rc_client = rc_client_create(memory_reader, server_call);
    if (!g_rc_client) {
        RC_LOGE("Failed to create rc_client");
        return -1;
    }

    /* Set up event handler */
    rc_client_set_event_handler(g_rc_client, event_handler);

    /* Enable logging */
    rc_client_enable_logging(g_rc_client, RC_CLIENT_LOG_LEVEL_INFO, log_message);

    RC_LOGI("rc_client initialized (core=%p)", yage_core);
    return 0;
}

void yage_rc_destroy(void) {
    if (g_rc_client) {
        rc_client_destroy(g_rc_client);
        g_rc_client = NULL;
    }
    g_yage_core = NULL;
    rc_memory_clear();

    /* Free any pending request strings */
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (g_requests[i].active) {
            free(g_requests[i].url);
            free(g_requests[i].post_data);
            free(g_requests[i].content_type);
        }
    }
    memset(g_requests, 0, sizeof(g_requests));

    RC_LOGI("rc_client destroyed");
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — Configuration
 * ═══════════════════════════════════════════════════════════════════════ */

void yage_rc_set_hardcore(int enabled) {
    if (!g_rc_client) return;
    rc_client_set_hardcore_enabled(g_rc_client, enabled);
    RC_LOGI("Hardcore mode: %s", enabled ? "ON" : "OFF");
}

void yage_rc_set_encore(int enabled) {
    if (!g_rc_client) return;
    rc_client_set_encore_mode_enabled(g_rc_client, enabled);
    RC_LOGI("Encore mode: %s", enabled ? "ON" : "OFF");
}

int yage_rc_get_user_agent_clause(char* buffer, int buffer_size) {
    if (!g_rc_client || !buffer || buffer_size <= 0) return 0;
    return (int)rc_client_get_user_agent_clause(g_rc_client, buffer, (size_t)buffer_size);
}

int yage_rc_hash_file(uint32_t console_id,
                      const char* path,
                      char* out_hash,
                      int out_hash_size) {
    char hash[33];
    rc_hash_iterator_t iterator;
    int result;

    if (!path || !out_hash || out_hash_size < 33) return 0;

    memset(hash, 0, sizeof(hash));
    rc_hash_initialize_iterator(&iterator, path, NULL, 0);
    iterator.callbacks.verbose_message = hash_verbose_message;
    iterator.callbacks.error_message = hash_error_message;

    result = rc_hash_generate(hash, console_id, &iterator);
    rc_hash_destroy_iterator(&iterator);

    if (!result) {
        out_hash[0] = '\0';
        return 0;
    }

    memcpy(out_hash, hash, sizeof(hash));
    return 1;
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — User / Session
 * ═══════════════════════════════════════════════════════════════════════ */

void yage_rc_begin_login(const char* username, const char* token) {
    if (!g_rc_client || !username || !token) return;
    RC_LOGI("Beginning login for user: %s", username);
    rc_client_begin_login_with_token(g_rc_client, username, token,
                                      login_callback, NULL);
}

int yage_rc_is_logged_in(void) {
    if (!g_rc_client) return 0;
    return rc_client_get_user_info(g_rc_client) != NULL ? 1 : 0;
}

const char* yage_rc_get_user_display_name(void) {
    if (!g_rc_client) return NULL;
    const rc_client_user_t* user = rc_client_get_user_info(g_rc_client);
    return user ? user->display_name : NULL;
}

void yage_rc_logout(void) {
    if (!g_rc_client) return;
    rc_client_logout(g_rc_client);
    RC_LOGI("User logged out");
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — Game
 * ═══════════════════════════════════════════════════════════════════════ */

void yage_rc_begin_load_game(const char* hash) {
    if (!g_rc_client || !hash) return;
    RC_LOGI("Beginning game load for hash: %s", hash);
    rc_memory_clear();
    rc_client_begin_load_game(g_rc_client, hash, load_game_callback, NULL);
}

int yage_rc_is_game_loaded(void) {
    if (!g_rc_client) return 0;
    return rc_client_is_game_loaded(g_rc_client);
}

const char* yage_rc_get_game_title(void) {
    if (!g_rc_client) return NULL;
    const rc_client_game_t* game = rc_client_get_game_info(g_rc_client);
    return game ? game->title : NULL;
}

uint32_t yage_rc_get_game_id(void) {
    if (!g_rc_client) return 0;
    const rc_client_game_t* game = rc_client_get_game_info(g_rc_client);
    return game ? game->id : 0;
}

const char* yage_rc_get_game_badge_url(void) {
    if (!g_rc_client) return NULL;
    const rc_client_game_t* game = rc_client_get_game_info(g_rc_client);
    return game ? game->badge_url : NULL;
}

void yage_rc_unload_game(void) {
    if (!g_rc_client) return;
    rc_client_unload_game(g_rc_client);
    rc_memory_clear();
    RC_LOGI("Game unloaded");
}

void yage_rc_reset(void) {
    if (!g_rc_client) return;
    rc_client_reset(g_rc_client);
    /* A reset can re-init the core and remap its RAM; drop the cached memory
     * map so it is rebuilt against the new buffers on the next read. */
    rc_memory_clear();
    RC_LOGI("Runtime reset");
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — Frame Processing
 * ═══════════════════════════════════════════════════════════════════════ */

void yage_rc_do_frame(void) {
    if (!g_rc_client) return;
    rc_client_do_frame(g_rc_client);
}

void yage_rc_idle(void) {
    if (!g_rc_client) return;
    rc_client_idle(g_rc_client);
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — Achievement Info
 * ═══════════════════════════════════════════════════════════════════════ */

uint32_t yage_rc_get_achievement_count(void) {
    if (!g_rc_client) return 0;
    rc_client_user_game_summary_t summary;
    memset(&summary, 0, sizeof(summary));
    rc_client_get_user_game_summary(g_rc_client, &summary);
    return summary.num_core_achievements;
}

uint32_t yage_rc_get_unlocked_count(void) {
    if (!g_rc_client) return 0;
    rc_client_user_game_summary_t summary;
    memset(&summary, 0, sizeof(summary));
    rc_client_get_user_game_summary(g_rc_client, &summary);
    return summary.num_unlocked_achievements;
}

uint32_t yage_rc_get_total_points(void) {
    if (!g_rc_client) return 0;
    rc_client_user_game_summary_t summary;
    memset(&summary, 0, sizeof(summary));
    rc_client_get_user_game_summary(g_rc_client, &summary);
    return summary.points_core;
}

uint32_t yage_rc_get_unlocked_points(void) {
    if (!g_rc_client) return 0;
    rc_client_user_game_summary_t summary;
    memset(&summary, 0, sizeof(summary));
    rc_client_get_user_game_summary(g_rc_client, &summary);
    return summary.points_unlocked;
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — HTTP Bridge
 * ═══════════════════════════════════════════════════════════════════════ */

uint32_t yage_rc_get_pending_request(void) {
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (g_requests[i].active) {
            return g_requests[i].id;
        }
    }
    return 0;
}

const char* yage_rc_get_request_url(uint32_t request_id) {
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (g_requests[i].active && g_requests[i].id == request_id) {
            return g_requests[i].url;
        }
    }
    return NULL;
}

const char* yage_rc_get_request_post_data(uint32_t request_id) {
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (g_requests[i].active && g_requests[i].id == request_id) {
            return g_requests[i].post_data;
        }
    }
    return NULL;
}

const char* yage_rc_get_request_content_type(uint32_t request_id) {
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (g_requests[i].active && g_requests[i].id == request_id) {
            return g_requests[i].content_type;
        }
    }
    return NULL;
}

void yage_rc_submit_response(uint32_t request_id,
                              const char* body,
                              uint32_t body_length,
                              int http_status) {
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (g_requests[i].active && g_requests[i].id == request_id) {
            pending_request_t* req = &g_requests[i];

            RC_LOGI("HTTP response: id=%u, status=%d, len=%u",
                    request_id, http_status, body_length);

            /* Build the server response */
            rc_api_server_response_t response;
            memset(&response, 0, sizeof(response));
            response.body = body;
            response.body_length = (size_t)body_length;
            response.http_status_code = http_status;

            /* Call rc_client's callback with the response */
            rc_client_server_callback_t cb = req->callback;
            void* cb_data = req->callback_data;

            /* Free the request slot BEFORE calling the callback,
             * because the callback may trigger new requests */
            free(req->url);
            free(req->post_data);
            free(req->content_type);
            memset(req, 0, sizeof(pending_request_t));

            /* Deliver the response */
            cb(&response, cb_data);
            return;
        }
    }

    RC_LOGE("HTTP response for unknown request id=%u", request_id);
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — Event Bridge
 * ═══════════════════════════════════════════════════════════════════════ */

int yage_rc_has_pending_event(void) {
    return g_event_read != g_event_write ? 1 : 0;
}

int yage_rc_get_pending_event(yage_rc_event_t* out_event) {
    if (!out_event || g_event_read == g_event_write) return 0;
    *out_event = g_events[g_event_read];
    return 1;
}

void yage_rc_consume_event(void) {
    if (g_event_read != g_event_write) {
        g_event_read = (g_event_read + 1) % MAX_PENDING_EVENTS;
    }
}

/* ═══════════════════════════════════════════════════════════════════════
 *  Public API — State
 * ═══════════════════════════════════════════════════════════════════════ */

int yage_rc_get_load_game_state(void) {
    if (!g_rc_client) return 0;
    return rc_client_get_load_game_state(g_rc_client);
}

int yage_rc_is_processing_required(void) {
    if (!g_rc_client) return 0;
    return rc_client_is_processing_required(g_rc_client);
}

int yage_rc_get_hardcore_enabled(void) {
    if (!g_rc_client) return 0;
    return rc_client_get_hardcore_enabled(g_rc_client);
}
