

#include "yage_rcheevos.h"
#include "yage_libretro.h"  
#include "rcheevos/include/rc_client.h"
#include "rcheevos/include/rc_consoles.h"

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



static rc_client_t* g_rc_client = NULL;
static YageCore* g_yage_core = NULL;


static const rc_memory_regions_t* g_memory_regions = NULL;



#define MAX_PENDING_REQUESTS 32

typedef struct {
    int active;                            
    uint32_t id;                           
    char* url;                             
    char* post_data;                       
    char* content_type;                    
    rc_client_server_callback_t callback;  
    void* callback_data;                   
} pending_request_t;

static pending_request_t g_requests[MAX_PENDING_REQUESTS];
static uint32_t g_next_request_id = 1;



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




static uint32_t translate_address(uint32_t rc_address) {
    if (!g_memory_regions || g_memory_regions->num_regions == 0)
        return rc_address; 

    for (uint32_t i = 0; i < g_memory_regions->num_regions; i++) {
        const rc_memory_region_t* region = &g_memory_regions->region[i];
        if (rc_address >= region->start_address &&
            rc_address <= region->end_address) {
            return region->real_address + (rc_address - region->start_address);
        }
    }

    
    return rc_address;
}


static uint32_t RC_CCONV memory_reader(uint32_t address, uint8_t* buffer,
                                        uint32_t num_bytes, rc_client_t* client) {
    
    YageCore* core = g_yage_core;
    if (!core || !buffer || num_bytes == 0) return 0;

    
    const rc_memory_regions_t* regions = g_memory_regions;
    if (!regions && client) {
        const rc_client_game_t* game = rc_client_get_game_info(client);
        if (game && game->console_id != 0) {
            regions = rc_console_memory_regions(game->console_id);
            if (regions) {
                g_memory_regions = regions;
                RC_LOGI("Memory regions resolved: %u regions for console %u",
                        regions->num_regions, game->console_id);
            }
        }
    }

    
    if (regions && regions->num_regions > 0) {
        uint32_t last = address + num_bytes - 1;
        for (uint32_t i = 0; i < regions->num_regions; i++) {
            const rc_memory_region_t* r = &regions->region[i];
            if (address >= r->start_address && last <= r->end_address) {
                uint32_t hw_addr = r->real_address + (address - r->start_address);
                int result = yage_core_read_memory(core, hw_addr,
                                                    (int32_t)num_bytes, buffer);
                return (result > 0) ? (uint32_t)result : 0;
            }
        }
    }

    
    for (uint32_t i = 0; i < num_bytes; i++) {
        uint32_t hw_addr = translate_address(address + i);
        uint8_t byte_val = 0;
        int result = yage_core_read_memory(core, hw_addr, 1, &byte_val);
        if (result <= 0) return i; 
        buffer[i] = byte_val;
    }
    return num_bytes;
}


static void RC_CCONV server_call(const rc_api_request_t* request,
                                  rc_client_server_callback_t callback,
                                  void* callback_data,
                                  rc_client_t* client) {
    (void)client;

    
    int slot = -1;
    for (int i = 0; i < MAX_PENDING_REQUESTS; i++) {
        if (!g_requests[i].active) {
            slot = i;
            break;
        }
    }

    if (slot < 0) {
        RC_LOGE("HTTP request queue full — dropping request!");
        
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


static void RC_CCONV event_handler(const rc_client_event_t* event,
                                    rc_client_t* client) {
    (void)client;
    if (!event) return;

    yage_rc_event_t ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = event->type;

    
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


static void RC_CCONV log_message(const char* message, const rc_client_t* client) {
    (void)client;
    RC_LOGI("rc_client: %s", message ? message : "(null)");
}


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

        
        if (!g_memory_regions && game) {
            g_memory_regions = rc_console_memory_regions(game->console_id);
        }

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



int yage_rc_init(void* yage_core) {
    if (g_rc_client) {
        RC_LOGI("rc_client already initialized — destroying first");
        yage_rc_destroy();
    }

    g_yage_core = (YageCore*)yage_core;

    
    memset(g_requests, 0, sizeof(g_requests));
    g_next_request_id = 1;
    g_event_read = 0;
    g_event_write = 0;

    
    g_rc_client = rc_client_create(memory_reader, server_call);
    if (!g_rc_client) {
        RC_LOGE("Failed to create rc_client");
        return -1;
    }

    
    rc_client_set_event_handler(g_rc_client, event_handler);

    
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
    g_memory_regions = NULL;

    
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



void yage_rc_begin_load_game(const char* hash) {
    if (!g_rc_client || !hash) return;
    RC_LOGI("Beginning game load for hash: %s", hash);
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
    g_memory_regions = NULL;
    RC_LOGI("Game unloaded");
}

void yage_rc_reset(void) {
    if (!g_rc_client) return;
    rc_client_reset(g_rc_client);
    RC_LOGI("Runtime reset");
}



void yage_rc_do_frame(void) {
    if (!g_rc_client) return;
    rc_client_do_frame(g_rc_client);
}

void yage_rc_idle(void) {
    if (!g_rc_client) return;
    rc_client_idle(g_rc_client);
}



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

            
            rc_api_server_response_t response;
            memset(&response, 0, sizeof(response));
            response.body = body;
            response.body_length = (size_t)body_length;
            response.http_status_code = http_status;

            
            rc_client_server_callback_t cb = req->callback;
            void* cb_data = req->callback_data;

            
            free(req->url);
            free(req->post_data);
            free(req->content_type);
            memset(req, 0, sizeof(pending_request_t));

            
            cb(&response, cb_data);
            return;
        }
    }

    RC_LOGE("HTTP response for unknown request id=%u", request_id);
}



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
