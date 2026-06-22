/*
 * YAGE rcheevos Integration
 *
 * Thin C wrapper around the official rcheevos rc_client library.
 * Exposes a polling-based API that Dart can drive via FFI:
 *
 *   ┌──────────┐   FFI    ┌───────────────┐   callbacks   ┌───────────┐
 *   │  Dart    │ ◄──────► │ yage_rcheevos │ ◄───────────► │ rc_client │
 *   │  Service │          │   (C wrapper) │               │ (rcheevos)│
 *   └──────────┘          └───────────────┘               └───────────┘
 *
 * HTTP Bridge:
 *   rc_client makes HTTP requests via a callback.  The wrapper queues
 *   them and Dart polls with yage_rc_get_pending_request(), makes the
 *   HTTP call, and delivers the response via yage_rc_submit_response().
 *
 * Event Bridge:
 *   rc_client fires events (achievement triggered, etc.) via a callback.
 *   The wrapper queues them and Dart polls with yage_rc_get_pending_event().
 */

#ifndef YAGE_RCHEEVOS_H
#define YAGE_RCHEEVOS_H

#include <stdint.h>
#include <stddef.h>

#ifdef _WIN32
    #ifdef YAGE_EXPORTS
        #define YAGE_API __declspec(dllexport)
    #else
        #define YAGE_API __declspec(dllimport)
    #endif
#else
    #define YAGE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ═══════════════════════════════════════════════════════════════════════
 *  Lifecycle
 * ═══════════════════════════════════════════════════════════════════════ */

/**
 * Initialize the rcheevos rc_client.
 *
 * Must be called once before any other yage_rc_* function.
 * The YageCore pointer is stored for memory reads.
 * Returns 0 on success, non-zero on failure.
 */
YAGE_API int yage_rc_init(void* yage_core);

/**
 * Destroy the rc_client and free all resources.
 */
YAGE_API void yage_rc_destroy(void);

/* ═══════════════════════════════════════════════════════════════════════
 *  Configuration
 * ═══════════════════════════════════════════════════════════════════════ */

/** Enable/disable hardcore mode. Must be called before load_game. */
YAGE_API void yage_rc_set_hardcore(int enabled);

/** Enable/disable encore mode (re-earn previously unlocked achievements). */
YAGE_API void yage_rc_set_encore(int enabled);

/** Get the rcheevos user-agent clause (e.g. "rcheevos/12.0"). */
YAGE_API int yage_rc_get_user_agent_clause(char* buffer, int buffer_size);

/**
 * Generate an official rcheevos hash for a file and console.
 *
 * `out_hash` must have room for at least 33 bytes. Returns 1 on success and
 * writes a lowercase 32-character MD5 string plus NUL terminator; returns 0 on
 * failure.
 */
YAGE_API int yage_rc_hash_file(uint32_t console_id,
                               const char* path,
                               char* out_hash,
                               int out_hash_size);

/* ═══════════════════════════════════════════════════════════════════════
 *  User / Session
 * ═══════════════════════════════════════════════════════════════════════ */

/**
 * Begin login with username + connect token (non-blocking).
 *
 * The login proceeds asynchronously via the HTTP bridge:
 *   1. This call queues an HTTP request.
 *   2. Dart polls and fulfills it.
 *   3. The login callback fires and the user is logged in.
 *
 * Use yage_rc_is_logged_in() to check when login is complete.
 */
YAGE_API void yage_rc_begin_login(const char* username, const char* token);

/** Check if a user is currently logged in. */
YAGE_API int yage_rc_is_logged_in(void);

/** Get the logged-in user's display name. NULL if not logged in. */
YAGE_API const char* yage_rc_get_user_display_name(void);

/** Logout the current user. */
YAGE_API void yage_rc_logout(void);

/* ═══════════════════════════════════════════════════════════════════════
 *  Game
 * ═══════════════════════════════════════════════════════════════════════ */

/**
 * Begin loading a game by its MD5 hash (non-blocking).
 *
 * This resolves the game, fetches achievement data, and starts a session.
 * Progress happens asynchronously via the HTTP bridge.
 *
 * Use yage_rc_is_game_loaded() to check when loading is complete.
 */
YAGE_API void yage_rc_begin_load_game(const char* hash);

/** Check if a game is currently loaded and ready. */
YAGE_API int yage_rc_is_game_loaded(void);

/** Get the current game's title. NULL if no game loaded. */
YAGE_API const char* yage_rc_get_game_title(void);

/** Get the current game's numeric ID. 0 if no game loaded. */
YAGE_API uint32_t yage_rc_get_game_id(void);

/** Get the current game's badge/image URL. NULL if no game loaded. */
YAGE_API const char* yage_rc_get_game_badge_url(void);

/** Unload the current game. */
YAGE_API void yage_rc_unload_game(void);

/** Reset the runtime (call when emulated system is reset). */
YAGE_API void yage_rc_reset(void);

/* ═══════════════════════════════════════════════════════════════════════
 *  Frame Processing
 * ═══════════════════════════════════════════════════════════════════════ */

/**
 * Process one frame of achievement evaluation.
 *
 * Call this once per emulated frame. It reads memory, evaluates
 * conditions, and fires events for unlocks. Very fast — safe to
 * call from the frame loop.
 */
YAGE_API void yage_rc_do_frame(void);

/**
 * Process the periodic queue (pings, retries, etc.).
 *
 * Call this when emulation is paused — it handles keepalive pings
 * and retry logic without requiring frame processing.
 */
YAGE_API void yage_rc_idle(void);

/* ═══════════════════════════════════════════════════════════════════════
 *  Achievement Info
 * ═══════════════════════════════════════════════════════════════════════ */

/** Get the number of core achievements for the loaded game. */
YAGE_API uint32_t yage_rc_get_achievement_count(void);

/** Get the number of unlocked achievements. */
YAGE_API uint32_t yage_rc_get_unlocked_count(void);

/** Get total points for the loaded game. */
YAGE_API uint32_t yage_rc_get_total_points(void);

/** Get unlocked points. */
YAGE_API uint32_t yage_rc_get_unlocked_points(void);

/* ═══════════════════════════════════════════════════════════════════════
 *  HTTP Bridge (Dart ↔ C)
 *
 *  rc_client issues HTTP requests via a callback. We queue them here
 *  and Dart polls + fulfills them asynchronously.
 * ═══════════════════════════════════════════════════════════════════════ */

/**
 * Check if there's a pending HTTP request from rc_client.
 * Returns the request ID (> 0) if one is pending, 0 if none.
 */
YAGE_API uint32_t yage_rc_get_pending_request(void);

/**
 * Get the URL for a pending request.
 * Returns NULL if the request ID is invalid.
 */
YAGE_API const char* yage_rc_get_request_url(uint32_t request_id);

/**
 * Get the POST data for a pending request.
 * Returns NULL if no POST data (use GET) or invalid request ID.
 */
YAGE_API const char* yage_rc_get_request_post_data(uint32_t request_id);

/**
 * Get the Content-Type for a pending request.
 * Returns NULL if not set or invalid request ID.
 */
YAGE_API const char* yage_rc_get_request_content_type(uint32_t request_id);

/**
 * Submit the HTTP response for a pending request.
 *
 * Dart calls this after making the HTTP request. The response is
 * delivered to rc_client's stored callback.
 *
 * body:           Response body (can be NULL on error).
 * body_length:    Length of the response body.
 * http_status:    HTTP status code (200, 404, etc.).
 *                 Use -1 for network errors.
 * request_id:     The request ID from yage_rc_get_pending_request().
 */
YAGE_API void yage_rc_submit_response(uint32_t request_id,
                                       const char* body,
                                       uint32_t body_length,
                                       int http_status);

/* ═══════════════════════════════════════════════════════════════════════
 *  Event Bridge (C → Dart)
 *
 *  rc_client fires events via a callback.  We queue them here and
 *  Dart polls to consume them.
 * ═══════════════════════════════════════════════════════════════════════ */

/* Event types (mirrors RC_CLIENT_EVENT_* from rc_client.h) */
#define YAGE_RC_EVENT_NONE                     0
#define YAGE_RC_EVENT_ACHIEVEMENT_TRIGGERED     1
#define YAGE_RC_EVENT_LBOARD_STARTED            2
#define YAGE_RC_EVENT_LBOARD_FAILED             3
#define YAGE_RC_EVENT_LBOARD_SUBMITTED          4
#define YAGE_RC_EVENT_CHALLENGE_INDICATOR_SHOW  5
#define YAGE_RC_EVENT_CHALLENGE_INDICATOR_HIDE  6
#define YAGE_RC_EVENT_PROGRESS_INDICATOR_SHOW   7
#define YAGE_RC_EVENT_PROGRESS_INDICATOR_HIDE   8
#define YAGE_RC_EVENT_GAME_COMPLETED           15
#define YAGE_RC_EVENT_SERVER_ERROR             16
#define YAGE_RC_EVENT_DISCONNECTED             17
#define YAGE_RC_EVENT_RECONNECTED              18

/* Login/load status events (custom, not from rc_client) */
#define YAGE_RC_EVENT_LOGIN_SUCCESS           100
#define YAGE_RC_EVENT_LOGIN_FAILED            101
#define YAGE_RC_EVENT_GAME_LOAD_SUCCESS       102
#define YAGE_RC_EVENT_GAME_LOAD_FAILED        103

/**
 * Packed event data returned to Dart.
 * Contains all fields needed to display notifications.
 */
typedef struct yage_rc_event_t {
    uint32_t type;
    uint32_t achievement_id;
    uint32_t achievement_points;
    char     achievement_title[256];
    char     achievement_description[256];
    char     achievement_badge_url[512];
    float    achievement_rarity;
    float    achievement_rarity_hardcore;
    uint8_t  achievement_type;  /* 0=standard, 1=missable, 2=progression, 3=win */
    /* For server error events */
    char     error_message[512];
    int      error_code;
} yage_rc_event_t;

/**
 * Check if there's a pending event.
 * Returns 1 if an event is available, 0 if not.
 */
YAGE_API int yage_rc_has_pending_event(void);

/**
 * Get the next pending event.
 * Copies the event data into the provided struct.
 * Returns 1 if an event was copied, 0 if none available.
 */
YAGE_API int yage_rc_get_pending_event(yage_rc_event_t* out_event);

/**
 * Consume (remove) the current pending event.
 * Call after processing the event from yage_rc_get_pending_event().
 */
YAGE_API void yage_rc_consume_event(void);

/* ═══════════════════════════════════════════════════════════════════════
 *  State
 * ═══════════════════════════════════════════════════════════════════════ */

/** Get the current load game state (RC_CLIENT_LOAD_GAME_STATE_*). */
YAGE_API int yage_rc_get_load_game_state(void);

/** Check if there's any processing required (active achievements, etc.). */
YAGE_API int yage_rc_is_processing_required(void);

/** Get whether hardcore mode is currently enabled. */
YAGE_API int yage_rc_get_hardcore_enabled(void);

#ifdef __cplusplus
}
#endif

#endif /* YAGE_RCHEEVOS_H */
