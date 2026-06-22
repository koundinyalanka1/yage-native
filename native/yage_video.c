/*
 * YAGE Video Module
 *
 * Video processing pipeline and ANativeWindow blit path.
 * Handles:
 *   - Pixel format conversion (XRGB8888, RGB565, 0RGB1555)
 *   - GBA colour-correction boost
 *   - GB colour-palette remapping
 *   - video_refresh_callback (libretro contract)
 *   - ANativeWindow blit + JNI surface management (Android)
 *   - yage_texture_blit / yage_texture_is_attached (Flutter Texture API)
 */

#include "yage_internal.h"

#include <math.h>   /* powf — color tuning LUT build */

/* ── Video dimensions ────────────────────────────────────────────────── */
int g_width  = GBA_WIDTH;
int g_height = GBA_HEIGHT;

/* ── Pixel format + palette configuration ────────────────────────────── */
int      g_pixel_format              = RETRO_PIXEL_FORMAT_RGB565;
/* Back-compat flag — now means "color tuning active". Kept exported so
 * existing externs keep linking; always mirrors g_tune_active below. */
int      g_color_correction_enabled  = 0;
int      g_palette_enabled           = 0;   /* 0 = original, 1 = remap  */
uint32_t g_palette_colors[4] = {
    0xFF0FBC9B, /* Lightest */
    0xFF0FAC8B, /* Light    */
    0xFF306230, /* Dark     */
    0xFF0F380F  /* Darkest  */
};

/* ── Video frame counters (shared with audio for rate detection) ─────── */
int g_video_frames_total  = 0;

/* ── ANativeWindow state (Android only) ──────────────────────────────── */
#ifdef __ANDROID__
ANativeWindow*  g_native_window    = NULL;
static int      g_nw_configured_w  = 0;
static int      g_nw_configured_h  = 0;
static int      g_blit_diag_count  = 0;
pthread_mutex_t g_nw_mutex         = PTHREAD_MUTEX_INITIALIZER;
#endif

/* ── Sharp-bilinear integer prescale (software blit path) ─────────────
 *
 * "Auto Optimized" wants pixel art that is neither blocky (pure nearest)
 * nor soft (pure bilinear/bicubic from native resolution, which feathers
 * edges across a full game-pixel width on screen).  The fix is two-stage
 * scaling: expand the framebuffer by an integer factor N with HARD
 * nearest-neighbour pixels here on the CPU, then let the GPU's smooth
 * sampler (Flutter Texture filterQuality) cover only the remaining
 * fractional stretch.  Edge feathering shrinks from ~scale device pixels
 * to ~scale/total — visually "crisp but smooth" (RetroArch's sharp-bilinear).
 *
 * The value pushed from Dart (yage_video_set_prescale) is the TARGET TOTAL
 * on-screen CPU expansion, ≈ round(physical scale × 0.70) — biased toward
 * pixel-perfect on the soft(0.5×)→pixel(1.0×) axis, so the GPU bicubic keeps
 * only a ~1.3–1.6× residual (see game_display.dart). Capped 8 on phones / 2
 * on TV; 1 in Authentic Pixel Mode and for hw direct-present cores (their blit
 * never passes through here anyway).
 *
 * When the edge-aware art-scaler is active (g_fx_artscale, all 2D cores in
 * Auto) the total is realized as art-base × nearest-passes (see
 * choose_art_base + the blit) — including art-base 1 (pure nearest) when that
 * lands closest, the natural "toward pixel" end; when it is off the total IS
 * the nearest factor N directly.
 *
 * Cost: one nearest row-expansion + N row memcpys per output frame,
 * bounded by PRESCALE_MAX_PIXELS below (~1-2 ms on a phone big core for
 * the worst case).  Screenshots / save-state thumbnails / the Dart
 * display buffer all read g_video_buffer (unscaled) and are unaffected.
 */
static int g_prescale_factor = 1;   /* 1 = off; set via FFI */
#ifdef __ANDROID__
/* Cap on the sharp-bilinear expanded output buffer.  ~3.3 Mpx lets the
 * common framebuffers reach the higher integer prescale the Dart side now
 * asks for (phone cap 8×) without the budget clipping them a factor short:
 *   - GB/GBC/GG 160×144 @ 8× = 1.47 Mpx
 *   - GBA 240×160 @ 8×       = 2.46 Mpx
 *   - NES/SNES 256×240 @ 6×  = 2.21 Mpx (was clipped to 5× by the old cap)
 *   - PS1 (software) 320×240 @ 5× = 1.92 Mpx
 * Cost is one nearest row-expansion + N row memcpys per frame (~3-4 ms on a
 * phone big core at the top of this budget) — within the phone frame budget,
 * and phones are the device class explicitly targeted for maximum quality.
 * TV is unaffected: its Dart-side prescale cap is 2×, so TV output never
 * approaches this limit. */
#define PRESCALE_MAX_PIXELS 3300000 /* cap output buffer ≈ 3.3 Mpx */
static uint32_t* g_prescale_row     = NULL; /* one expanded row (dw px) */
static size_t    g_prescale_row_cap = 0;    /* capacity in pixels */
#endif

YAGE_API void yage_video_set_prescale(YageCore* core, int32_t factor) {
    (void)core;
    if (factor < 1) factor = 1;
    /* Match the Dart-side phone cap (game_display.dart _desiredPrescale).
     * Was 4 — which silently clipped the factor Dart computes for small
     * framebuffers (GB/GBC/GG/NGP/WS/VB) on high-DPI phones/tablets, so
     * those cores upscaled through a softer fractional GPU stretch than
     * intended. 8 lets a 160×144 buffer reach the full integer step on a
     * 1440p panel; the per-frame PRESCALE_MAX_PIXELS budget below still
     * caps the actual expansion so large framebuffers can't run away. */
    if (factor > 8) factor = 8;
    if (factor != g_prescale_factor) {
        g_prescale_factor = factor;
        LOGI("Video prescale: factor=%d", factor);
    }
}

/* ══════════════════════════════════════════════════════════════════════
 * Per-system display FX  ("out of the box" 2D enhancement, Auto mode)
 *
 * Four optional, composable effects applied in the software blit so they
 * cover the primary Android Texture path and every software-rendered 2D
 * core uniformly. Each intensity is 0..100 (0 = off). The whole pipeline
 * is gated by g_fx_active — when every effect is off the blit takes the
 * original fast path and the output is byte-identical to before.
 *
 *   artscale  — Scale2x/EPX edge-aware expansion (rounds the pixel-art
 *               staircase into clean shapes) used as the first scale step,
 *               then the existing nearest+GPU-bicubic finishes the stretch.
 *   ntsc      — light composite-video horizontal blend: merges dithering
 *               into gradients and softens chroma (NES/Genesis look). A
 *               cheap approximation of blargg nes-/snes-ntsc, not a full
 *               signal simulation.
 *   ghost     — inter-frame blend (LCD persistence/"smear") for handhelds;
 *               also restores transparency effects games faked via LCD blur.
 *   scanline  — darkens one output row per source scanline (console CRT).
 *   lcdgrid   — darkens the cell's bottom row + right column (handheld LCD
 *               pixel grid).
 *
 * Policy (which system gets which) lives in Dart
 * (EmulatorService._applyVideoFx); this layer just renders what it's told.
 * Authentic Pixel Mode pushes all-zero, so it is never touched.
 * ══════════════════════════════════════════════════════════════════════ */

static int g_fx_active   = 0;
static int g_fx_artscale = 0;  /* 0/1   — Scale2x edge-aware expand        */
static int g_fx_scanline = 0;  /* 0..100 — scanline darkening (consoles)   */
static int g_fx_lcdgrid  = 0;  /* 0..100 — LCD pixel-grid (handhelds)      */
static int g_fx_ghost    = 0;  /* 0..100 — inter-frame blend (LCD smear)   */
static int g_fx_ntsc     = 0;  /* 0..100 — composite horizontal blend      */

/* Ghost (inter-frame blend) needs the previous frame. The validity flag
 * lives out here (plain int) so a new ROM can invalidate it via
 * yage_video_apply_default_tuning; the previous-frame dims + pixel buffers
 * are Android-only and declared with the blit scratch below. */
static int g_fx_prev_valid = 0;

YAGE_API void yage_video_set_fx(YageCore* core,
                                int32_t artscale, int32_t scanline,
                                int32_t lcdgrid, int32_t ghost, int32_t ntsc) {
    (void)core;
    #define FX_CLAMP100(v) ((v) < 0 ? 0 : ((v) > 100 ? 100 : (int)(v)))
    g_fx_artscale = artscale > 0 ? 1 : 0;
    g_fx_scanline = FX_CLAMP100(scanline);
    g_fx_lcdgrid  = FX_CLAMP100(lcdgrid);
    g_fx_ghost    = FX_CLAMP100(ghost);
    g_fx_ntsc     = FX_CLAMP100(ntsc);
    #undef FX_CLAMP100
    g_fx_active = (g_fx_artscale || g_fx_scanline || g_fx_lcdgrid ||
                  g_fx_ghost || g_fx_ntsc) ? 1 : 0;
    LOGI("Video FX: art=%d scan=%d grid=%d ghost=%d ntsc=%d -> active=%d",
         g_fx_artscale, g_fx_scanline, g_fx_lcdgrid,
         g_fx_ghost, g_fx_ntsc, g_fx_active);
}

/* ══════════════════════════════════════════════════════════════════════
 * Generalized color tuning (brightness / contrast / saturation / gamma)
 *
 * Replaces the old GB-family-only "+10% contrast" boost with a tunable,
 * LUT-driven pipeline that works for every software-rendered core:
 *
 *   1. Per-channel curve LUT (256 entries) combining gamma → contrast →
 *      brightness.  Built once in yage_video_set_color_tuning(); the hot
 *      loop is a single table lookup per channel.
 *   2. Integer saturation mix around Rec.601 luma (Q8 fixed point).
 *
 * When all parameters are neutral (1.0) g_tune_active is 0 and the
 * existing fast row-converter path is used — zero added cost.
 *
 * NOTE: hardware direct-present cores (melonDS GL, mupen64plus, Beetle PSX
 * HW on Android) bypass this path entirely (EGL window surface).  Their
 * color tuning is applied by the Flutter compositor (ColorFiltered matrix
 * in game_display.dart).  Keep the two mild and equivalent.
 * ══════════════════════════════════════════════════════════════════════ */

static int     g_tune_active  = 0;
static int     g_tune_sat_q8  = 256;        /* saturation, Q8 (256 = 1.0) */
static uint8_t g_tune_lut[256];

/* Defaults are neutral until yage_video_apply_default_tuning() or the
 * Dart-side yage_video_set_color_tuning() configures them. */

static inline uint8_t clamp_u8(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return (uint8_t)v;
}

YAGE_API void yage_video_set_color_tuning(YageCore* core,
                                          float brightness,
                                          float contrast,
                                          float saturation,
                                          float gamma) {
    (void)core;

    /* Clamp to mild, safe ranges — this API is for gentle correction, not
     * artistic grading.  Values outside these ranges produce washed-out or
     * neon output, which we explicitly do not want. */
    if (!(brightness > 0.0f)) brightness = 1.0f;
    if (!(contrast   > 0.0f)) contrast   = 1.0f;
    if (!(saturation >= 0.0f)) saturation = 1.0f;
    if (!(gamma      > 0.0f)) gamma      = 1.0f;
    if (brightness < 0.5f) brightness = 0.5f;  if (brightness > 1.5f) brightness = 1.5f;
    if (contrast   < 0.5f) contrast   = 0.5f;  if (contrast   > 1.5f) contrast   = 1.5f;
    if (saturation < 0.0f) saturation = 0.0f;  if (saturation > 1.5f) saturation = 1.5f;
    if (gamma      < 0.5f) gamma      = 0.5f;  if (gamma      > 2.0f) gamma      = 2.0f;

    const int neutral =
        brightness > 0.995f && brightness < 1.005f &&
        contrast   > 0.995f && contrast   < 1.005f &&
        saturation > 0.995f && saturation < 1.005f &&
        gamma      > 0.995f && gamma      < 1.005f;

    if (neutral) {
        /* Disable first so the frame thread stops reading the LUT before
         * we (don't) touch it.  A relaxed int store is fine — worst case
         * one frame uses the old tuning. */
        g_tune_active = 0;
        g_color_correction_enabled = 0;
        LOGI("Color tuning: neutral (fast path)");
        return;
    }

    /* Build the new curve into a local table, then copy.  The frame thread
     * may read mid-copy; per-entry tearing is visually harmless (one frame
     * blends old/new curve). */
    uint8_t lut[256];
    for (int i = 0; i < 256; i++) {
        float v = (float)i / 255.0f;
        /* Gamma (gamma < 1 lifts midtones, > 1 darkens). */
        v = powf(v, gamma);
        /* Contrast around mid-gray. */
        v = (v - 0.5f) * contrast + 0.5f;
        /* Brightness multiply (preserves black — no crushed blacks). */
        v = v * brightness;
        int out = (int)(v * 255.0f + 0.5f);
        lut[i] = clamp_u8(out);
    }
    memcpy(g_tune_lut, lut, sizeof(g_tune_lut));
    g_tune_sat_q8 = (int)(saturation * 256.0f + 0.5f);
    g_tune_active = 1;
    g_color_correction_enabled = 1;
    LOGI("Color tuning: b=%.2f c=%.2f s=%.2f g=%.2f",
         (double)brightness, (double)contrast,
         (double)saturation, (double)gamma);
}

/* Load-time defaults, applied from yage_core_load_rom.
 *
 * GB / GBC / GBA: these handhelds had dim, low-saturation LCD panels and
 * games were authored over-bright/over-saturated to compensate.  On a
 * modern phone/TV panel the raw output looks dull, so they keep a mild
 * boost by default — the successor of the old fixed "+10% contrast", plus
 * a slight midtone lift and natural saturation.
 *
 * Every other platform starts NEUTRAL here.  The Dart side
 * (EmulatorService) pushes the per-platform tuning right after loading,
 * because it knows the exact frontend platform (the native extension
 * sniffer maps PS1 / PCE / Intellivision to YAGE_PLATFORM_UNKNOWN) and the
 * user's Graphics Quality mode (Pixel = authentic colors = neutral).
 */
void yage_video_apply_default_tuning(int platform) {
    /* New game = fresh display state: drop any prescale factor from the
     * previous session (the Dart side re-pushes the right factor for the
     * new framebuffer size / mode within a second), and invalidate the
     * ghost (inter-frame blend) history so no smear leaks across games. */
    g_prescale_factor = 1;
    g_fx_prev_valid = 0;
    switch (platform) {
        case YAGE_PLATFORM_GB:
        case YAGE_PLATFORM_GBC:
        case YAGE_PLATFORM_GBA:
            yage_video_set_color_tuning(NULL, 1.02f, 1.08f, 1.06f, 0.96f);
            break;
        default:
            yage_video_set_color_tuning(NULL, 1.0f, 1.0f, 1.0f, 1.0f);
            break;
    }
}

static inline uint32_t apply_color_correction(uint8_t r, uint8_t g, uint8_t b) {
    /* Curve LUT (gamma → contrast → brightness). */
    int ri = g_tune_lut[r];
    int gi = g_tune_lut[g];
    int bi = g_tune_lut[b];

    /* Saturation mix around Rec.601 luma (Q8). */
    int sat = g_tune_sat_q8;
    if (sat != 256) {
        int lum = (ri * 54 + gi * 183 + bi * 19) >> 8;
        ri = lum + (((ri - lum) * sat) >> 8);
        gi = lum + (((gi - lum) * sat) >> 8);
        bi = lum + (((bi - lum) * sat) >> 8);
        ri = clamp_u8(ri); gi = clamp_u8(gi); bi = clamp_u8(bi);
    }
    return 0xFF000000 | ((uint32_t)bi << 16) | ((uint32_t)gi << 8) | (uint32_t)ri;
}

static inline uint32_t apply_gb_palette(uint8_t r, uint8_t g, uint8_t b) {
    int lum = (r * 2 + g * 5 + b) >> 3;
    if (lum >= 192) return g_palette_colors[0];
    else if (lum >= 128) return g_palette_colors[1];
    else if (lum >= 64)  return g_palette_colors[2];
    else                 return g_palette_colors[3];
}

static inline uint32_t process_pixel(uint8_t r, uint8_t g, uint8_t b) {
    if (g_palette_enabled)  return apply_gb_palette(r, g, b);
    if (g_tune_active)      return apply_color_correction(r, g, b);
    return 0xFF000000 | ((uint32_t)b << 16) | ((uint32_t)g << 8) | (uint32_t)r;
}

/* ── Fast XRGB8888 → ABGR8888 row converter ──────────────────────────────
 *
 * Used when neither the GB-family colour-correction boost nor the GB palette
 * remap is active (e.g. NDS, N64, SNES on most cores). Avoids the per-pixel
 * function-call / branch overhead in `process_pixel`.
 *
 * Input  pixel layout: 0xXXRRGGBB (little-endian bytes:  B G R X)
 * Output pixel layout: 0xFFBBGGRR (little-endian bytes:  R G B A)
 *
 * The transform per 32-bit word is:
 *   out = 0xFF000000 | (in & 0x0000FF00)
 *                    | ((in & 0x00FF0000) >> 16)
 *                    | ((in & 0x000000FF) << 16)
 *
 * Hot loop is 4× unrolled so the compiler can keep the masks in registers
 * across iterations and saturate dual-issue on the ARMv8 cores typical of
 * Android TV / budget phones.  On an Android-TV class Cortex-A53 this is
 * ~3× faster than going through `process_pixel` per pixel.
 */
static inline void convert_xrgb_row_to_abgr(uint32_t* dst,
                                             const uint32_t* src,
                                             unsigned count) {
    unsigned x = 0;
    for (; x + 4 <= count; x += 4) {
        uint32_t p0 = src[x + 0];
        uint32_t p1 = src[x + 1];
        uint32_t p2 = src[x + 2];
        uint32_t p3 = src[x + 3];
        dst[x + 0] = 0xFF000000u | (p0 & 0x0000FF00u) | ((p0 & 0x00FF0000u) >> 16) | ((p0 & 0x000000FFu) << 16);
        dst[x + 1] = 0xFF000000u | (p1 & 0x0000FF00u) | ((p1 & 0x00FF0000u) >> 16) | ((p1 & 0x000000FFu) << 16);
        dst[x + 2] = 0xFF000000u | (p2 & 0x0000FF00u) | ((p2 & 0x00FF0000u) >> 16) | ((p2 & 0x000000FFu) << 16);
        dst[x + 3] = 0xFF000000u | (p3 & 0x0000FF00u) | ((p3 & 0x00FF0000u) >> 16) | ((p3 & 0x000000FFu) << 16);
    }
    for (; x < count; x++) {
        uint32_t p = src[x];
        dst[x] = 0xFF000000u | (p & 0x0000FF00u) | ((p & 0x00FF0000u) >> 16) | ((p & 0x000000FFu) << 16);
    }
}

/* ══════════════════════════════════════════════════════════════════════
 * video_refresh_callback — libretro contract
 * ══════════════════════════════════════════════════════════════════════ */

void video_refresh_callback(const void* data, unsigned width,
                             unsigned height, size_t pitch) {
    if (!g_video_buffer) return;

    if (data == RETRO_HW_FRAME_BUFFER_VALID) {
        g_width  = (int)width;
        g_height = (int)height;
        g_video_frames_total++;

        size_t needed = (size_t)width * height;
        if (needed > g_video_buffer_capacity) {
            uint32_t* new_buf = (uint32_t*)realloc(g_video_buffer,
                                                    needed * sizeof(uint32_t));
            if (!new_buf) {
                LOGE("HW frame: failed to reallocate video buffer for %ux%u", width, height);
                return;
            }
            g_video_buffer = new_buf;
            g_video_buffer_capacity = needed;
        }

#ifdef __ANDROID__
        if (hw_render_readback(width, height, g_video_buffer) != 0 &&
            g_log_frame_count < 20) {
            LOGE("HW frame readback failed (%ux%u)", width, height);
            g_log_frame_count++;
        }
#endif
        return;
    }

    if (!data) return;

    g_width  = (int)width;
    g_height = (int)height;
    g_video_frames_total++;

    if (g_log_frame_count < 5) {
        const uint8_t* raw = (const uint8_t*)data;
        uint32_t p0 = 0, pM = 0;
        if (g_pixel_format == RETRO_PIXEL_FORMAT_XRGB8888 && pitch >= 4) {
            p0 = *(const uint32_t*)(raw);
            pM = *(const uint32_t*)(raw + (height / 2) * pitch + (width / 2) * 4);
        }
        LOGI("Video: %ux%u, pitch=%zu, format=%d, px[0,0]=0x%08X, px[mid]=0x%08X",
             width, height, pitch, g_pixel_format, p0, pM);
        g_log_frame_count++;
    }

    size_t needed = (size_t)width * height;
    if (needed > g_video_buffer_capacity) {
        uint32_t* new_buf = (uint32_t*)realloc(g_video_buffer,
                                                needed * sizeof(uint32_t));
        if (!new_buf) {
            LOGE("Failed to reallocate video buffer for %ux%u", width, height);
            return;
        }
        g_video_buffer = new_buf;
        g_video_buffer_capacity = needed;
        LOGI("Video buffer reallocated for %ux%u (%zu pixels)", width, height, needed);
    }

    if (g_pixel_format == RETRO_PIXEL_FORMAT_XRGB8888) {
        const uint8_t* src = (const uint8_t*)data;
        const int fast_path = !g_palette_enabled && !g_tune_active;
        if (fast_path) {
            /* Hot path for NDS / N64 / most modern cores: no palette remap,
             * no GB contrast boost — straight XRGB → ABGR with an unrolled
             * row converter.  Roughly 3× cheaper than the per-pixel path. */
            for (unsigned y = 0; y < height; y++) {
                const uint32_t* row = (const uint32_t*)(src + y * pitch);
                convert_xrgb_row_to_abgr(g_video_buffer + (size_t)y * width,
                                         row, width);
            }
        } else {
            for (unsigned y = 0; y < height; y++) {
                const uint32_t* row = (const uint32_t*)(src + y * pitch);
                for (unsigned x = 0; x < width; x++) {
                    uint32_t pixel = row[x];
                    g_video_buffer[y * width + x] = process_pixel(
                        (pixel >> 16) & 0xFF, (pixel >> 8) & 0xFF, pixel & 0xFF);
                }
            }
        }
    } else if (g_pixel_format == RETRO_PIXEL_FORMAT_RGB565) {
        const uint8_t* src = (const uint8_t*)data;
        for (unsigned y = 0; y < height; y++) {
            const uint16_t* row = (const uint16_t*)(src + y * pitch);
            for (unsigned x = 0; x < width; x++) {
                uint16_t p = row[x];
                uint8_t r = (p >> 11) & 0x1F; r = (r << 3) | (r >> 2);
                uint8_t g = (p >>  5) & 0x3F; g = (g << 2) | (g >> 4);
                uint8_t b =  p        & 0x1F; b = (b << 3) | (b >> 2);
                g_video_buffer[y * width + x] = process_pixel(r, g, b);
            }
        }
    } else if (g_pixel_format == RETRO_PIXEL_FORMAT_0RGB1555) {
        const uint8_t* src = (const uint8_t*)data;
        for (unsigned y = 0; y < height; y++) {
            const uint16_t* row = (const uint16_t*)(src + y * pitch);
            for (unsigned x = 0; x < width; x++) {
                uint16_t p = row[x];
                uint8_t r = (p >> 10) & 0x1F; r = (r << 3) | (r >> 2);
                uint8_t g = (p >>  5) & 0x1F; g = (g << 3) | (g >> 2);
                uint8_t b =  p        & 0x1F; b = (b << 3) | (b >> 2);
                g_video_buffer[y * width + x] = process_pixel(r, g, b);
            }
        }
    } else {
        LOGI("Unknown pixel format %d, trying auto-detect", g_pixel_format);
        if (pitch >= width * 4) {
            const uint8_t* src = (const uint8_t*)data;
            for (unsigned y = 0; y < height; y++) {
                const uint32_t* row = (const uint32_t*)(src + y * pitch);
                for (unsigned x = 0; x < width; x++) {
                    uint32_t pixel = row[x];
                    g_video_buffer[y * width + x] = process_pixel(
                        (pixel >> 16) & 0xFF, (pixel >> 8) & 0xFF, pixel & 0xFF);
                }
            }
        } else {
            const uint8_t* src = (const uint8_t*)data;
            for (unsigned y = 0; y < height; y++) {
                const uint16_t* row = (const uint16_t*)(src + y * pitch);
                for (unsigned x = 0; x < width; x++) {
                    uint16_t p = row[x];
                    uint8_t r = (p >> 11) & 0x1F; r = (r << 3) | (r >> 2);
                    uint8_t g = (p >>  5) & 0x3F; g = (g << 2) | (g >> 4);
                    uint8_t b =  p        & 0x1F; b = (b << 3) | (b >> 2);
                    g_video_buffer[y * width + x] = process_pixel(r, g, b);
                }
            }
        }
    }
}

/* ══════════════════════════════════════════════════════════════════════
 * ANativeWindow blit + JNI surface management (Android only)
 * ══════════════════════════════════════════════════════════════════════ */

#ifdef __ANDROID__

/* ── Display-FX scratch buffers (Android blit path) ────────────────────
 * Reallocated on demand and freed in nativeReleaseSurface. */
static uint32_t* g_fx_src   = NULL; static size_t g_fx_src_cap   = 0; /* w×h     */
static uint32_t* g_fx_prev  = NULL; static size_t g_fx_prev_cap  = 0; /* w×h     */
static uint32_t* g_fx_2x    = NULL; static size_t g_fx_2x_cap    = 0; /* 2w×2h   */
static uint32_t* g_fx_3x    = NULL; static size_t g_fx_3x_cap    = 0; /* 3w×3h   */
static int       g_fx_prev_w = 0;   /* dims the ghost prev-frame was stored at */
static int       g_fx_prev_h = 0;

static int fx_ensure_cap(uint32_t** buf, size_t* cap, size_t need) {
    if (*buf && *cap >= need) return 1;
    uint32_t* nb = (uint32_t*)realloc(*buf, need * sizeof(uint32_t));
    if (!nb) return 0;
    *buf = nb; *cap = need;
    return 1;
}

/* Source-domain effects (NTSC composite blend, then LCD ghosting), both at
 * native w×h. Returns the effective source: g_video_buffer untouched when
 * neither is enabled, otherwise g_fx_src. Pixels are ABGR8888
 * (r=bits0-7, g=8-15, b=16-23, a=24-31). */
static const uint32_t* fx_prepare_source(const uint32_t* in, int w, int h) {
    const int doN = g_fx_ntsc  > 0;
    const int doG = g_fx_ghost > 0;
    if (!doN && !doG) return in;
    const size_t n = (size_t)w * (size_t)h;
    if (!fx_ensure_cap(&g_fx_src, &g_fx_src_cap, n)) return in;

    /* Stage A — composite horizontal blend (merges dithering, softens chroma). */
    if (doN) {
        const int t = g_fx_ntsc;
        for (int y = 0; y < h; y++) {
            const uint32_t* row = in + (size_t)y * w;
            uint32_t* o = g_fx_src + (size_t)y * w;
            for (int x = 0; x < w; x++) {
                const uint32_t C = row[x];
                const uint32_t L = (x > 0)     ? row[x - 1] : C;
                const uint32_t R = (x < w - 1) ? row[x + 1] : C;
                const int cr = C & 0xFF, cg = (C >> 8) & 0xFF, cb = (C >> 16) & 0xFF;
                const int br = (((int)(L & 0xFF))         + 2 * cr + ((int)(R & 0xFF)))         >> 2;
                const int bg = (((int)((L >> 8) & 0xFF))  + 2 * cg + ((int)((R >> 8) & 0xFF)))  >> 2;
                const int bb = (((int)((L >> 16) & 0xFF)) + 2 * cb + ((int)((R >> 16) & 0xFF))) >> 2;
                const int orr = (cr * (100 - t) + br * t) / 100;
                const int og  = (cg * (100 - t) + bg * t) / 100;
                const int ob  = (cb * (100 - t) + bb * t) / 100;
                o[x] = 0xFF000000u | ((uint32_t)ob << 16) | ((uint32_t)og << 8) | (uint32_t)orr;
            }
        }
    } else {
        memcpy(g_fx_src, in, n * sizeof(uint32_t));
    }

    /* Stage B — LCD ghosting (blend with the previous displayed frame). */
    if (doG) {
        const int g = g_fx_ghost;
        const int havePrev = g_fx_prev_valid && g_fx_prev &&
                             g_fx_prev_w == w && g_fx_prev_h == h &&
                             g_fx_prev_cap >= n;
        if (havePrev) {
            for (size_t i = 0; i < n; i++) {
                const uint32_t C = g_fx_src[i], P = g_fx_prev[i];
                const int cr = C & 0xFF, cg = (C >> 8) & 0xFF, cb = (C >> 16) & 0xFF;
                const int pr = P & 0xFF, pg = (P >> 8) & 0xFF, pb = (P >> 16) & 0xFF;
                const int orr = (cr * (100 - g) + pr * g) / 100;
                const int og  = (cg * (100 - g) + pg * g) / 100;
                const int ob  = (cb * (100 - g) + pb * g) / 100;
                g_fx_src[i] = 0xFF000000u | ((uint32_t)ob << 16) | ((uint32_t)og << 8) | (uint32_t)orr;
            }
        }
        /* Persist the (blended) current frame for next time. */
        if (fx_ensure_cap(&g_fx_prev, &g_fx_prev_cap, n)) {
            memcpy(g_fx_prev, g_fx_src, n * sizeof(uint32_t));
            g_fx_prev_w = w; g_fx_prev_h = h; g_fx_prev_valid = 1;
        } else {
            g_fx_prev_valid = 0;
        }
    }
    return g_fx_src;
}

/* Scale2x / EPX edge-aware 2× expansion (rounds the pixel-art staircase).
 * out must hold 2w×2h pixels. Out-of-bounds neighbours fall back to the
 * centre pixel, which simply disables the rule at the image border. */
static void fx_scale2x(const uint32_t* in, int w, int h, uint32_t* out) {
    const int ow = w * 2;
    for (int y = 0; y < h; y++) {
        const uint32_t* r  = in + (size_t)y * w;
        const uint32_t* ru = (y > 0)     ? in + (size_t)(y - 1) * w : r;
        const uint32_t* rd = (y < h - 1) ? in + (size_t)(y + 1) * w : r;
        uint32_t* o0 = out + (size_t)(2 * y)     * ow;
        uint32_t* o1 = out + (size_t)(2 * y + 1) * ow;
        for (int x = 0; x < w; x++) {
            const uint32_t P = r[x];
            const uint32_t A = ru[x];                       /* up    */
            const uint32_t D = rd[x];                       /* down  */
            const uint32_t C = (x > 0)     ? r[x - 1] : P;  /* left  */
            const uint32_t B = (x < w - 1) ? r[x + 1] : P;  /* right */
            uint32_t E0 = P, E1 = P, E2 = P, E3 = P;
            if (C == A && C != D && A != B) E0 = A;
            if (A == B && A != C && B != D) E1 = B;
            if (D == C && D != B && C != A) E2 = C;
            if (B == D && B != A && D != C) E3 = D;
            o0[2 * x] = E0; o0[2 * x + 1] = E1;
            o1[2 * x] = E2; o1[2 * x + 1] = E3;
        }
    }
}

/* Scale3x / EPX 3× expansion — sharper than Scale2x (more intermediate
 * pixels per edge, so the GPU bicubic finishes a smaller ~scale/3 residual)
 * while still rounding the pixel-art staircase. out must hold 3w×3h pixels.
 * Canonical Scale3x rules; out-of-bounds neighbours clamp to the edge. */
static void fx_scale3x(const uint32_t* in, int w, int h, uint32_t* out) {
    const int ow = w * 3;
    for (int y = 0; y < h; y++) {
        const uint32_t* r  = in + (size_t)y * w;
        const uint32_t* ru = (y > 0)     ? in + (size_t)(y - 1) * w : r;
        const uint32_t* rd = (y < h - 1) ? in + (size_t)(y + 1) * w : r;
        uint32_t* o0 = out + (size_t)(3 * y)     * ow;
        uint32_t* o1 = out + (size_t)(3 * y + 1) * ow;
        uint32_t* o2 = out + (size_t)(3 * y + 2) * ow;
        for (int x = 0; x < w; x++) {
            const int xl = (x > 0)     ? x - 1 : x;
            const int xr = (x < w - 1) ? x + 1 : x;
            const uint32_t A = ru[xl], B = ru[x], C = ru[xr];
            const uint32_t D = r[xl],  E = r[x],  F = r[xr];
            const uint32_t G = rd[xl], H = rd[x], I = rd[xr];
            uint32_t e0 = E, e1 = E, e2 = E,
                     e3 = E, e4 = E, e5 = E,
                     e6 = E, e7 = E, e8 = E;
            if (B != H && D != F) {
                if (D == B)                                  e0 = D;
                if ((D == B && E != C) || (B == F && E != A)) e1 = B;
                if (B == F)                                  e2 = F;
                if ((D == B && E != G) || (D == H && E != A)) e3 = D;
                if ((B == F && E != I) || (H == F && E != C)) e5 = F;
                if (D == H)                                  e6 = D;
                if ((D == H && E != I) || (H == F && E != G)) e7 = H;
                if (H == F)                                  e8 = F;
            }
            o0[3 * x] = e0; o0[3 * x + 1] = e1; o0[3 * x + 2] = e2;
            o1[3 * x] = e3; o1[3 * x + 1] = e4; o1[3 * x + 2] = e5;
            o2[3 * x] = e6; o2[3 * x + 1] = e7; o2[3 * x + 2] = e8;
        }
    }
}

/* Output-domain overlay: console scanlines and/or handheld LCD grid.
 * `period` = output pixels per ORIGINAL source pixel, so one dark line lands
 * per source scanline. Pixels are darkened to (100-intensity)% on the line. */
static void fx_apply_overlay(uint32_t* dst, int dw, int dh, int stride, int period) {
    if (period < 3) return;   /* too few px/cell to draw a line without aliasing */
    const int scan = g_fx_scanline;
    const int grid = g_fx_lcdgrid;
    if (!scan && !grid) return;
    const int lineI    = scan ? scan : grid;
    const int rowDarkQ8 = (256 * (100 - lineI)) / 100;
    const int colDarkQ8 = grid ? (256 * (100 - grid)) / 100 : 256;
    for (int oy = 0; oy < dh; oy++) {
        const int rowLine = ((oy % period) == period - 1);
        const int rf = rowLine ? rowDarkQ8 : 256;
        /* Scanline-only: untouched rows can be skipped entirely. */
        if (!grid && rf == 256) continue;
        uint32_t* o = dst + (size_t)oy * stride;
        for (int ox = 0; ox < dw; ox++) {
            int cf = 256;
            if (grid && (ox % period) == period - 1) cf = colDarkQ8;
            const int f = (rf * cf) >> 8;
            if (f >= 256) continue;
            const uint32_t v = o[ox];
            int rr = v & 0xFF, gg = (v >> 8) & 0xFF, bb = (v >> 16) & 0xFF;
            rr = (rr * f) >> 8; gg = (gg * f) >> 8; bb = (bb * f) >> 8;
            o[ox] = 0xFF000000u | ((uint32_t)bb << 16) | ((uint32_t)gg << 8) | (uint32_t)rr;
        }
    }
}

/* ── Auto sharp-bilinear: pick the scaling base nearest the Dart target ──
 * Given the Dart TARGET total cpu expansion and whether a Scale3x surface
 * fits the per-frame pixel budget, choose the base whose nearest realizable
 * total lands closest to the target:
 *   * base 3 → Scale3x (× round(target/3))   — finest edge-aware rounding
 *   * base 2 → Scale2x (× round(target/2))   — edge-aware, even totals
 *   * base 1 → pure nearest (× target)        — hits any total exactly; the
 *               natural "toward pixel" end (no edge-aware smoothing), and it
 *               dominates as the target approaches the full scale.
 * The caller runs the chosen scaler (none for base 1) then round(target/base)
 * hard-nearest passes, so total ≈ target and the GPU bicubic finishes only
 * the small residual (≈ scale/target).
 *
 * Ties prefer the LARGER base (keep edge-aware smoothing unless pure-nearest
 * is strictly closer). Never drops below a single Scale3x when it fits — the
 * Auto floor: no blur regression, and TV (whose target is small) is unchanged.
 *
 * round(target/b) is computed as (target + 1) / b, which == lround(target/b)
 * for all integer targets (b ∈ {2,3} never hit an exact .5). */
static int choose_art_base(int target, int fits3) {
    if (target < 1) target = 1;
    int best_base = 1, best_tot = target;          /* base 1: total == target */
    int best_d = 0;
    const int n2 = (target + 1) / 2;               /* round(target/2), >=1 */
    const int t2 = 2 * n2;
    const int d2 = t2 > target ? t2 - target : target - t2;
    if (d2 < best_d || (d2 == best_d && 2 > best_base)) {
        best_base = 2; best_tot = t2; best_d = d2;
    }
    if (fits3) {
        const int n3 = (target + 1) / 3;           /* round(target/3), >=1 */
        const int t3 = 3 * n3;
        const int d3 = t3 > target ? t3 - target : target - t3;
        if (d3 < best_d || (d3 == best_d && 3 > best_base)) {
            best_base = 3; best_tot = t3; best_d = d3;
        }
    }
    if (best_tot < 3 && fits3) return 3;           /* floor: one Scale3x */
    return best_base;
}

int blit_to_native_window(void) {
    if (g_hw_render_enabled && hw_render_is_direct_present()) {
        return 0;
    }

    pthread_mutex_lock(&g_nw_mutex);
    ANativeWindow* win = g_native_window;
    if (!win || !g_video_buffer) {
        pthread_mutex_unlock(&g_nw_mutex);
        return -1;
    }

    int w = g_width;
    int h = g_height;
    if (w <= 0 || h <= 0) {
        pthread_mutex_unlock(&g_nw_mutex);
        return -1;
    }

    /* ── Per-system display FX: source-domain stage (NTSC + ghosting) ──
     * Produces the effective source (still native ew×eh). With FX inactive
     * `eff` is g_video_buffer and ew/eh = w/h, so everything below is the
     * original fast path, byte-identical to before. */
    const uint32_t* eff = g_video_buffer;
    int ew = w, eh = h;
    int artMul = 1;                 /* output px per source px from art stage */
    if (g_fx_active) {
        eff = fx_prepare_source(g_video_buffer, w, h);
        if (g_fx_artscale) {
            /* Auto "toward pixel" sharp-bilinear: realize the Dart TARGET total
             * cpu expansion (g_prescale_factor ≈ 0.70 × on-screen scale) as an
             * edge-aware base × hard-nearest passes, so the GPU bicubic finishes
             * only a small residual (≈ scale/target, ~1.3–1.6×). choose_art_base
             * picks the base whose nearest total lands closest to the target:
             * Scale3x for finest rounding (NES/SNES at target 3 → ×3), Scale2x
             * for even totals, or pure nearest (base 1, NO art scaler) when it
             * hits the target exactly — the "more pixel" end, e.g. a 240×160 GBA
             * at target 5 → nearest ×5. Pure nearest naturally takes over as the
             * target approaches the full scale (→ pixel-perfect). */
            const int fits3 =
                ((size_t)w * 3 * (size_t)h * 3 <= (size_t)PRESCALE_MAX_PIXELS);
            const int base = choose_art_base(g_prescale_factor, fits3);
            if (base == 3 &&
                fx_ensure_cap(&g_fx_3x, &g_fx_3x_cap,
                              (size_t)w * 3 * (size_t)h * 3)) {
                fx_scale3x(eff, w, h, g_fx_3x);
                eff = g_fx_3x; ew = w * 3; eh = h * 3; artMul = 3;
            } else if (base >= 2 &&
                       fx_ensure_cap(&g_fx_2x, &g_fx_2x_cap,
                                     (size_t)w * 2 * (size_t)h * 2)) {
                fx_scale2x(eff, w, h, g_fx_2x);
                eff = g_fx_2x; ew = w * 2; eh = h * 2; artMul = 2;
            }
            /* base == 1 (or an art alloc failed): no edge-aware pass — the
             * nearest stage below expands the raw source by the full target. */
        }
    }

    /* ── Sharp-bilinear stage: integer prescale on the effective source ──
     * base 1 / art OFF: the target total IS the nearest factor N. art base ≥2:
     * the art stage already produced artMul×, so add round(target/artMul)
     * nearest passes — total = artMul × N ≈ target. N is recomputed from the
     * artMul that ACTUALLY ran, so a Scale3x→Scale2x budget fallback adapts.
     * The budget-clamp below stops a large framebuffer from exploding per-frame
     * CPU. round(t/b) == (t + 1) / b for b ∈ {2,3} (see choose_art_base). */
    int N = g_prescale_factor;
    if (artMul >= 2) {
        N = (g_prescale_factor + 1) / artMul;   /* round(target / artMul), ≥1 */
        if (N < 1) N = 1;
    }
    if (N < 1) N = 1;
    while (N > 1 && (size_t)ew * N * (size_t)eh * N > (size_t)PRESCALE_MAX_PIXELS) {
        N--;
    }
    if (N > 1) {
        size_t need = (size_t)ew * N;
        if (need > g_prescale_row_cap) {
            uint32_t* nr = (uint32_t*)realloc(g_prescale_row,
                                              need * sizeof(uint32_t));
            if (nr) {
                g_prescale_row     = nr;
                g_prescale_row_cap = need;
            } else {
                N = 1;
            }
        }
    }
    const int dw = ew * N;
    const int dh = eh * N;
    const int fxPeriod = artMul * N;   /* output px per ORIGINAL source px */

    if (dw != g_nw_configured_w || dh != g_nw_configured_h) {
        ANativeWindow_setBuffersGeometry(win, dw, dh, WINDOW_FORMAT_RGBA_8888);
        g_nw_configured_w = dw;
        g_nw_configured_h = dh;
        LOGI("ANativeWindow geometry set to %dx%d (eff %dx%d, prescale %dx, fx=%d)",
             dw, dh, ew, eh, N, g_fx_active);
    }

    ANativeWindow_Buffer buf;
    if (ANativeWindow_lock(win, &buf, NULL) != 0) {
        pthread_mutex_unlock(&g_nw_mutex);
        return -1;
    }

    uint32_t* dst = (uint32_t*)buf.bits;

    if (N == 1) {
        if (buf.stride == ew) {
            memcpy(dst, eff, (size_t)ew * eh * sizeof(uint32_t));
        } else {
            for (int y = 0; y < eh; y++) {
                memcpy(dst + (size_t)y * buf.stride, eff + (size_t)y * ew,
                       (size_t)ew * sizeof(uint32_t));
            }
        }
    } else {
        /* Nearest N× expansion: build each output row once in the scratch
         * buffer, then memcpy it to the N identical destination rows
         * (stride-aware).  Hard pixel edges are preserved; the GPU's
         * smooth sampler only covers the remaining fractional stretch. */
        for (int y = 0; y < eh; y++) {
            const uint32_t* srow = eff + (size_t)y * ew;
            uint32_t* rb = g_prescale_row;
            for (int x = 0; x < ew; x++) {
                const uint32_t v = srow[x];
                for (int i = 0; i < N; i++) {
                    *rb++ = v;
                }
            }
            for (int i = 0; i < N; i++) {
                memcpy(dst + ((size_t)y * N + i) * buf.stride,
                       g_prescale_row, (size_t)dw * sizeof(uint32_t));
            }
        }
    }

    /* ── Output-domain FX overlay (scanlines / LCD grid) ── */
    if (g_fx_active && (g_fx_scanline || g_fx_lcdgrid)) {
        fx_apply_overlay(dst, dw, dh, (int)buf.stride, fxPeriod);
    }

    if (g_blit_diag_count < 3) {
        LOGI("Blit #%d: eff %dx%d→%dx%d (N=%d art=%d) stride=%d eff[0]=0x%08X dst[0]=0x%08X",
             g_blit_diag_count, ew, eh, dw, dh, N, artMul, (int)buf.stride,
             eff[0], dst[0]);
        g_blit_diag_count++;
    }

    ANativeWindow_unlockAndPost(win);
    pthread_mutex_unlock(&g_nw_mutex);
    return 0;
}

JNIEXPORT void JNICALL
Java_com_yourmateapps_retropal_YageTextureBridge_nativeSetSurface(
        JNIEnv* env, jclass clazz, jobject surface) {
    (void)clazz;

    pthread_mutex_lock(&g_nw_mutex);
    if (g_native_window) {
        ANativeWindow_release(g_native_window);
        g_native_window   = NULL;
        g_nw_configured_w = 0;
        g_nw_configured_h = 0;
    }

    if (surface) {
        g_native_window = ANativeWindow_fromSurface(env, surface);
        g_blit_diag_count = 0;
        if (g_native_window) {
            ANativeWindow_setBuffersGeometry(
                g_native_window, g_width, g_height, WINDOW_FORMAT_RGBA_8888);
            g_nw_configured_w = g_width;
            g_nw_configured_h = g_height;
            LOGI("ANativeWindow attached (%dx%d)", g_width, g_height);
        } else {
            LOGE("ANativeWindow_fromSurface returned NULL");
        }
    }
    pthread_mutex_unlock(&g_nw_mutex);
}

JNIEXPORT void JNICALL
Java_com_yourmateapps_retropal_YageTextureBridge_nativeReleaseSurface(
        JNIEnv* env, jclass clazz) {
    (void)env; (void)clazz;

    pthread_mutex_lock(&g_nw_mutex);
    if (g_native_window) {
        ANativeWindow* old = g_native_window;
        g_native_window   = NULL;
        g_nw_configured_w = 0;
        g_nw_configured_h = 0;
        /* Free the prescale row + display-FX scratch (reallocated on demand). */
        free(g_prescale_row);
        g_prescale_row     = NULL;
        g_prescale_row_cap = 0;
        free(g_fx_src);  g_fx_src  = NULL; g_fx_src_cap  = 0;
        free(g_fx_prev); g_fx_prev = NULL; g_fx_prev_cap = 0;
        free(g_fx_2x);   g_fx_2x   = NULL; g_fx_2x_cap   = 0;
        free(g_fx_3x);   g_fx_3x   = NULL; g_fx_3x_cap   = 0;
        g_fx_prev_valid = 0; g_fx_prev_w = 0; g_fx_prev_h = 0;
        pthread_mutex_unlock(&g_nw_mutex);
        ANativeWindow_release(old);
        LOGI("ANativeWindow released");
    } else {
        pthread_mutex_unlock(&g_nw_mutex);
    }
}

#endif /* __ANDROID__ */

/* ── Flutter Texture API ─────────────────────────────────────────────── */

YAGE_API int yage_texture_blit(YageCore* core) {
    (void)core;
#ifdef __ANDROID__
    return blit_to_native_window();
#else
    return -1;
#endif
}

YAGE_API int32_t yage_texture_is_attached(YageCore* core) {
    (void)core;
#ifdef __ANDROID__
    return g_native_window != NULL ? 1 : 0;
#else
    return 0;
#endif
}
