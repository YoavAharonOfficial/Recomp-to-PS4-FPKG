# Mega Man X (USA Rev 1) — mstan/MegaManXSNESRecomp on snesrecomp.
#
# Mirrors add_mmx_variant() from the game's own CMakeLists.txt, minus the
# desktop-only pieces: the ImGui launcher, netplay and the ROM path cache.

set(G "${SRPS4_GAME_ROOT}")
set(SRPS4_MMX_VERSION "01.00" CACHE STRING "Package version shown on the PS4")

find_package(Python3 COMPONENTS Interpreter REQUIRED)
find_package(Git QUIET)
execute_process(COMMAND "${GIT_EXECUTABLE}" rev-parse --short=12 HEAD
    WORKING_DIRECTORY "${G}" OUTPUT_VARIABLE MMX_SOURCE_REVISION
    OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT MMX_SOURCE_REVISION)
    set(MMX_SOURCE_REVISION "unknown")
endif()
set_property(SOURCE "${G}/src/mmx_replay.c" APPEND PROPERTY COMPILE_DEFINITIONS
    MMX_REPLAY_REVISION="${MMX_SOURCE_REVISION}" MMX_REPLAY_ENGINE="ps4")
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/mmx_weapon_sources.h"
    COMMAND ${Python3_EXECUTABLE} "${G}/tools/generate_x_weapon_tables.py"
        "${G}/tools/data/x_weapon_assets.json"
        "${CMAKE_CURRENT_BINARY_DIR}/mmx_weapon_sources.h"
    DEPENDS "${G}/tools/generate_x_weapon_tables.py" "${G}/tools/data/x_weapon_assets.json"
    VERBATIM)

set(SNESRECOMP_BUILD_VERSION "ps4-${SRPS4_MMX_VERSION}" CACHE STRING "" FORCE)
set(SNESRECOMP_ROOT "${G}/snesrecomp" CACHE PATH "" FORCE)
include(${SNESRECOMP_ROOT}/runner/runner.cmake)

# The PS4 default config: the game's own defaults with console-appropriate
# overrides layered on top (see config_ps4.ini).
file(READ "${G}/config.ini" _config)
file(READ "${SRPS4_PROFILE_DIR}/config_ps4.ini" _config_ps4)
set(SRPS4_MMX_CONFIG "${CMAKE_CURRENT_BINARY_DIR}/config.ini")
execute_process(COMMAND ${Python3_EXECUTABLE} "${SRPS4_ROOT}/scripts/merge_ini.py"
    "${G}/config.ini" "${SRPS4_PROFILE_DIR}/config_ps4.ini" "${SRPS4_MMX_CONFIG}"
    RESULT_VARIABLE _merge_rc)
if(NOT _merge_rc EQUAL 0)
    message(FATAL_ERROR "merge_ini.py failed")
endif()
file(READ "${SRPS4_MMX_CONFIG}" _config)
string(REPLACE "\\" "\\\\" _config "${_config}")
string(REPLACE "\"" "\\\"" _config "${_config}")
string(REPLACE "\r" "" _config "${_config}")
string(REPLACE "\n" "\\n\"\n\"" _config "${_config}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/mmx_default_config.h"
    "static const char kMmxDefaultConfig[] =\n\"${_config}\";\n")

set(TARGET MegaManX)
set(GEN_DIR "${G}/src/gen")
set(CFG_DIR "${G}/recomp")
add_executable(${TARGET} ${SNESRECOMP_RUNNER_SOURCES}
    ${G}/src/main.c ${G}/src/mmx_startup.c ${G}/src/mmx_netplay.c ${G}/src/mmx_display.c
    ${G}/src/mmx_renderer.c ${G}/src/mmx_render_assets.c ${G}/src/mmx_wide_policy.c
    ${G}/src/mmx_00.c ${G}/src/gen_stubs.c ${G}/src/mmx_cpu_infra.c ${G}/src/mmx_rtl.c
    ${G}/src/mmx_spc_player.c ${G}/src/mmx_replay.c ${G}/src/mods/mmx_diagnostics_plugin.c
    ${G}/src/mods/mmx_widescreen_plugin.c ${G}/src/mods/mmx_msu1_plugin.c
    ${G}/src/mods/mmx_hadouken_plugin.c ${G}/src/mods/mmx_password_plugin.c
    ${G}/src/mods/mmx_boss_rush_plugin.c ${G}/src/mmx_password_save.cpp
    ${G}/src/mods/mmx_zero_plugin.c ${G}/src/mmx_zero.c ${G}/src/mmx_weapons.c
    ${G}/src/mmx_weapon_combat.c ${G}/src/mmx_knc_bugfix.c ${G}/src/mmx_coop.c
    ${G}/src/mmx_coop_trace.c ${G}/src/mmx_coop_view.c ${G}/src/mmx_hitbox_overlay.c
    ${G}/src/mmx_boss_rush.c ${G}/src/mmx_boss_rush_audio.c ${G}/src/mmx_boss_rush_runtime.c
    ${G}/src/mmx_boss_rush_draw.c ${G}/src/mmx_boss_rush_score.cpp
    ${G}/src/mmx_source_assets.cpp "${CMAKE_CURRENT_BINARY_DIR}/mmx_weapon_sources.h")
target_compile_features(${TARGET} PRIVATE cxx_std_17)
target_include_directories(${TARGET} PRIVATE
    ${CFG_DIR} ${G}/src ${CMAKE_CURRENT_BINARY_DIR} ${SNESRECOMP_RUNNER_INCLUDE_DIRS}
    # Mod plugins use the launcher's C types (mod resources) even when the
    # launcher itself is not built; the header is self-contained.
    ${G}/recomp-ui/src)
target_compile_definitions(${TARGET} PRIVATE
    SMW_DISABLE_LM=1 SYSTEM_VOLUME_MIXER_AVAILABLE=0
    MMX_SOURCE_REVISION="${MMX_SOURCE_REVISION}"
    SNESRECOMP_BUILD_VERSION="${SNESRECOMP_BUILD_VERSION}"
    SNESRECOMP_TRACE=0 SNESRECOMP_REVERSE_DEBUG=0
    MMX_DESKTOP_ENTRY=mmx_desktop_main)
target_compile_options(${TARGET} PRIVATE $<$<COMPILE_LANGUAGE:C>:-Wno-implicit-function-declaration>)
target_link_libraries(${TARGET} PRIVATE ${SNESRECOMP_RUNNER_LIBRARIES})
snesrecomp_target_sdl(${TARGET})
snesrecomp_target_fiber_compat(${TARGET})
snesrecomp_target_desktop_host(${TARGET} TIER2)
snesrecomp_target_generated_code(${TARGET} ${GEN_DIR})
snesrecomp_target_mod_catalog(${TARGET} "${G}/mods/preloaded")
include("${SRPS4_PROFILE_DIR}/saber.cmake")
# Composition pass of the widescreen renderer on snesrecomp's worker pool
# (see games/megamanx/patches/0002-*). SNESRECOMP_RENDER_WORKERS=1 forces the
# original serial path at runtime.
include(${SNESRECOMP_RUNNER_ROOT}/render_workers.cmake)
snesrecomp_target_render_workers(${TARGET})
set_property(SOURCE "${G}/src/mmx_renderer.c" APPEND PROPERTY COMPILE_DEFINITIONS MMX_RENDER_PARALLEL=1)

# The game's generated-code mod hooks (widescreen, password, Zero, weapons,
# co-op, boss rush) are applied to src/gen in place, exactly as upstream does.
file(GLOB mmx_generated ${GEN_DIR}/*.c)
add_custom_target(${TARGET}_hooks
    COMMAND ${Python3_EXECUTABLE} ${G}/tools/apply_overrides.py --gen-dir ${GEN_DIR}
    COMMAND ${Python3_EXECUTABLE} ${G}/tools/apply_renderer_capture.py --gen-dir ${GEN_DIR}
    COMMAND ${Python3_EXECUTABLE} ${G}/tools/apply_password_hooks.py --gen-dir ${GEN_DIR}
    COMMAND ${Python3_EXECUTABLE} ${G}/tools/apply_zero_hooks.py --gen-dir ${GEN_DIR}
    COMMAND ${Python3_EXECUTABLE} ${G}/tools/apply_weapon_hooks.py --gen-dir ${GEN_DIR}
    COMMAND ${Python3_EXECUTABLE} ${G}/tools/apply_coop_hooks.py --gen-dir ${GEN_DIR}
    COMMAND ${Python3_EXECUTABLE} ${G}/tools/apply_boss_rush_hooks.py --gen-dir ${GEN_DIR}
    WORKING_DIRECTORY ${G}
    COMMENT "Applying Mega Man X generated-code mod hooks" VERBATIM)
add_dependencies(${TARGET} ${TARGET}_hooks)

srps4_add_host(${TARGET} ENTRY mmx_desktop_main DATA_DIR "MegaManX" TITLE "Mega Man X")

# --- Package payload --------------------------------------------------------
# defaults/ : copied to /data/MegaManX once (player may edit afterwards)
# refresh/  : re-synced on every package version change
set(SRPS4_ROM "" CACHE FILEPATH "Mega Man X (USA) (Rev 1) .sfc to bundle (personal use)")
set(stage_files
    "${SRPS4_MMX_CONFIG}=srps4/defaults/config.ini"
    "${G}/logging.ini=srps4/defaults/logging.ini"
    "${SRPS4_PROFILE_DIR}/version.txt=srps4/version.txt")
if(SRPS4_ROM)
    list(APPEND stage_files "${SRPS4_ROM}=srps4/defaults/mmx.sfc")
endif()
set(stage_dirs
    "${G}/mods/preloaded/packages=srps4/refresh/${SNESRECOMP_MOD_CATALOG_DEST}"
    "${SNESRECOMP_RUNNER_ROOT}/assets/shaders=srps4/refresh/assets/shaders")
if(EXISTS "${SRPS4_PROFILE_DIR}/mods_state.toml")
    list(APPEND stage_files "${SRPS4_PROFILE_DIR}/mods_state.toml=srps4/defaults/mods/preloaded/state.toml")
endif()

srps4_package(${TARGET}
    TITLE_ID "MMXR00001" TITLE "Mega Man X Recompiled" VERSION "${SRPS4_MMX_VERSION}"
    LABEL "MEGAMANXRECOMP00"
    ICON "${SRPS4_PROFILE_DIR}/icon0.png"
    STAGE_FILES ${stage_files}
    STAGE_DIRS ${stage_dirs})
