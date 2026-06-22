/*
 * YAGE Frame Loop Module
 *
 * Native POSIX frame-loop thread for ~60 Hz emulation timing.
 * Handles:
 *   - nanosleep-based frame pacing (speed-adjustable, 25%–800%)
 *   - Rewind capture integration
 *   - RetroAchievements per-frame evaluation hook
 *   - Display buffer snapshot for Dart-side pixel access
 *   - ANativeWindow blit (preferred zero-copy path on Android)
 *   - FPS counter (atomic, readable from Dart)
 *   - Windows stubs (symbols must exist for the linker)
 */

/* _GNU_SOURCE must be defined before any system header to expose
 * cpu_set_t, CPU_ZERO/SET, CPU_SETSIZE, and sched_setaffinity on bionic. */
#ifdef __ANDROID__
#  ifndef _GNU_SOURCE
#    define _GNU_SOURCE
#  endif
#  include <sched.h>
#  include <signal.h>
#  include <sys/resource.h>
#  include <sys/syscall.h>
#  include <sys/prctl.h>
#  include <ucontext.h>
#  include <unistd.h>
#endif

#include "yage_internal.h"

#ifndef _WIN32

#ifdef __ANDROID__

#if defined(__arm__)
#  ifndef PR_SET_UNALIGN
#    define PR_SET_UNALIGN 6
#  endif
#  ifndef PR_UNALIGN_NOPRINT
#    define PR_UNALIGN_NOPRINT 1
#  endif

/* Some 32-bit ARM Android TV kernels SIGBUS on unaligned multi-word stores
 * emitted by older libretro cores (observed in Genesis Plus GX at
 * pc=0x20fadc: stm r4, {r2, r5}). Ask the kernel to fix alignment traps for
 * this emulation thread so a core renderer bug cannot kill the whole app.
 * This is thread-local on Linux, so it must run inside frame_loop_thread(). */
static void enable_arm_unaligned_fixups(void) {
    errno = 0;
    if (prctl(PR_SET_UNALIGN, PR_UNALIGN_NOPRINT, 0, 0, 0) == 0) {
        LOGI("Frame loop: ARM unaligned access fixups enabled");
    } else {
        LOGI("Frame loop: ARM unaligned access fixups unavailable (errno=%d: %s)",
             errno, strerror(errno));
    }
}

static volatile sig_atomic_t g_arm_genesis_sigbus_enabled = 0;
static volatile sig_atomic_t g_arm_genesis_sigbus_fixups  = 0;
static struct sigaction      g_prev_sigbus_action;
static int                   g_sigbus_handler_installed  = 0;

static void chain_or_reraise_sigbus(int sig, siginfo_t* info, void* uctx) {
    if ((g_prev_sigbus_action.sa_flags & SA_SIGINFO) &&
        g_prev_sigbus_action.sa_sigaction &&
        g_prev_sigbus_action.sa_sigaction != SIG_DFL &&
        g_prev_sigbus_action.sa_sigaction != SIG_IGN) {
        g_prev_sigbus_action.sa_sigaction(sig, info, uctx);
        return;
    }

    if (g_prev_sigbus_action.sa_handler == SIG_IGN) {
        return;
    }

    if (g_prev_sigbus_action.sa_handler &&
        g_prev_sigbus_action.sa_handler != SIG_DFL) {
        g_prev_sigbus_action.sa_handler(sig);
        return;
    }

    sigaction(sig, &g_prev_sigbus_action, NULL);
    raise(sig);
}

/* General A32 unaligned load/store emulator.
 *
 * Some 32-bit ARM Android TV kernels (e.g. the Sony BRAVIA BF1) provide no
 * PR_SET_UNALIGN fixup (prctl returns EINVAL) and SIGBUS on the instruction
 * classes that trap on an unaligned base regardless of SCTLR.A:
 *   • LDM / STM  (multi-register block transfer)
 *   • LDRD / STRD (double-word transfer)
 * Prebuilt libretro cores such as Genesis Plus GX emit these from ordinary C
 * (e.g. a struct/array copy through an odd pointer), so a single hardcoded
 * instruction match is not enough — Road Rash 3 (Genesis) crashed on a
 * *different* instruction than the SMS/GG renderer's `stm r4,{r2,r5}`.
 *
 * This decodes the faulting instruction at pc and re-executes it with byte
 * accesses (which never trap), then advances pc. Single LDR/STR/LDRH are left
 * to the hardware — they work unaligned when SCTLR.A=0, which is the case on
 * these devices (otherwise far more code would fault). Only the unconditional
 * (AL) encodings are handled; that covers all compiler-generated copies.
 *
 * Async-signal-safe: touches only the trapped register file (in the
 * sigcontext), the faulting memory via byte ops, and the 4-aligned pc word
 * (always-valid executing code). No libc calls. Returns 1 if emulated.
 */
static int yage_arm_fixup_unaligned_a32(struct sigcontext* sc,
                                        const void* fault_addr) {
    uintptr_t pc = (uintptr_t)sc->arm_pc;
    if (pc == 0 || (pc & 3u)) return 0;          /* need a valid A32 pc        */
    if (sc->arm_cpsr & (1u << 5)) return 0;      /* Thumb (T bit) — not handled */

    const uint32_t insn = *((const uint32_t*)pc);
    if ((insn >> 28) != 0xEu) return 0;          /* only unconditional (AL)    */

    /* r0..r15 are contiguous in struct sigcontext (arm_r0..arm_r10, arm_fp,
     * arm_ip, arm_sp, arm_lr, arm_pc); index them as a flat array. */
    uint32_t* regs = (uint32_t*)&sc->arm_r0;
    const uintptr_t fa = (uintptr_t)fault_addr;

    /* ── LDM / STM : bits[27:25] == 0b100 ── */
    if (((insn >> 25) & 0x7u) == 0x4u) {
        const uint32_t P = (insn >> 24) & 1u;
        const uint32_t U = (insn >> 23) & 1u;
        const uint32_t S = (insn >> 22) & 1u;    /* banked/user regs — skip    */
        const uint32_t W = (insn >> 21) & 1u;
        const uint32_t L = (insn >> 20) & 1u;
        const uint32_t Rn = (insn >> 16) & 0xFu;
        const uint32_t list = insn & 0xFFFFu;
        if (S || list == 0u || Rn == 15u) return 0;

        const int count = __builtin_popcount(list);
        const uintptr_t base = regs[Rn];
        const uintptr_t start = U ? (base + (P ? 4u : 0u))
                                  : (base - 4u * (uint32_t)count + (P ? 0u : 4u));
        /* Decode sanity: the faulting address must lie inside the block. */
        if (fa < start || fa >= start + 4u * (uint32_t)count) return 0;

        uintptr_t cur = start;
        for (int i = 0; i < 16; i++) {
            if (!(list & (1u << i))) continue;
            volatile uint8_t* m = (volatile uint8_t*)cur;
            if (L) {
                regs[i] = (uint32_t)m[0] | ((uint32_t)m[1] << 8) |
                          ((uint32_t)m[2] << 16) | ((uint32_t)m[3] << 24);
            } else {
                const uint32_t v = regs[i];
                m[0] = (uint8_t)v;         m[1] = (uint8_t)(v >> 8);
                m[2] = (uint8_t)(v >> 16); m[3] = (uint8_t)(v >> 24);
            }
            cur += 4u;
        }
        if (W) regs[Rn] = (uint32_t)(U ? base + 4u * (uint32_t)count
                                       : base - 4u * (uint32_t)count);
        /* LDM with r15 in the list is a branch (e.g. function return). */
        if (L && (list & 0x8000u)) {
            const uint32_t npc = regs[15];
            if (npc & 1u) sc->arm_cpsr |= (1u << 5); else sc->arm_cpsr &= ~(1u << 5);
            sc->arm_pc = npc & ~1u;
        } else {
            sc->arm_pc += 4u;
        }
        g_arm_genesis_sigbus_fixups++;
        return 1;
    }

    /* ── LDRD / STRD : bits[27:25]==000, bits[7:4]==1101/1111, bit20==0 ──
     * (1101=LDRD, 1111=STRD; bit20=1 would be LDRSB/LDRSH — left to HW.) */
    {
        const uint32_t b2725 = (insn >> 25) & 0x7u;
        const uint32_t b74   = (insn >> 4) & 0xFu;
        if (b2725 == 0u && (b74 == 0xDu || b74 == 0xFu) &&
            ((insn >> 20) & 1u) == 0u) {
            const uint32_t P = (insn >> 24) & 1u;
            const uint32_t U = (insn >> 23) & 1u;
            const uint32_t I = (insn >> 22) & 1u;   /* 1 = immediate offset    */
            const uint32_t W = (insn >> 21) & 1u;
            const uint32_t Rn = (insn >> 16) & 0xFu;
            const uint32_t Rt = (insn >> 12) & 0xFu;
            const int isLoad = (b74 == 0xDu);
            if ((Rt & 1u) || Rt == 14u || Rn == 15u) return 0; /* need Rt,Rt+1 */

            uint32_t off;
            if (I) {
                off = (((insn >> 8) & 0xFu) << 4) | (insn & 0xFu);
            } else {
                const uint32_t Rm = insn & 0xFu;
                if (Rm == 15u) return 0;
                off = regs[Rm];
            }
            const uintptr_t base = regs[Rn];
            const uintptr_t addr = P ? (U ? base + off : base - off) : base;
            if (fa != addr && fa != addr + 4u) return 0;   /* decode sanity   */

            volatile uint8_t* m = (volatile uint8_t*)addr;
            if (isLoad) {
                regs[Rt]     = (uint32_t)m[0] | ((uint32_t)m[1] << 8) |
                               ((uint32_t)m[2] << 16) | ((uint32_t)m[3] << 24);
                regs[Rt + 1] = (uint32_t)m[4] | ((uint32_t)m[5] << 8) |
                               ((uint32_t)m[6] << 16) | ((uint32_t)m[7] << 24);
            } else {
                const uint32_t v0 = regs[Rt], v1 = regs[Rt + 1];
                m[0] = (uint8_t)v0;         m[1] = (uint8_t)(v0 >> 8);
                m[2] = (uint8_t)(v0 >> 16); m[3] = (uint8_t)(v0 >> 24);
                m[4] = (uint8_t)v1;         m[5] = (uint8_t)(v1 >> 8);
                m[6] = (uint8_t)(v1 >> 16); m[7] = (uint8_t)(v1 >> 24);
            }
            if (W || !P) {        /* pre-indexed writeback, or post-indexed    */
                regs[Rn] = (uint32_t)(P ? addr : (U ? base + off : base - off));
            }
            sc->arm_pc += 4u;
            g_arm_genesis_sigbus_fixups++;
            return 1;
        }
    }

    return 0;
}

static void yage_arm_sigbus_handler(int sig, siginfo_t* info, void* uctx) {
    if (sig == SIGBUS &&
        g_arm_genesis_sigbus_enabled &&
        info &&
        info->si_code == BUS_ADRALN &&
        uctx) {
        ucontext_t* uc = (ucontext_t*)uctx;
        struct sigcontext* sc = &uc->uc_mcontext;
        /* General decoder handles every unaligned LDM/STM + LDRD/STRD the
         * prebuilt core can emit (SMS/GG `stm r4,{r2,r5}`, Genesis Road Rash,
         * and any future offender) — not just one hardcoded encoding. */
        if (yage_arm_fixup_unaligned_a32(sc, info->si_addr)) {
            return;
        }
    }

    chain_or_reraise_sigbus(sig, info, uctx);
}

static void configure_arm_sigbus_alignment_handler(void) {
    /* Arm the fixup for EVERY core on 32-bit ARM, not just Genesis Plus GX.
     * The unaligned LDM/STM/LDRD/STRD fault is a property of the armv7 CPU
     * (these kernels offer no PR_SET_UNALIGN) plus how the prebuilt libretro
     * cores are compiled — Genesis Plus GX was simply the first one observed
     * crashing (SMS/GG renderer, then Genesis Road Rash), but any core can hit
     * it. The handler is safe to arm broadly: it only emulates a faulting
     * instruction it can fully decode as an unconditional block/dual transfer
     * whose computed address matches the trap address, and re-raises everything
     * else — so it cannot mask a genuine (non-alignment) crash. */
    g_arm_genesis_sigbus_enabled = 1;

    if (!g_sigbus_handler_installed) {
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        sigemptyset(&action.sa_mask);
        action.sa_sigaction = yage_arm_sigbus_handler;
        action.sa_flags = SA_SIGINFO | SA_NODEFER;
        if (sigaction(SIGBUS, &action, &g_prev_sigbus_action) == 0) {
            g_sigbus_handler_installed = 1;
            LOGI("Frame loop: ARM unaligned LDM/STM/LDRD/STRD SIGBUS handler installed");
        } else {
            LOGI("Frame loop: SIGBUS alignment handler install failed (errno=%d: %s)",
                 errno, strerror(errno));
        }
    } else {
        LOGI("Frame loop: ARM unaligned SIGBUS handler active");
    }
}
#else
static void enable_arm_unaligned_fixups(void) {}
static void configure_arm_sigbus_alignment_handler(void) {}
#endif

/* ── Big-core pinning ────────────────────────────────────────────────────
 * On big.LITTLE / DynamIQ SoCs (Cortex-A53/55 LITTLE + A75/A78/X1 big)
 * the Linux CFS scheduler does not reliably migrate a CPU-bound pthread to
 * a big core under sustained load.  Reading each CPU's advertised max
 * frequency from sysfs and calling sched_setaffinity() to restrict the
 * frame-loop thread to the fastest cluster can deliver 20–35 % more
 * throughput on heterogeneous Android TVs and phones.
 *
 * Strategy:
 *   1. Walk CPU0..CPU_SETSIZE-1; skip offline CPUs (sysfs entry missing).
 *   2. Record the highest max_freq seen across all online CPUs.
 *   3. Include every CPU whose max_freq >= 90 % of that peak (catches both
 *      prime and big cores while excluding all LITTLE cores).
 *   4. sched_setaffinity(0, ...) the calling thread.
 *   5. Any failure → return silently; emulation continues on any core.
 */
static void pin_to_big_cores(void) {
    unsigned long max_freqs[CPU_SETSIZE];
    int           num_cpus = 0;
    unsigned long peak_freq = 0;
    char          path[128];
    char          buf[32];

    for (int cpu = 0; cpu < CPU_SETSIZE; cpu++) {
        snprintf(path, sizeof(path),
                 "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", cpu);
        FILE* f = fopen(path, "r");
        if (!f) {
            /* Sysfs entry absent → this CPU index doesn't exist; stop scan. */
            if (cpu > 0) break;
            continue;
        }
        unsigned long freq = 0;
        if (fgets(buf, sizeof(buf), f)) {
            freq = strtoul(buf, NULL, 10);
        }
        fclose(f);
        max_freqs[cpu] = freq;
        if (freq > peak_freq) peak_freq = freq;
        num_cpus = cpu + 1;
    }

    if (peak_freq == 0 || num_cpus == 0) return;   /* no sysfs data */

    /* Allow all CPUs within 10 % of peak (avoids excluding prime core on
     * Snapdragon 8 Gen 1/2/3 where X3 runs slightly above the A710 cluster). */
    unsigned long threshold = peak_freq * 9 / 10;
    cpu_set_t big_set;
    CPU_ZERO(&big_set);
    int big_count = 0;
    for (int cpu = 0; cpu < num_cpus; cpu++) {
        if (max_freqs[cpu] >= threshold) {
            CPU_SET(cpu, &big_set);
            big_count++;
        }
    }
    if (big_count == 0) return;

    if (sched_setaffinity(0, sizeof(big_set), &big_set) == 0) {
        if (big_count == num_cpus) {
            /* All CPUs ≥ 90 % of peak — homogeneous SoC (e.g. 4×A55 on most
             * budget Android TVs / Mediatek phones).  Affinity restriction
             * is effectively a no-op; the kernel is already free to use
             * any core.  Log this loudly so it's clear from the field log
             * that we're CPU-bound on the actual cluster speed, not on the
             * scheduler picking a LITTLE core. */
            LOGI("Frame loop: homogeneous CPU detected (%d cores all @ ~%lu kHz); "
                 "big-core pin is a no-op on this device",
                 big_count, peak_freq);
        } else {
            LOGI("Frame loop: pinned to %d/%d big core(s) (peak=%lu kHz, threshold=%lu kHz)",
                 big_count, num_cpus, peak_freq, threshold);
        }
    }
    /* Failure (e.g. permission denied on some OEM kernels) → silent, no-op. */
}
#endif /* __ANDROID__ */

/* ── Frame loop globals ──────────────────────────────────────────────── */
int64_t        g_core_frame_ns       = DEFAULT_FRAME_NS;
uint32_t*      g_display_buf         = NULL;
size_t         g_display_buf_capacity = 0;
int            g_display_width        = 0;
int            g_display_height       = 0;
pthread_mutex_t g_display_mutex       = PTHREAD_MUTEX_INITIALIZER;

static pthread_t           g_frame_thread;
atomic_int                 g_floop_running       = 0;
atomic_int                 g_core_frames_total   = 0;
static atomic_int          g_floop_speed_pct     = 100;
static atomic_int          g_floop_rewind_on     = 0;
static atomic_int          g_floop_rewind_interval = 5;
static atomic_int          g_floop_rcheevos_on   = 0;
static atomic_int          g_floop_fps_x100      = 0;
/* Published per outer iteration so other modules (e.g. audio's elastic
 * playback-rate adaptation) can read a stable estimate of retro_run cost
 * without locking. Stored in microseconds to fit comfortably in int. */
atomic_int                 g_retro_run_ewma_us   = 0;
/* Set to 1 when the next retro_run should run with video rendering
 * suppressed (audio + CPU emulation still happen). Read by the env
 * callback's RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE handler. */
atomic_int                 g_floop_skip_video    = 0;
static yage_frame_callback_t g_frame_callback    = NULL;

/* ── Async GPU3D render worker (Phase 3) ─────────────────────────────
 * A dedicated pthread that can overlap GPU3D geometry/raster work with
 * the next frame's CPU emulation on the A53's spare cores.
 *
 * State machine: the worker blocks on g_render_cond waiting for work.
 * The frame loop posts work by setting g_render_pending=1 and signaling.
 * When done, the worker sets g_render_done=1 and signals g_render_done_cond.
 * The frame loop checks g_render_done before the next compositor pass.
 */
#ifdef __ANDROID__
static pthread_t       g_render_worker;
static pthread_mutex_t g_render_mutex    = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_render_cond     = PTHREAD_COND_INITIALIZER;
static pthread_cond_t  g_render_done_cond = PTHREAD_COND_INITIALIZER;
static atomic_int      g_render_worker_running = 0;
static atomic_int      g_render_pending        = 0;
static atomic_int      g_render_done           = 1;

typedef void (*render_work_fn)(void);
static render_work_fn  g_render_work_func = NULL;

static void* render_worker_thread(void* arg) {
    (void)arg;

    /* Pin to a different core from the frame loop if possible.
     * On homogeneous A53 quad-core, just pick core 2 or 3. */
    {
        cpu_set_t worker_set;
        CPU_ZERO(&worker_set);
        CPU_SET(2, &worker_set);
        CPU_SET(3, &worker_set);
        sched_setaffinity(0, sizeof(worker_set), &worker_set);
    }
    setpriority(PRIO_PROCESS, 0, -6);

    LOGI("Render worker thread started");

    while (atomic_load_explicit(&g_render_worker_running, memory_order_acquire)) {
        pthread_mutex_lock(&g_render_mutex);
        while (!atomic_load_explicit(&g_render_pending, memory_order_acquire) &&
               atomic_load_explicit(&g_render_worker_running, memory_order_acquire)) {
            pthread_cond_wait(&g_render_cond, &g_render_mutex);
        }
        pthread_mutex_unlock(&g_render_mutex);

        if (!atomic_load_explicit(&g_render_worker_running, memory_order_acquire))
            break;

        if (g_render_work_func)
            g_render_work_func();

        atomic_store_explicit(&g_render_pending, 0, memory_order_release);
        atomic_store_explicit(&g_render_done, 1, memory_order_release);

        pthread_mutex_lock(&g_render_mutex);
        pthread_cond_signal(&g_render_done_cond);
        pthread_mutex_unlock(&g_render_mutex);
    }

    /* M27: release the worker's shared EGL context from this thread before
     * it exits (hw_render_shutdown destroys the context later). */
    hw_render_worker_unbind();

    LOGI("Render worker thread exiting");
    return NULL;
}

static void render_worker_start(void) {
    if (atomic_load(&g_render_worker_running)) return;
    atomic_store_explicit(&g_render_worker_running, 1, memory_order_release);
    atomic_store_explicit(&g_render_done, 1, memory_order_release);
    atomic_store_explicit(&g_render_pending, 0, memory_order_release);
    pthread_create(&g_render_worker, NULL, render_worker_thread, NULL);
}

static void render_worker_stop(void) {
    if (!atomic_load(&g_render_worker_running)) return;
    atomic_store_explicit(&g_render_worker_running, 0, memory_order_release);
    pthread_mutex_lock(&g_render_mutex);
    pthread_cond_signal(&g_render_cond);
    pthread_mutex_unlock(&g_render_mutex);
    pthread_join(g_render_worker, NULL);

    /* Release any waiter stuck on a job the worker never picked up (the
     * frame thread is normally joined before this runs, so this is a
     * belt-and-braces unblock, not the expected path). */
    atomic_store_explicit(&g_render_pending, 0, memory_order_release);
    atomic_store_explicit(&g_render_done, 1, memory_order_release);
    pthread_mutex_lock(&g_render_mutex);
    pthread_cond_broadcast(&g_render_done_cond);
    pthread_mutex_unlock(&g_render_mutex);
}

static void render_worker_submit(render_work_fn fn) {
    /* Worker not running (startup race / shutdown): run inline. The caller's
     * thread holds a valid GL context in every M27 call path. */
    if (!atomic_load_explicit(&g_render_worker_running, memory_order_acquire)) {
        if (fn) fn();
        return;
    }

    /* Wait for any previous work to complete first. */
    pthread_mutex_lock(&g_render_mutex);
    while (!atomic_load_explicit(&g_render_done, memory_order_acquire))
        pthread_cond_wait(&g_render_done_cond, &g_render_mutex);
    pthread_mutex_unlock(&g_render_mutex);

    g_render_work_func = fn;
    atomic_store_explicit(&g_render_done, 0, memory_order_release);
    atomic_store_explicit(&g_render_pending, 1, memory_order_release);

    pthread_mutex_lock(&g_render_mutex);
    pthread_cond_signal(&g_render_cond);
    pthread_mutex_unlock(&g_render_mutex);
}

static void render_worker_wait(void) {
    pthread_mutex_lock(&g_render_mutex);
    while (!atomic_load_explicit(&g_render_done, memory_order_acquire))
        pthread_cond_wait(&g_render_done_cond, &g_render_mutex);
    pthread_mutex_unlock(&g_render_mutex);
}

/* ── M27: deferred GL2D composite glue ───────────────────────────────────
 * The melonDS core defers its heavy 2D composite at scanline 191 and calls
 * m27_kick_cb (emulation thread). We submit melonds_m27_execute() to the
 * render worker, which binds its own shared EGL context; the composite then
 * overlaps the VBlank portion (scanlines 192–262) of the same frame's CPU
 * emulation. Before the core present samples the output (or the next frame
 * rewrites the inputs), it calls m27_wait_cb via its internal sync point.
 * Failure of the worker context binding flips g_m27_worker_fail; the core's
 * sync point then renders the pending composite inline (correctness never
 * depends on the worker). */
static YageCore*  g_m27_core = NULL;
static atomic_int g_m27_worker_fail = 0;
static unsigned   g_m27_kicks = 0;
static unsigned   g_m27_waits = 0;

static void m27_worker_job(void) {
    if (hw_render_worker_bind() != 0) {
        atomic_store_explicit(&g_m27_worker_fail, 1, memory_order_release);
        return;     /* core's sync point falls back to inline rendering */
    }
    YageCore* core = g_m27_core;
    if (core && core->melonds_m27_execute)
        core->melonds_m27_execute();
}

static void m27_kick_cb(void) {
    if (atomic_load_explicit(&g_m27_worker_fail, memory_order_acquire)) {
        /* One-shot disable: worker context unusable on this device. */
        if (g_m27_core && g_m27_core->melonds_m27_set_enabled) {
            g_m27_core->melonds_m27_set_enabled(0);
            LOGI("M27: worker EGL bind failed — parallel GL2D disabled "
                 "(inline rendering restored)");
        }
        return;
    }
    render_worker_submit(m27_worker_job);
    g_m27_kicks++;
    if (g_m27_kicks == 1 || (g_m27_kicks % 600) == 0)
        LOGI("M27: kick #%u — composite submitted to render worker", g_m27_kicks);
}

static void m27_wait_cb(void) {
    render_worker_wait();
    g_m27_waits++;
    if (g_m27_waits == 1 || (g_m27_waits % 600) == 0)
        LOGI("M27: wait #%u — worker composite joined before consume/present",
             g_m27_waits);
}

static int m27_core_has_hooks(YageCore* core) {
    return core && core->melonds_m27_set_enabled && core->melonds_m27_execute &&
           core->melonds_m27_set_kick_callback && core->melonds_m27_set_wait_callback;
}

static void m27_enable(YageCore* core) {
    if (!m27_core_has_hooks(core)) return;
    if (getenv("YAGE_M27_DISABLE")) {
        LOGI("M27: disabled by YAGE_M27_DISABLE");
        return;
    }
    g_m27_core = core;
    atomic_store(&g_m27_worker_fail, 0);
    g_m27_kicks = g_m27_waits = 0;
    core->melonds_m27_set_kick_callback(m27_kick_cb);
    core->melonds_m27_set_wait_callback(m27_wait_cb);
    core->melonds_m27_set_enabled(1);
    LOGI("M27: parallel GL2D composite ENABLED (render worker, shared EGL context)");
}

static void m27_disable(YageCore* core) {
    if (!m27_core_has_hooks(core)) return;
    core->melonds_m27_set_enabled(0);
    core->melonds_m27_set_kick_callback(NULL);
    core->melonds_m27_set_wait_callback(NULL);
    if (g_m27_core)
        LOGI("M27: parallel GL2D composite disabled (kicks=%u waits=%u)",
             g_m27_kicks, g_m27_waits);
    g_m27_core = NULL;
}
#endif /* __ANDROID__ */

static int frame_loop_is_melonds_nds(void) {
#ifdef __ANDROID__
    return g_current_core &&
           g_current_core->platform == YAGE_PLATFORM_NDS &&
           g_core_lib_path &&
           strstr(g_core_lib_path, "melonds");
#else
    return 0;
#endif
}

static int frame_loop_melonds_direct_present(void) {
#ifdef __ANDROID__
    return frame_loop_is_melonds_nds() && hw_render_is_direct_present();
#else
    return 0;
#endif
}

static void frame_loop_start_failed(void) {
    atomic_store_explicit(&g_floop_running, 0, memory_order_release);
#ifdef __ANDROID__
    LOGE("Frame loop: startup failed; silencing audio (hw=%d current_ctx=%p target_ctx=%p)",
         g_hw_render_enabled,
         (void*)eglGetCurrentContext(),
         (void*)g_egl_context);
    atomic_store_explicit(&g_audio_stopping, 1, memory_order_release);
    reset_opensl_audio_pipeline();
#endif
}

/* ── Frame loop thread ───────────────────────────────────────────────── */

static void* frame_loop_thread(void* arg) {
    YageCore* core = (YageCore*)arg;

    struct timespec last_time;
    clock_gettime(CLOCK_MONOTONIC, &last_time);

    int64_t emu_accum_ns     = 0;
    int64_t display_accum_ns = 0;
    int     total_frames     = 0;
    int     rewind_counter   = 0;
    int64_t retro_run_total_ns = 0;
    int     retro_run_count    = 0;
    int     blit_ok_count      = 0;
    int     blit_fail_count    = 0;

    /* ── Adaptive frame pacing ──────────────────────────────────────────
     * EWMA of recent retro_run cost in ns. We use this to (a) cap the
     * inner catch-up loop so we don't blow past the display refresh and
     * starve audio on low-end TVs, and (b) skip the display blit on
     * frames where we can't keep up with the core's nominal frame rate.
     *
     * Seeded with the core's reported frame interval; recovers quickly
     * on speed-up but resists single-frame spikes that would otherwise
     * trigger aggressive catch-up.
     */
    int64_t retro_run_ewma_ns = g_core_frame_ns;
    int64_t last_blit_ns      = 0;  /* monotonic time of last completed blit */

    struct timespec fps_time  = last_time;
    struct timespec diag_time = last_time;
    int             diag_heartbeat_count = 0;

    LOGI("Frame loop thread started (core_frame_ns=%lld)", (long long)g_core_frame_ns);
    LOGI("Frame loop: fps heartbeat enabled (1s warmup, then 5s windows)");

#ifdef __ANDROID__
    configure_arm_sigbus_alignment_handler();
    enable_arm_unaligned_fixups();

    /* Apply THREAD_PRIORITY_URGENT_DISPLAY (nice -8) to ourselves.  This is
     * the same priority bucket SurfaceFlinger uses; it survives without
     * CAP_SYS_NICE and keeps the frame thread off the back of the run queue
     * when background services compete on a homogeneous low-end SoC (the
     * Sony BRAVIA BF1 capture had 4 cores all pegged at 1.53 GHz, so the
     * usual big-core pin is a no-op there).  setpriority on Linux applies
     * per-thread when pid==0. */
    {
        errno = 0;
        if (setpriority(PRIO_PROCESS, 0, -8) == 0) {
            LOGI("Frame loop: nice=-8 set (URGENT_DISPLAY equivalent)");
        } else {
            LOGI("Frame loop: setpriority(-8) failed (errno=%d), staying at default nice", errno);
        }
    }

    /* Wait briefly for the native window before doing anything else.
     *
     * Two cases benefit:
     *   1. HW-render cores that negotiated SET_HW_RENDER during
     *      retro_load_game (mupen64plus, Beetle PSX HW): they already have
     *      a pbuffer EGL context that we will promote to a window surface
     *      below.
     *   2. HW-render cores that negotiate lazily during the first retro_run
     *      (melonDS): no EGL context exists yet.  Their SET_HW_RENDER will
     *      fire from inside the first core->retro_run() below, and our
     *      env_callback's hw_render_init must see a non-NULL g_native_window
     *      so it creates a window surface (not a pbuffer fallback).  If we
     *      skipped this wait, the first retro_run would race the Flutter
     *      UI's surfaceCreated and intermittently fall back to pbuffer →
     *      readback path, breaking direct present.
     *
     * Software cores are unaffected. HW-render cores (melonDS, mupen64plus,
     * Beetle PSX HW) get a longer ~500 ms window so their first context_reset
     * can happen on the final Flutter texture surface instead of a pbuffer
     * fallback. */
    {
        int has_native_window = 0;
        int wait_tries = (frame_loop_is_melonds_nds() || g_hw_render_enabled) ? 50 : 10;
        for (int wait_i = 0; wait_i < wait_tries; wait_i++) {
            pthread_mutex_lock(&g_nw_mutex);
            has_native_window = (g_native_window != NULL);
            pthread_mutex_unlock(&g_nw_mutex);
            if (has_native_window) break;
            struct timespec ts = {0, 10000000};
            nanosleep(&ts, NULL);
        }
        (void)has_native_window;
    }

    /* EGL context binding for HW-render cores that already have a context
     * from retro_load_game (mupen64plus, Beetle PSX HW).
     *
     * For lazy-init cores (melonDS), g_hw_render_enabled is still 0 here;
     * the env_callback will create the context with a window surface on the
     * first retro_run and fire context_reset synchronously, so this block
     * is intentionally skipped. */
    if (g_hw_render_enabled &&
        g_egl_display != EGL_NO_DISPLAY &&
        g_egl_surface != EGL_NO_SURFACE &&
        g_egl_context != EGL_NO_CONTEXT) {

        int has_native_window = 0;
        pthread_mutex_lock(&g_nw_mutex);
        has_native_window = (g_native_window != NULL);
        pthread_mutex_unlock(&g_nw_mutex);

        if (has_native_window) {
            /* Promote the EGL context from pbuffer to window surface before
             * the first retro_run.  Cores like melonDS call GL functions at
             * the top of retro_run (before video_refresh_callback fires), so
             * the context must be current and context_reset must have run.
             *
             * Promoting here also prevents hw_render_readback from
             * reinitialising mid-frame (it only does so when the surface type
             * or dimensions change), avoiding a double context_reset that
             * would corrupt GL state in cores like GLideN64. */
            if (!hw_render_is_direct_present()) {
                unsigned w = g_hw_fb_width  > 0 ? g_hw_fb_width  : (unsigned)N64_WIDTH;
                unsigned h = g_hw_fb_height > 0 ? g_hw_fb_height : (unsigned)N64_HEIGHT;
                if (frame_loop_is_melonds_nds() && g_width > 0 && g_height > 0) {
                    w = (unsigned)g_width;
                    h = (unsigned)g_height;
                }
                if (hw_render_init(w, h) != 0) {
                    LOGE("Frame loop: hw_render_init (window surface) failed; stopping");
                    frame_loop_start_failed();
                    return NULL;
                }
                LOGI("Frame loop: promoted EGL context to window surface (%ux%u)", w, h);
            }
            /* hw_render_init leaves the context current on the calling thread.
             * If it was already a window surface the load thread released it;
             * rebind only if not already current. */
            if (eglGetCurrentContext() != g_egl_context) {
                if (!eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface, g_egl_context)) {
                    LOGE("Frame loop: eglMakeCurrent failed (err=0x%x)", (unsigned)eglGetError());
                    frame_loop_start_failed();
                    return NULL;
                }
            }
            LOGI("Frame loop: EGL window-surface context bound to frame thread");
            if (g_hw_context_reset_pending && g_hw_render_cb.context_reset) {
                g_hw_context_reset_pending = 0;
                LOGI("Frame loop: firing context_reset (window surface, pre-retro_run)");
                g_hw_render_cb.context_reset();
            }
            /* Clear the surface to black so any area outside the core's
             * viewport starts clean rather than showing uninitialized garbage
             * from a previous session or a stale surface recreation.  This
             * eliminates the "yellow/red lines" artifact that appears when
             * the core's rendered viewport is smaller than the EGL surface
             * (e.g. boot sequence at 512×480 on a 1280×956 surface left
             * from a prior mode). */
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
            glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
            glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        } else {
            /* No native window after 100 ms — use the pbuffer context as
             * fallback.  hw_render_readback will switch to window surface
             * on the first frame once the native window is attached. */
            if (!eglMakeCurrent(g_egl_display, g_egl_surface, g_egl_surface, g_egl_context)) {
                LOGE("Frame loop: eglMakeCurrent failed (err=0x%x)", (unsigned)eglGetError());
                frame_loop_start_failed();
                return NULL;
            }
            LOGI("Frame loop: EGL context bound to frame thread (pbuffer, no native window)");
            if (g_hw_context_reset_pending && g_hw_render_cb.context_reset) {
                g_hw_context_reset_pending = 0;
                LOGI("Frame loop: firing context_reset (pbuffer fallback)");
                g_hw_render_cb.context_reset();
            }
        }
    }

    /* Pin this thread to the fastest CPU cluster on big.LITTLE / DynamIQ
     * SoCs.  No-ops silently if sysfs is unavailable or permission denied. */
    pin_to_big_cores();

    /* Start the async GPU3D render worker for melonDS NDS cores.
     * On homogeneous quad-core SoCs (BRAVIA BF1) this puts GPU3D geometry
     * on a separate core, overlapping with the next frame's CPU emulation. */
    if (frame_loop_is_melonds_nds()) {
        render_worker_start();
        LOGI("Frame loop: GPU3D render worker started for melonDS");
        /* M27: wire the deferred GL2D composite to the worker (no-op unless
         * the core exports the hooks; safe even before GL2D initialises —
         * deferral only begins once the GL2D renderer is live). */
        m27_enable(core);
    }
#endif /* __ANDROID__ */

    while (atomic_load_explicit(&g_floop_running, memory_order_acquire)) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        int64_t elapsed_ns = (now.tv_sec  - last_time.tv_sec)  * 1000000000LL
                           + (now.tv_nsec - last_time.tv_nsec);
        last_time = now;

        emu_accum_ns     += elapsed_ns;
        display_accum_ns += elapsed_ns;

        int speed_pct = atomic_load_explicit(&g_floop_speed_pct, memory_order_relaxed);
        if (speed_pct < 25) speed_pct = 25;
        int64_t target_ns = g_core_frame_ns * 100LL / speed_pct;

        /* Adaptive catch-up cap. At 1× speed we never want to run more
         * back-to-back frames than the device can deliver in one display
         * interval, otherwise we lock out the blit + nanosleep paths and
         * starve the audio ring. On a fast device this remains 4 (close
         * to the old cap of 8); on a slow device where retro_run already
         * exceeds the target interval we shrink it to 1 so emulation
         * runs in real-time-ish lockstep with display refresh.
         *
         * Turbo (>1× speed) gets a larger budget so fast-forward isn't
         * artificially throttled.
         */
        int max_catchup;
        if (speed_pct > 100) {
            max_catchup = 4;
        } else if (retro_run_ewma_ns >= g_core_frame_ns) {
            max_catchup = 1;   /* can't keep up — run one at a time */
        } else if (retro_run_ewma_ns >= g_core_frame_ns / 2) {
            max_catchup = 2;
        } else {
            max_catchup = 4;
        }

        /* ── Adaptive video frameskip ────────────────────────────────────
         * When retro_run consistently exceeds the core's nominal frame
         * interval, ask the core to skip video rendering while still running
         * audio + CPU emulation. The old policy always rendered 1 of every 2
         * frames once late. On the BRAVIA ARMv7 interpreter path, logs show
         * retro_run can climb to 30-70 ms, so fixed 50% video is still too
         * much GL/GPU work during severe scenes.
         *
         * The interval scales with sustained lateness:
         *   1x-2x over budget: render 1 of 2 frames
         *   2x-3x over budget: render 1 of 3 frames
         *   3x+  over budget: render 1 of 4 frames
         *
         * Enter skip mode when EWMA exceeds 1.0x target for sustained
         * frames; exit when EWMA drops to 0.85x to avoid flapping.
         * Speed override (turbo/slow-mo) disables skipping because the user
         * explicitly asked for non-real-time speed.
         */
        static int  skip_mode      = 0;
        static int  skip_above_n   = 0; /* consecutive over-budget frames */
        static int  skip_phase     = 0; /* modulo skip_interval */
        static int  skip_interval  = 1; /* 1=no skip, 2=render 1/2, etc. */
        int desired_skip_interval = 1;
        if (speed_pct == 100) {
            if (retro_run_ewma_ns > g_core_frame_ns) {
                desired_skip_interval = 2;
                if (retro_run_ewma_ns > g_core_frame_ns * 3)
                    desired_skip_interval = 4;
                else if (retro_run_ewma_ns > g_core_frame_ns * 2)
                    desired_skip_interval = 3;
                if (++skip_above_n >= 6 && !skip_mode) {
                    skip_mode = 1;
                    skip_phase = 0;
                }
                if (skip_mode) {
                    skip_interval = desired_skip_interval;
                    if (skip_phase >= skip_interval) skip_phase = 0;
                }
            } else if (retro_run_ewma_ns < (g_core_frame_ns * 85 / 100)) {
                skip_above_n = 0;
                if (skip_mode) skip_mode = 0;
                skip_interval = 1;
            }
        } else {
            skip_mode = 0;
            skip_above_n = 0;
            skip_interval = 1;
        }

        int frames_run = 0;
        while (atomic_load_explicit(&g_floop_running, memory_order_relaxed) &&
               emu_accum_ns >= target_ns && frames_run < max_catchup) {

            /* Decide if this retro_run drops video. Audio always runs.
             * In catch-up (frames_run > 0) we always skip the extra
             * iterations' video — those frames will never be displayed
             * anyway, so rendering them is pure waste. The first frame
             * of a tick respects the alternating phase. */
            int want_skip;
            if (frames_run > 0) {
                want_skip = 1;
            } else if (skip_mode) {
                skip_phase = (skip_phase + 1) % skip_interval;
                want_skip = (skip_phase != 0);
            } else {
                want_skip = 0;
            }
            /* GL direct-present: allow skip — GPU::SkipFrameRendering=true saves
             * GPU2D scanlines + GPU3D VCount215 GL rasterisation + GL composite
             * (~7-17% of frame time). CPU-side GPU3D::Run() geometry is
             * unconditional (NDS.cpp) and unaffected. The FBO retains its last
             * rendered content; the EGL surface holds the last swap → display
             * shows the previous frame cleanly. No state corruption: the next
             * real frame re-renders all FBOs from scratch. */
            atomic_store_explicit(&g_floop_skip_video, want_skip,
                                  memory_order_relaxed);

            g_audio_samples = 0;
            /* Count emulated frames before retro_run(), so audio callbacks
             * fired during this run see the frame they belong to. Video
             * callbacks are skipped under adaptive frameskip; this counter is
             * the stable denominator for audio rate detection. */
            atomic_fetch_add_explicit(&g_core_frames_total, 1,
                                      memory_order_relaxed);
            int64_t this_run_ns;
            {
                struct timespec t0, t1;
                clock_gettime(CLOCK_MONOTONIC, &t0);
                yage_env_frame_time_tick();
                core->retro_run();
                clock_gettime(CLOCK_MONOTONIC, &t1);
                this_run_ns = (t1.tv_sec - t0.tv_sec) * 1000000000LL
                            + (t1.tv_nsec - t0.tv_nsec);
                retro_run_total_ns += this_run_ns;
                retro_run_count++;
            }
            /* EWMA with alpha=1/8 — fast enough to track scene changes
             * but stable enough to ignore one-off spikes. */
            retro_run_ewma_ns += (this_run_ns - retro_run_ewma_ns) >> 3;
            /* Publish in µs for the audio thread (used by elastic rate). */
            atomic_store_explicit(&g_retro_run_ewma_us,
                (int)(retro_run_ewma_ns / 1000),
                memory_order_relaxed);
            total_frames++;

            if (atomic_load_explicit(&g_floop_rewind_on, memory_order_relaxed)) {
                rewind_counter++;
                int interval = atomic_load_explicit(&g_floop_rewind_interval,
                                                     memory_order_relaxed);
                if (interval > 0 && rewind_counter >= interval) {
                    rewind_counter = 0;
                    yage_core_rewind_push(core);
                }
            }

            if (atomic_load_explicit(&g_floop_rcheevos_on, memory_order_relaxed)) {
                yage_rc_do_frame();
            }

            emu_accum_ns -= target_ns;
            frames_run++;
        }

        if (emu_accum_ns > target_ns * 10) emu_accum_ns = 0;
        /* When the blit-skip path stays active for a long stretch we can
         * accumulate many display intervals without ever decrementing
         * display_accum_ns inside the blit branch.  Cap it here so that
         * when we do finally blit we don't fire several back-to-back
         * blits in a row (each one does the decrement-and-rebound below). */
        if (display_accum_ns > DISPLAY_INTERVAL_NS * 4) {
            display_accum_ns = DISPLAY_INTERVAL_NS;
        }

        /* Skip the display blit when we are visibly behind real-time:
         * the emulator backlog (emu_accum_ns) is already greater than
         * one core frame interval AND the last retro_run cost > 1.25×
         * the target interval.  In that regime running another emu
         * frame is more valuable than presenting a frame the user will
         * barely notice — and skipping the blit reclaims ~1 ms of
         * Mali / memcpy time per skip on TV.  We still guarantee a
         * blit every ~6 core frames (~100 ms) so the screen never
         * appears frozen, and we always blit at least one frame
         * shortly after startup (last_blit_ns == 0). */
        int allow_blit = 1;
        if (frames_run > 0 && speed_pct == 100 && last_blit_ns != 0) {
            int64_t now_ns_abs = now.tv_sec * 1000000000LL + now.tv_nsec;
            int64_t since_blit = now_ns_abs - last_blit_ns;
            const int64_t blit_force_after_ns = g_core_frame_ns * 6;
            int behind = (emu_accum_ns > target_ns) &&
                         (retro_run_ewma_ns > (target_ns * 5) / 4);
            if (behind && since_blit < blit_force_after_ns) {
                allow_blit = 0;
            }
        }

        if (frames_run > 0 && display_accum_ns >= DISPLAY_INTERVAL_NS && allow_blit) {
            display_accum_ns -= DISPLAY_INTERVAL_NS;
            if (display_accum_ns > DISPLAY_INTERVAL_NS * 3) display_accum_ns = 0;

            int w = g_width;
            int h = g_height;

#ifdef __ANDROID__
            if (g_native_window) {
                if (g_hw_render_enabled && hw_render_is_direct_present()) {
                    /* Direct-present (NDS/N64/PS1 OpenGL): there is no CPU
                     * blit, but the core can change geometry at runtime — e.g.
                     * melonDS reflows Top/Bottom (256x384) to Left/Right
                     * (512x192) when the device rotates to landscape. The
                     * software path below keeps g_display_* in sync every
                     * frame; the HW path must do the same, or Dart keeps
                     * sizing the surface to the stale start-up dimensions and
                     * the NDS screens render as a narrow vertical strip. */
                    pthread_mutex_lock(&g_display_mutex);
                    g_display_width  = w;
                    g_display_height = h;
                    pthread_mutex_unlock(&g_display_mutex);
                    blit_ok_count++;
                } else {
                    if (blit_to_native_window() == 0) blit_ok_count++;
                    else blit_fail_count++;
                }
            } else
#endif
            {
                size_t pixels = (size_t)w * h;
                if (g_display_buf && pixels <= g_display_buf_capacity && g_video_buffer) {
                    pthread_mutex_lock(&g_display_mutex);
                    memcpy(g_display_buf, g_video_buffer, pixels * sizeof(uint32_t));
                    g_display_width  = w;
                    g_display_height = h;
                    pthread_mutex_unlock(&g_display_mutex);
                }
            }

            last_blit_ns = (now.tv_sec * 1000000000LL) + now.tv_nsec;
            /* Throttle the Dart-side callback to 1/3 frames (~20 Hz at
             * full speed, ~10 Hz when CPU-bound).  The callback is a
             * NativeCallable.listener — every invocation posts a message
             * to the Dart isolate's event loop, which then runs the
             * handler.  In debug mode each isolate wakeup is unoptimised;
             * 60 messages/sec on a 1.5 GHz core is measurable overhead.
             *
             * Consumers of the callback (FPS overlay, link-cable poll)
             * don't need 60 Hz: overlay refreshes at 2 Hz, link-cable
             * GB/GBA serial protocol is well under 1 KHz.  Dart side
             * also has its own internal throttle on the FPS read. */
            static int callback_tick = 0;
            /* Frame-delivery-aware throttle. When a native window / Surface is
             * attached (the zero-copy Texture path, now used on phones AND
             * Android TV), the blit above already presented this frame to the
             * screen at full rate, so the Dart callback only feeds the FPS
             * overlay + link-cable poll — throttle it to 1/3 to keep isolate
             * wakeups cheap. When there is NO native window (the software
             * fallback, where Dart reads g_display_buf and paints it itself),
             * the callback IS the frame-delivery mechanism and must fire on
             * every displayed frame, otherwise the picture only updates at
             * ~20 Hz — the old "TV feels slow / choppy" behaviour. */
            int callback_has_window = 0;
#ifdef __ANDROID__
            callback_has_window = (g_native_window != NULL);
#endif
            const int callback_due =
                callback_has_window ? ((callback_tick++ % 3) == 0) : 1;
            if (g_frame_callback && callback_due) {
                g_frame_callback(frames_run);
            }
        }

        int64_t fps_elapsed = (now.tv_sec  - fps_time.tv_sec)  * 1000000000LL
                            + (now.tv_nsec - fps_time.tv_nsec);
        if (fps_elapsed >= 500000000LL) {
            double fps = (double)total_frames * 1.0e9 / (double)fps_elapsed;
            atomic_store_explicit(&g_floop_fps_x100, (int)(fps * 100.0), memory_order_relaxed);
            total_frames = 0;
            fps_time = now;
        }

        int64_t diag_elapsed = (now.tv_sec  - diag_time.tv_sec)  * 1000000000LL
                             + (now.tv_nsec - diag_time.tv_nsec);
        /* Heartbeat: log compact fps/retro_run lines every second during
         * the first few windows so short TV captures always include FPS,
         * then settle to a 5-second cadence to keep logcat cheap. Verbose
         * Diag (ring/underruns/blit) is still gated behind
         * YAGE_FRAME_LOOP_DIAG. */
        int64_t diag_interval_ns =
            (diag_heartbeat_count < 10) ? 1000000000LL : 5000000000LL;
        if (diag_elapsed >= diag_interval_ns) {
#ifdef __ANDROID__
            double avg_run_ms = (retro_run_count > 0)
                ? (double)retro_run_total_ns / retro_run_count / 1e6 : 0;
            double diag_fps = (retro_run_count > 0)
                ? (double)retro_run_count * 1.0e9 / (double)diag_elapsed : 0;
            double diag_window_s = (double)diag_elapsed / 1e9;
            LOGI("Frame loop: fps=%.1f retro_run=%.1fms (%.1fs window)",
                 diag_fps, avg_run_ms, diag_window_s);
            {
                int avail = ring_buffer_available();
                LOGI("Frame loop audio: ring=%d/%d underrun=%d overflow=%d skip=%s interval=%d",
                     avail, RING_BUFFER_SIZE - 1,
                     g_underrun_count, g_overflow_count,
                     skip_mode ? "on" : "off",
                     skip_mode ? skip_interval : 1);
            }
#  ifdef YAGE_FRAME_LOOP_DIAG
            {
                int avail = ring_buffer_available();
                LOGI("  Diag: blit=%d ok/%d fail, ring=%d/%d, underruns=%d, overflows=%d, skip=%s interval=%d",
                     blit_ok_count, blit_fail_count,
                     avail, RING_BUFFER_SIZE - 1,
                     g_underrun_count, g_overflow_count,
                     skip_mode ? "on" : "off",
                     skip_mode ? skip_interval : 1);
            }
#  else
            (void)blit_ok_count; (void)blit_fail_count;
#  endif
#else
            (void)blit_ok_count; (void)blit_fail_count;
#endif
            retro_run_total_ns = 0;
            retro_run_count    = 0;
            blit_ok_count      = 0;
            blit_fail_count    = 0;
            diag_time = now;
            diag_heartbeat_count++;
        }

        int64_t next_emu_ns     = target_ns - emu_accum_ns;
        int64_t next_display_ns = DISPLAY_INTERVAL_NS - display_accum_ns;
        int64_t sleep_ns = next_emu_ns < next_display_ns ? next_emu_ns : next_display_ns;

        if (sleep_ns > 500000) {
            struct timespec ts;
            ts.tv_sec  = sleep_ns / 1000000000LL;
            ts.tv_nsec = sleep_ns % 1000000000LL;
            nanosleep(&ts, NULL);
        }
    }

    /* Clear the frameskip hint so the next session's first retro_run
     * sees a clean state (env_callback returns ENABLE_VIDEO|ENABLE_AUDIO). */
    atomic_store_explicit(&g_floop_skip_video, 0, memory_order_relaxed);

#ifdef __ANDROID__
    /* M27: unhook before this thread (the only kick producer) exits, so the
     * worker can be stopped without in-flight submissions. */
    m27_disable(core);

    /* Release the EGL context from this thread before it dies.  An EGL
     * context left "current" on an exited thread is, per spec, still
     * busy — a later eglMakeCurrent from the main thread (pause→resume
     * rebind, or yage_core_destroy's clean-shutdown rebind before
     * retro_unload_game) can then fail with EGL_BAD_ACCESS depending on
     * the driver.  Explicitly unbinding here makes the cross-thread
     * handoff deterministic on every driver. */
    if (g_hw_render_enabled &&
        g_egl_display != EGL_NO_DISPLAY &&
        eglGetCurrentContext() == g_egl_context) {
        eglMakeCurrent(g_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       EGL_NO_CONTEXT);
        LOGI("Frame loop: EGL context released from frame thread");
    }
#endif

    LOGI("Frame loop thread exiting");
    return NULL;
}

/* ── Public API ──────────────────────────────────────────────────────── */

int yage_frame_loop_start(YageCore* core, yage_frame_callback_t callback) {
    if (!core || !core->game_loaded || !core->retro_run) return -1;
    if (atomic_load(&g_floop_running)) return -1;

#ifdef __ANDROID__
    LOGI("Frame loop: start requested platform=%d hw=%d direct=%d "
         "current_ctx=%p target_ctx=%p surface=%p",
         core->platform,
         g_hw_render_enabled,
         hw_render_is_direct_present(),
         (void*)eglGetCurrentContext(),
         (void*)g_egl_context,
         (void*)g_egl_surface);
#else
    LOGI("Frame loop: start requested platform=%d", core->platform);
#endif

    size_t needed = g_video_buffer_capacity;
    if (!g_display_buf || g_display_buf_capacity < needed) {
        free(g_display_buf);
        g_display_buf = (uint32_t*)malloc(needed * sizeof(uint32_t));
        if (!g_display_buf) { LOGE("Failed to allocate display buffer"); return -1; }
        g_display_buf_capacity = needed;
    }
    memset(g_display_buf, 0, needed * sizeof(uint32_t));
    g_display_width  = g_width;
    g_display_height = g_height;

    g_frame_callback = callback;
    atomic_store_explicit(&g_floop_fps_x100,  0, memory_order_relaxed);
#ifdef __ANDROID__
    reset_opensl_audio_pipeline();
#endif
    /* Clear the stop-flag that yage_frame_loop_stop() set to silence the
     * OpenSL callback during shutdown.  If we don't reset it here, resuming
     * from pause leaves g_audio_stopping=1 permanently (shutdown_opensl_audio
     * is only called on game unload, not on pause), so the OpenSL buffer
     * callback silences every audio buffer for the rest of the session. */
    atomic_store_explicit(&g_audio_stopping, 0, memory_order_release);
    atomic_store_explicit(&g_floop_running,  1, memory_order_release);

    int rc = pthread_create(&g_frame_thread, NULL, frame_loop_thread, core);
    if (rc != 0) {
        frame_loop_start_failed();
        g_frame_callback = NULL;
        LOGE("pthread_create failed: %d", rc);
        return -1;
    }

#ifdef __ANDROID__
    /* Elevate the frame-loop thread above CFS-default.  Two tiers:
     *   1. SCHED_FIFO priority 1 — true real-time bucket; only granted if
     *      the process holds CAP_SYS_NICE, which apps don't on stock
     *      Android (so this almost always fails with EPERM).  We still
     *      try it: rooted devices and emulators sometimes grant it.
     *   2. CFS nice -8 via setpriority() applied from inside the thread
     *      itself (see frame_loop_thread) — equivalent to
     *      THREAD_PRIORITY_URGENT_DISPLAY in android.os.Process.  Doesn't
     *      need extra capabilities and gives the thread the same scheduling
     *      treatment as SurfaceFlinger.  This is the path that actually
     *      lands on TV.  One-time log on the chosen path so we can confirm
     *      from a capture which scheduler bucket the thread ended up in. */
    {
        struct sched_param sp;
        sp.sched_priority = 1;
        int sched_rc = pthread_setschedparam(g_frame_thread, SCHED_FIFO, &sp);
        if (sched_rc == 0) {
            LOGI("Frame loop: SCHED_FIFO priority 1 set");
        }
        /* On failure we stay quiet — the frame thread will then drop into
         * the setpriority(-8) tier inside frame_loop_thread and log that. */
    }
#endif

    LOGI("Native frame loop started (speed=%d%%)", atomic_load(&g_floop_speed_pct));
    return 0;
}

void yage_frame_loop_stop(YageCore* core) {
    (void)core;
    if (!atomic_load(&g_floop_running)) return;
    atomic_store_explicit(&g_floop_running, 0, memory_order_release);
    /* Silence the OpenSL callback immediately so the elastic hold-buffer
     * does not loop the last audio buffer as radio noise while we wait
     * for the frame thread to finish its current retro_run(). */
    atomic_store_explicit(&g_audio_stopping, 1, memory_order_release);
    /* Join the frame thread BEFORE stopping the render worker: the frame
     * thread is the only producer of worker jobs (M27 kicks), and it unhooks
     * M27 on exit. Stopping the worker first could strand a submitted job
     * and hang a subsequent wait. */
    pthread_join(g_frame_thread, NULL);
#ifdef __ANDROID__
    render_worker_stop();
#endif
    g_frame_callback = NULL;

    /*
     * Release the display buffer now that the thread is joined and no
     * callbacks are in flight. The Dart side always clears
     * `_frameLoopActive` BEFORE calling stop (see emulator_service.dart),
     * so no queued frame-ready event can race this free. Freeing here —
     * rather than leaking to app shutdown — means a core switch from a
     * high-res system (e.g. N64 640x480 ≈ 1.2 MB) back to GB doesn't
     * retain the larger buffer for the rest of the session.
     */
    pthread_mutex_lock(&g_display_mutex);
    free(g_display_buf);
    g_display_buf = NULL;
    g_display_buf_capacity = 0;
    g_display_width = 0;
    g_display_height = 0;
    pthread_mutex_unlock(&g_display_mutex);

    LOGI("Native frame loop stopped");
}

void yage_frame_loop_set_speed(YageCore* core, int32_t speed_percent) {
    (void)core;
    if (speed_percent < 25)  speed_percent = 25;
    if (speed_percent > 800) speed_percent = 800;
    atomic_store_explicit(&g_floop_speed_pct, speed_percent, memory_order_relaxed);
}

void yage_frame_loop_set_rewind(YageCore* core, int32_t enabled, int32_t interval) {
    (void)core;
    atomic_store_explicit(&g_floop_rewind_on, enabled ? 1 : 0, memory_order_relaxed);
    if (interval > 0)
        atomic_store_explicit(&g_floop_rewind_interval, interval, memory_order_relaxed);
}

void yage_frame_loop_set_rcheevos(YageCore* core, int32_t enabled) {
    (void)core;
    atomic_store_explicit(&g_floop_rcheevos_on, enabled ? 1 : 0, memory_order_relaxed);
}

int32_t yage_frame_loop_get_fps_x100(YageCore* core) {
    (void)core;
    return atomic_load_explicit(&g_floop_fps_x100, memory_order_relaxed);
}

int32_t yage_frame_loop_get_run_ewma_us(YageCore* core) {
    (void)core;
    return atomic_load_explicit(&g_retro_run_ewma_us, memory_order_relaxed);
}

int32_t yage_frame_loop_get_frame_interval_us(YageCore* core) {
    (void)core;
    return (int32_t)(g_core_frame_ns / 1000);
}

uint32_t* yage_frame_loop_get_display_buffer(YageCore* core) {
    (void)core;
    /*
     * Returns a raw pointer to the internal display buffer.
     *
     * LIFETIME: valid only while the frame loop is running (between
     * yage_frame_loop_start() and yage_frame_loop_stop()). stop() frees
     * the buffer under g_display_mutex, so callers MUST NOT cache the
     * pointer across a stop/start boundary — that would be a
     * use-after-free.
     *
     * THREAD SAFETY: the frame-loop thread writes this buffer under
     * g_display_mutex. Callers that read it (e.g. Dart via FFI) MUST
     * hold g_display_mutex via yage_frame_loop_lock_display() for the
     * duration of the read, otherwise they may observe a torn frame or
     * (at stop time) a freed buffer.
     */
    return g_display_buf;
}

int32_t yage_frame_loop_get_display_width(YageCore* core) {
    (void)core;
    return g_display_width;
}

int32_t yage_frame_loop_get_display_height(YageCore* core) {
    (void)core;
    return g_display_height;
}

void yage_frame_loop_lock_display(YageCore* core) {
    (void)core;
    pthread_mutex_lock(&g_display_mutex);
}

void yage_frame_loop_unlock_display(YageCore* core) {
    (void)core;
    pthread_mutex_unlock(&g_display_mutex);
}

int32_t yage_frame_loop_is_running(YageCore* core) {
    (void)core;
    return atomic_load_explicit(&g_floop_running, memory_order_acquire);
}

#else /* _WIN32 — stubs so all symbols exist for the linker */

int  yage_frame_loop_start(YageCore* c, yage_frame_callback_t cb) { (void)c; (void)cb; return -1; }
void yage_frame_loop_stop(YageCore* c) { (void)c; }
void yage_frame_loop_set_speed(YageCore* c, int32_t s) { (void)c; (void)s; }
void yage_frame_loop_set_rewind(YageCore* c, int32_t e, int32_t i) { (void)c; (void)e; (void)i; }
void yage_frame_loop_set_rcheevos(YageCore* c, int32_t e) { (void)c; (void)e; }
int32_t   yage_frame_loop_get_fps_x100(YageCore* c)          { (void)c; return 0; }
int32_t   yage_frame_loop_get_run_ewma_us(YageCore* c)       { (void)c; return 0; }
int32_t   yage_frame_loop_get_frame_interval_us(YageCore* c) { (void)c; return 0; }
uint32_t* yage_frame_loop_get_display_buffer(YageCore* c)    { (void)c; return NULL; }
int32_t   yage_frame_loop_get_display_width(YageCore* c)     { (void)c; return 0; }
int32_t   yage_frame_loop_get_display_height(YageCore* c)    { (void)c; return 0; }
void      yage_frame_loop_lock_display(YageCore* c)          { (void)c; }
void      yage_frame_loop_unlock_display(YageCore* c)        { (void)c; }
int32_t   yage_frame_loop_is_running(YageCore* c)            { (void)c; return 0; }

#endif /* _WIN32 */
