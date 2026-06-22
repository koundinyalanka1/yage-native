# YAGE Libretro Wrapper + rcheevos CMake Configuration
cmake_minimum_required(VERSION 3.16)
project(yage_core C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# ── rcheevos source files ──────────────────────────────────────────────
# We compile rcheevos as part of yage_core (static linking).
# Include the core/client sources and rhash so game identification matches
# RetroAchievements for systems with special hashing rules (NDS, PS1, etc.).
set(RCHEEVOS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/rcheevos)

set(RCHEEVOS_SOURCES
    # Core rcheevos (condition parser, evaluator, runtime)
    ${RCHEEVOS_DIR}/src/rcheevos/alloc.c
    ${RCHEEVOS_DIR}/src/rcheevos/condition.c
    ${RCHEEVOS_DIR}/src/rcheevos/condset.c
    ${RCHEEVOS_DIR}/src/rcheevos/consoleinfo.c
    ${RCHEEVOS_DIR}/src/rcheevos/format.c
    ${RCHEEVOS_DIR}/src/rcheevos/lboard.c
    ${RCHEEVOS_DIR}/src/rcheevos/memref.c
    ${RCHEEVOS_DIR}/src/rcheevos/operand.c
    ${RCHEEVOS_DIR}/src/rcheevos/richpresence.c
    ${RCHEEVOS_DIR}/src/rcheevos/runtime.c
    ${RCHEEVOS_DIR}/src/rcheevos/runtime_progress.c
    ${RCHEEVOS_DIR}/src/rcheevos/trigger.c
    ${RCHEEVOS_DIR}/src/rcheevos/value.c
    # rc_client (high-level API)
    ${RCHEEVOS_DIR}/src/rc_client.c
    ${RCHEEVOS_DIR}/src/rc_compat.c
    ${RCHEEVOS_DIR}/src/rc_util.c
    ${RCHEEVOS_DIR}/src/rc_version.c
    # API request/response serialization
    ${RCHEEVOS_DIR}/src/rapi/rc_api_common.c
    ${RCHEEVOS_DIR}/src/rapi/rc_api_editor.c
    ${RCHEEVOS_DIR}/src/rapi/rc_api_info.c
    ${RCHEEVOS_DIR}/src/rapi/rc_api_runtime.c
    ${RCHEEVOS_DIR}/src/rapi/rc_api_user.c
    # Hash utilities (MD5 — required by rc_api_editor and runtime)
    ${RCHEEVOS_DIR}/src/rhash/aes.c
    ${RCHEEVOS_DIR}/src/rhash/cdreader.c
    ${RCHEEVOS_DIR}/src/rhash/hash.c
    ${RCHEEVOS_DIR}/src/rhash/hash_disc.c
    ${RCHEEVOS_DIR}/src/rhash/hash_encrypted.c
    ${RCHEEVOS_DIR}/src/rhash/hash_rom.c
    ${RCHEEVOS_DIR}/src/rhash/hash_zip.c
    ${RCHEEVOS_DIR}/src/rhash/md5.c
)

# ── YAGE Libretro Module Files ─────────────────────────────────────────
# Refactored into focused, single-responsibility modules linked via yage_internal.h.
# 
# Module Breakdown:
#   yage_libretro.c       - Core lifecycle, API orchestration
#   yage_internal.h       - Shared header: extern declarations, types, prototypes
#   yage_core_vars.c      - Core option variables storage & parsing
#   yage_input.c          - Input callbacks (joypad, analog, touch)
#   yage_callbacks.c      - Memory mapping helpers for link cable
#   yage_hw_render.c      - EGL/OpenGL ES HW render context (Android)
#   yage_audio.c          - OpenSL ES audio backend + libretro callbacks
#   yage_video.c          - Video processing, color correction, ANativeWindow blit
#   yage_frame_loop.c     - POSIX frame-loop thread (~60 Hz pacing)
#   yage_state.c          - Save/load state, rewind, SRAM, cheat codes
#   yage_env_callback.c   - Libretro environment_callback
#
# All modules include yage_internal.h which provides unified declarations

# ── Build shared library ───────────────────────────────────────────
add_library(yage_core SHARED
    yage_libretro.c
    yage_libretro.h
    yage_internal.h
    yage_core_vars.c
    yage_input.c
    yage_callbacks.c
    yage_hw_render.c
    yage_audio.c
    yage_video.c
    yage_frame_loop.c
    yage_state.c
    yage_env_callback.c
    yage_gpu_texture.c
    yage_options_ui.c
    yage_rcheevos.c
    yage_rcheevos.h
    ${RCHEEVOS_SOURCES}
)

# ── Include paths ──────────────────────────────────────────────────────
target_include_directories(yage_core PRIVATE
    ${RCHEEVOS_DIR}/include
    ${RCHEEVOS_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# ── Compile definitions ───────────────────────────────────────────────
# Build rcheevos as static (compiled into yage_core shared lib).
target_compile_definitions(yage_core PRIVATE
    RC_STATIC
)

# Export symbols on Windows
if(WIN32)
    target_compile_definitions(yage_core PRIVATE YAGE_EXPORTS)
endif()

# ── Link libraries ────────────────────────────────────────────────────
if(WIN32)
    # No additional libs needed - we load libretro dynamically
elseif(ANDROID)
    # pthread is part of Bionic libc (no explicit link needed)
    # 'android' provides ANativeWindow for zero-copy texture rendering
    # EGL/GLESv3 are required for the GLES3 HW-render context (melonDS,
    # mupen64plus-next etc.) and glReadPixels readback.  GLESv3 is a strict
    # superset of GLESv2 on Android, so no GLES2-only code is broken.
    target_link_libraries(yage_core PRIVATE dl log m OpenSLES android EGL GLESv3)
else()
    # Linux / macOS — link pthread for the native frame loop thread.
    # 'm' provides powf for the color-tuning LUT (yage_video.c); macOS
    # bundles it in libSystem but linking m is harmless there.
    find_package(Threads REQUIRED)
    target_link_libraries(yage_core PRIVATE dl m Threads::Threads)
endif()

# ── Output directory ──────────────────────────────────────────────────
set_target_properties(yage_core PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
)

# For Android NDK build
if(ANDROID)
    set_target_properties(yage_core PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}"
    )
    # 16 KB page size support for Google Play (required for Android 15+ from Nov 2025)
    # Ensures ELF segments are aligned for devices with 16 KB memory pages
    target_link_options(yage_core PRIVATE
        "LINKER:-z,max-page-size=16384"
        "LINKER:-z,common-page-size=16384"
    )
endif()
