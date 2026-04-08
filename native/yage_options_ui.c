#include "yage_internal.h"
#include <ctype.h>
#include <stdio.h>

#define MAX_CORE_OPTIONS 256
#define MAX_OPTION_KEY_LEN 128
#define MAX_OPTION_DESC_LEN 256
#define MAX_OPTION_CAT_LEN 64
#define MAX_OPTION_VAL_LEN 256
#define MAX_OPTION_VALUES 64

struct core_option_metadata {
    char key[MAX_OPTION_KEY_LEN];
    char description[MAX_OPTION_DESC_LEN];
    char category[MAX_OPTION_CAT_LEN];
    char value[MAX_OPTION_VAL_LEN];           
    char default_value[MAX_OPTION_VAL_LEN];
    char type[32];                             
    struct {
        char value[MAX_OPTION_VAL_LEN];
        char label[MAX_OPTION_VAL_LEN];
    } values[MAX_OPTION_VALUES];
    int values_count;
};

static struct core_option_metadata g_core_options[MAX_CORE_OPTIONS];
static int g_core_options_count = 0;
static pthread_mutex_t g_options_mutex = PTHREAD_MUTEX_INITIALIZER;

void options_ui_clear(void) {
    pthread_mutex_lock(&g_options_mutex);
    g_core_options_count = 0;
    memset(g_core_options, 0, sizeof(g_core_options));
    pthread_mutex_unlock(&g_options_mutex);
}

static int find_option_index(const char* key) {
    for (int i = 0; i < g_core_options_count; i++) {
        if (strcmp(g_core_options[i].key, key) == 0) {
            return i;
        }
    }
    return -1;
}

void options_ui_set_from_retro_variable(const char* key, const char* value) {
    if (!key || !value) return;

    pthread_mutex_lock(&g_options_mutex);

    int idx = find_option_index(key);
    if (idx == -1 && g_core_options_count < MAX_CORE_OPTIONS) {
        idx = g_core_options_count++;
    }

    if (idx >= 0 && idx < MAX_CORE_OPTIONS) {
        struct core_option_metadata* opt = &g_core_options[idx];

        strncpy(opt->key, key, MAX_OPTION_KEY_LEN - 1);
        opt->key[MAX_OPTION_KEY_LEN - 1] = '\0';

        
        
        strncpy(opt->value, value, MAX_OPTION_VAL_LEN - 1);
        opt->value[MAX_OPTION_VAL_LEN - 1] = '\0';

        strncpy(opt->default_value, value, MAX_OPTION_VAL_LEN - 1);
        opt->default_value[MAX_OPTION_VAL_LEN - 1] = '\0';

        strncpy(opt->type, "select", sizeof(opt->type) - 1);

        
        opt->values_count = 0;
        const char* p = value;
        int is_first = 1;

        while (*p && opt->values_count < MAX_OPTION_VALUES) {
            
            while (*p && isspace(*p)) p++;
            if (!*p) break;

            
            const char* start = p;
            while (*p && *p != '|') p++;

            int len = p - start;
            if (len > 0 && len < (int)MAX_OPTION_VAL_LEN) {
                
                while (len > 0 && isspace(start[len - 1])) len--;

                strncpy(opt->values[opt->values_count].value, start, len);
                opt->values[opt->values_count].value[len] = '\0';

                
                strncpy(opt->values[opt->values_count].label,
                        opt->values[opt->values_count].value,
                        MAX_OPTION_VAL_LEN - 1);
                opt->values[opt->values_count].label[MAX_OPTION_VAL_LEN - 1] = '\0';

                
                if (is_first) {
                    strncpy(opt->default_value, opt->values[opt->values_count].value,
                            MAX_OPTION_VAL_LEN - 1);
                    is_first = 0;
                }

                opt->values_count++;
            }

            if (*p == '|') p++;
        }
    }

    pthread_mutex_unlock(&g_options_mutex);
}

void options_ui_set_from_v2_option(const char* key, const char* description,
                                    const char* category, const char* default_val) {
    if (!key) return;

    pthread_mutex_lock(&g_options_mutex);

    int idx = find_option_index(key);
    if (idx == -1 && g_core_options_count < MAX_CORE_OPTIONS) {
        idx = g_core_options_count++;
    }

    if (idx >= 0 && idx < MAX_CORE_OPTIONS) {
        struct core_option_metadata* opt = &g_core_options[idx];

        strncpy(opt->key, key, MAX_OPTION_KEY_LEN - 1);
        opt->key[MAX_OPTION_KEY_LEN - 1] = '\0';

        if (description) {
            strncpy(opt->description, description, MAX_OPTION_DESC_LEN - 1);
            opt->description[MAX_OPTION_DESC_LEN - 1] = '\0';
        }

        if (category) {
            strncpy(opt->category, category, MAX_OPTION_CAT_LEN - 1);
            opt->category[MAX_OPTION_CAT_LEN - 1] = '\0';
        }

        if (default_val) {
            strncpy(opt->default_value, default_val, MAX_OPTION_VAL_LEN - 1);
            opt->default_value[MAX_OPTION_VAL_LEN - 1] = '\0';

            strncpy(opt->value, default_val, MAX_OPTION_VAL_LEN - 1);
            opt->value[MAX_OPTION_VAL_LEN - 1] = '\0';
        }

        strncpy(opt->type, "select", sizeof(opt->type) - 1);
    }

    pthread_mutex_unlock(&g_options_mutex);
}

const char* options_ui_get_value(const char* key) {
    if (!key) return NULL;

    pthread_mutex_lock(&g_options_mutex);
    int idx = find_option_index(key);
    const char* value = (idx >= 0) ? g_core_options[idx].value : NULL;
    pthread_mutex_unlock(&g_options_mutex);

    return value;
}

int options_ui_set_value(const char* key, const char* value) {
    if (!key || !value) return -1;

    pthread_mutex_lock(&g_options_mutex);

    int idx = find_option_index(key);
    if (idx < 0) {
        pthread_mutex_unlock(&g_options_mutex);
        return -1; 
    }

    strncpy(g_core_options[idx].value, value, MAX_OPTION_VAL_LEN - 1);
    g_core_options[idx].value[MAX_OPTION_VAL_LEN - 1] = '\0';

    pthread_mutex_unlock(&g_options_mutex);
    return 0;
}

static void json_escape_string(const char* src, char* dst, size_t dst_size) {
    if (!src || !dst || dst_size < 2) return;

    char* p = dst;
    char* end = dst + dst_size - 1;

    while (*src && p < end - 1) {
        switch (*src) {
            case '"':
                if (p + 1 < end) { *p++ = '\\'; *p++ = '"'; }
                break;
            case '\\':
                if (p + 1 < end) { *p++ = '\\'; *p++ = '\\'; }
                break;
            case '\n':
                if (p + 1 < end) { *p++ = '\\'; *p++ = 'n'; }
                break;
            case '\r':
                if (p + 1 < end) { *p++ = '\\'; *p++ = 'r'; }
                break;
            case '\t':
                if (p + 1 < end) { *p++ = '\\'; *p++ = 't'; }
                break;
            default:
                *p++ = *src;
        }
        src++;
    }

    *p = '\0';
}

char* options_ui_build_json(void) {
    
    size_t buffer_size = 64 * 1024; 
    char* json_buf = (char*)malloc(buffer_size);
    if (!json_buf) return NULL;

    pthread_mutex_lock(&g_options_mutex);

    int offset = 0;
    #define APPEND(...) do { \
        int written = snprintf(json_buf + offset, buffer_size - offset, __VA_ARGS__); \
        if (written > 0) offset += written; \
        if (offset >= (int)buffer_size - 512) { \
            LOGE("options_ui: JSON buffer overflow"); \
            offset = buffer_size - 1; \
        } \
    } while(0)

    APPEND("{\"options\":[");

    for (int i = 0; i < g_core_options_count; i++) {
        if (i > 0) APPEND(",");

        struct core_option_metadata* opt = &g_core_options[i];

        char key_esc[MAX_OPTION_KEY_LEN * 2];
        char desc_esc[MAX_OPTION_DESC_LEN * 2];
        char cat_esc[MAX_OPTION_CAT_LEN * 2];
        char val_esc[MAX_OPTION_VAL_LEN * 2];
        char def_esc[MAX_OPTION_VAL_LEN * 2];

        json_escape_string(opt->key, key_esc, sizeof(key_esc));
        json_escape_string(opt->description, desc_esc, sizeof(desc_esc));
        json_escape_string(opt->category, cat_esc, sizeof(cat_esc));
        json_escape_string(opt->value, val_esc, sizeof(val_esc));
        json_escape_string(opt->default_value, def_esc, sizeof(def_esc));

        APPEND("{");
        APPEND("\"key\":\"%s\",", key_esc);
        APPEND("\"description\":\"%s\",", desc_esc);
        APPEND("\"category\":\"%s\",", cat_esc);
        APPEND("\"type\":\"%s\",", opt->type);
        APPEND("\"defaultValue\":\"%s\",", def_esc);
        APPEND("\"currentValue\":\"%s\",", val_esc);
        APPEND("\"values\":[");

        for (int j = 0; j < opt->values_count; j++) {
            if (j > 0) APPEND(",");

            char val_esc2[MAX_OPTION_VAL_LEN * 2];
            char lbl_esc[MAX_OPTION_VAL_LEN * 2];

            json_escape_string(opt->values[j].value, val_esc2, sizeof(val_esc2));
            json_escape_string(opt->values[j].label, lbl_esc, sizeof(lbl_esc));

            APPEND("{\"value\":\"%s\",\"label\":\"%s\"}", val_esc2, lbl_esc);
        }

        APPEND("]");  
        APPEND("}");   
    }

    APPEND("]");    
    APPEND("}");    

    pthread_mutex_unlock(&g_options_mutex);

    #undef APPEND

    return json_buf;
}

const char* options_ui_get_json(void) {
    static char* g_cached_json = NULL;

    if (g_cached_json) {
        free(g_cached_json);
    }

    g_cached_json = options_ui_build_json();
    return g_cached_json ? g_cached_json : "{}";
}

void options_ui_free_json(const char* json) {
    
    (void)json;
}
