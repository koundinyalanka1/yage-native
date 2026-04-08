cmake_minimum_required(VERSION 3.16)
project(yage_core C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

set(RCHEEVOS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/rcheevos)

set(RCHEEVOS_SOURCES
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
    ${RCHEEVOS_DIR}/src/rc_client.c
    ${RCHEEVOS_DIR}/src/rc_compat.c
    ${RCHEEVOS_DIR}/src/rc_util.c
    ${RCHEEVOS_DIR}/src/rc_version.c
    ${RCHEEVOS_DIR}/src/rapi/rc_api_common.c
    ${RCHEEVOS_DIR}/src/rapi/rc_api_editor.c
    ${RCHEEVOS_DIR}/src/rapi/rc_api_info.c
    ${RCHEEVOS_DIR}/src/rapi/rc_api_runtime.c
    ${RCHEEVOS_DIR}/src/rapi/rc_api_user.c
    ${RCHEEVOS_DIR}/src/rhash/md5.c
)


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

target_include_directories(yage_core PRIVATE
    ${RCHEEVOS_DIR}/include
    ${RCHEEVOS_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_compile_definitions(yage_core PRIVATE
    RC_STATIC
)

if(WIN32)
    target_compile_definitions(yage_core PRIVATE YAGE_EXPORTS)
endif()

if(WIN32)
elseif(ANDROID)
    target_link_libraries(yage_core PRIVATE dl log m OpenSLES android EGL GLESv2)
else()
    find_package(Threads REQUIRED)
    target_link_libraries(yage_core PRIVATE dl Threads::Threads)
endif()

set_target_properties(yage_core PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
)

if(ANDROID)
    set_target_properties(yage_core PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}"
    )
    target_link_options(yage_core PRIVATE
        "LINKER:-z,max-page-size=16384"
        "LINKER:-z,common-page-size=16384"
    )
endif()
