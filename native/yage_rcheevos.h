

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




YAGE_API int yage_rc_init(void* yage_core);


YAGE_API void yage_rc_destroy(void);




YAGE_API void yage_rc_set_hardcore(int enabled);


YAGE_API void yage_rc_set_encore(int enabled);


YAGE_API int yage_rc_get_user_agent_clause(char* buffer, int buffer_size);




YAGE_API void yage_rc_begin_login(const char* username, const char* token);


YAGE_API int yage_rc_is_logged_in(void);


YAGE_API const char* yage_rc_get_user_display_name(void);


YAGE_API void yage_rc_logout(void);




YAGE_API void yage_rc_begin_load_game(const char* hash);


YAGE_API int yage_rc_is_game_loaded(void);


YAGE_API const char* yage_rc_get_game_title(void);


YAGE_API uint32_t yage_rc_get_game_id(void);


YAGE_API const char* yage_rc_get_game_badge_url(void);


YAGE_API void yage_rc_unload_game(void);


YAGE_API void yage_rc_reset(void);




YAGE_API void yage_rc_do_frame(void);


YAGE_API void yage_rc_idle(void);




YAGE_API uint32_t yage_rc_get_achievement_count(void);


YAGE_API uint32_t yage_rc_get_unlocked_count(void);


YAGE_API uint32_t yage_rc_get_total_points(void);


YAGE_API uint32_t yage_rc_get_unlocked_points(void);




YAGE_API uint32_t yage_rc_get_pending_request(void);


YAGE_API const char* yage_rc_get_request_url(uint32_t request_id);


YAGE_API const char* yage_rc_get_request_post_data(uint32_t request_id);


YAGE_API const char* yage_rc_get_request_content_type(uint32_t request_id);


YAGE_API void yage_rc_submit_response(uint32_t request_id,
                                       const char* body,
                                       uint32_t body_length,
                                       int http_status);




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


#define YAGE_RC_EVENT_LOGIN_SUCCESS           100
#define YAGE_RC_EVENT_LOGIN_FAILED            101
#define YAGE_RC_EVENT_GAME_LOAD_SUCCESS       102
#define YAGE_RC_EVENT_GAME_LOAD_FAILED        103


typedef struct yage_rc_event_t {
    uint32_t type;
    uint32_t achievement_id;
    uint32_t achievement_points;
    char     achievement_title[256];
    char     achievement_description[256];
    char     achievement_badge_url[512];
    float    achievement_rarity;
    float    achievement_rarity_hardcore;
    uint8_t  achievement_type;  
    
    char     error_message[512];
    int      error_code;
} yage_rc_event_t;


YAGE_API int yage_rc_has_pending_event(void);


YAGE_API int yage_rc_get_pending_event(yage_rc_event_t* out_event);


YAGE_API void yage_rc_consume_event(void);




YAGE_API int yage_rc_get_load_game_state(void);


YAGE_API int yage_rc_is_processing_required(void);


YAGE_API int yage_rc_get_hardcore_enabled(void);

#ifdef __cplusplus
}
#endif

#endif 
