/*
 * YAGE Core Variables Module
 * 
 * Handles libretro core option storage and retrieval.
 * Cores like Mupen64Plus-Next depend on storing core variables so
 * GET_VARIABLE can return values during retro_run.
 */

#include "yage_internal.h"

/* ── Local struct definitions (minimal subset for parsing) ────────────────
 * These match the libretro spec for core option storage.
 * Shared types are defined in yage_libretro.c; this module uses local
 * declarations to avoid redefinition conflicts when linking. */

struct cv_retro_variable {
    const char *key;
    const char *value;
};

struct cv_core_option_value {
    const char *value;
    const char *label;
};

#define CV_OPTION_VALUES_MAX 128
struct cv_core_option_v2_definition {
    const char *key;
    const char *desc;
    const char *desc_categorized;
    const char *info;
    const char *info_categorized;
    const char *category_key;
    struct cv_core_option_value values[CV_OPTION_VALUES_MAX];
    const char *default_value;
};

struct cv_core_options_v2 {
    void *categories;
    struct cv_core_option_v2_definition *definitions;
};

#define MAX_CORE_VARS 256
#define MAX_VAR_KEY_LEN 128
#define MAX_VAR_VAL_LEN 256

static struct {
    char key[MAX_VAR_KEY_LEN];
    char value[MAX_VAR_VAL_LEN];
} g_core_vars[MAX_CORE_VARS];

int g_core_vars_count = 0;

void core_vars_clear(void) {
    g_core_vars_count = 0;
    options_ui_clear();
}

void core_vars_set(const char* key, const char* value) {
    if (!key || !value) return;
    for (int i = 0; i < g_core_vars_count; i++) {
        if (strcmp(g_core_vars[i].key, key) == 0) {
            snprintf(g_core_vars[i].value, MAX_VAR_VAL_LEN, "%s", value);
            options_ui_set_value(key, value);
            if (strstr(key, "opengl") || strstr(key, "renderer")) {
                LOGI("core_vars_set: updated key=%s -> \"%s\"", key, value);
            }
            return;
        }
    }
    if (g_core_vars_count < MAX_CORE_VARS) {
        snprintf(g_core_vars[g_core_vars_count].key, MAX_VAR_KEY_LEN, "%s", key);
        snprintf(g_core_vars[g_core_vars_count].value, MAX_VAR_VAL_LEN, "%s", value);
        g_core_vars_count++;
        options_ui_set_from_retro_variable(key, value);
        if (strstr(key, "opengl") || strstr(key, "renderer")) {
            LOGI("core_vars_set: inserted key=%s -> \"%s\"", key, value);
        }
    }
}

const char* core_vars_get(const char* key) {
    if (!key) return NULL;
    for (int i = 0; i < g_core_vars_count; i++) {
        if (strcmp(g_core_vars[i].key, key) == 0) {
            return g_core_vars[i].value;
        }
    }
    return NULL;
}

/* Parse SET_VARIABLES (cmd 16) — value format: "Description; opt1|opt2|opt3"
 * First option after the semicolon is the default. */
void core_vars_parse_set_variables(const void* vars_raw) {
    if (!vars_raw) return;
    options_ui_clear();
    const struct cv_retro_variable* vars = (const struct cv_retro_variable*)vars_raw;
    for (; vars->key; vars++) {
        if (!vars->value) continue;
        const char* semi = strchr(vars->value, ';');
        if (!semi) continue;
        semi++;
        while (*semi == ' ') semi++;
        options_ui_set_from_retro_variable(vars->key, semi);
        char def[MAX_VAR_VAL_LEN];
        const char* pipe = strchr(semi, '|');
        size_t len = pipe ? (size_t)(pipe - semi) : strlen(semi);
        if (len >= MAX_VAR_VAL_LEN) len = MAX_VAR_VAL_LEN - 1;
        memcpy(def, semi, len);
        def[len] = '\0';
        /* Log keys that may affect renderer selection. */
        if (strstr(vars->key, "opengl") || strstr(vars->key, "renderer")) {
            LOGI("SET_VARIABLES: key=%s default=\"%s\"", vars->key, def);
        }
        core_vars_set(vars->key, def);
    }
}

void core_vars_parse_set_core_options_v2(const void* opts_raw) {
    if (!opts_raw) return;
    options_ui_clear();
    const struct cv_core_options_v2* opts = (const struct cv_core_options_v2*)opts_raw;
    if (!opts->definitions) return;
    LOGI("core_vars_parse_set_core_options_v2: sizeof(cv_core_option_v2_definition) = %zu", sizeof(struct cv_core_option_v2_definition));
    int count = 0;
    for (const struct cv_core_option_v2_definition* d = opts->definitions; d->key; d++) {
        const char* def = d->default_value;
        if (!def && d->values[0].value) {
            def = d->values[0].value;
        }
        if (def) {
            core_vars_set(d->key, def);
        }
        options_ui_set_from_v2_option(d->key, d->desc, d->category_key, def);
        count++;
    }
    LOGI("core_vars_parse_set_core_options_v2: parsed %d options", count);
}

