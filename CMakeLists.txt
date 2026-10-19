# snesrecomp-ps4 — PS4 (OpenOrbis / GoldHEN fpkg) host for snesrecomp titles.
#
# One build definition for every snesrecomp game. The game recomp repo is
# consumed unmodified except for the small, #ifdef __PS4__-guarded patch set in
# patches/; everything PS4-specific lives here.
#
#   PS4:    source scripts/env.sh; openorbis-cmake -S . -B build-ps4 -G Ninja \
#               -DSRPS4_GAME=megamanx -DSRPS4_GAME_ROOT=/path/to/MegaManXSNESRecomp
#   Native: cmake -S . -B build-native -G Ninja -DSRPS4_GAME=megamanx \
#               -DSRPS4_GAME_ROOT=... (same code path minus PS4 packaging; used
#               to smoke-test the port headlessly before it goes to a console)
cmake_minimum_required(VERSION 3.20)
project(snesrecomp_ps4 LANGUAGES C CXX ASM)
set(CMAKE_C_STANDARD 11)

set(SRPS4_GAME "" CACHE STRING "Game profile under games/ (e.g. megamanx)")
set(SRPS4_GAME_ROOT "" CACHE PATH "Path to the game's recomp repository")
if(NOT SRPS4_GAME OR NOT SRPS4_GAME_ROOT)
    message(FATAL_ERROR "Set -DSRPS4_GAME=<profile> and -DSRPS4_GAME_ROOT=<recomp repo>")
endif()
set(SRPS4_PROFILE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/games/${SRPS4_GAME}")
if(NOT EXISTS "${SRPS4_PROFILE_DIR}/game.cmake")
    message(FATAL_ERROR "No profile at ${SRPS4_PROFILE_DIR}/game.cmake")
endif()

# --- Framework options: the console build is offline, launcher-free and lean --
# The SDL3 PS4 port is NDA-only; the open SDL2 port (PacBrew, GLES2 via Piglet)
# is what we link, and snesrecomp still ships a supported SDL2 backend.
set(SNESRECOMP_SDL_BACKEND "SDL2" CACHE STRING "" FORCE)
set(SNESRECOMP_ENABLE_NET OFF CACHE BOOL "" FORCE)
set(SNESRECOMP_NET_ICE OFF CACHE BOOL "" FORCE)
set(SNESRECOMP_ENABLE_LUA OFF CACHE BOOL "" FORCE)
set(SNESRECOMP_ENABLE_TRACE OFF CACHE BOOL "" FORCE)
set(SNESRECOMP_ENABLE_MODS ON CACHE BOOL "" FORCE)
set(SNESRECOMP_SDL3_FETCH OFF CACHE BOOL "" FORCE)
set(RECOMP_UI_SDL3 OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)

if(PS4)
    set(SRPS4_TARGET_PS4 ON)
    add_compile_definitions(SRPS4=1 SRPS4_CONSOLE=1)
else()
    set(SRPS4_TARGET_PS4 OFF)
    add_compile_definitions(SRPS4=1 SRPS4_CONSOLE=0)
endif()

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/srps4_helpers.cmake")
include("${SRPS4_PROFILE_DIR}/game.cmake")

# Native smoke builds: glibc's fortified __fprintf_chk & co. bypass the stdio
# wraps (srps4_log.c), so the separately built worker library is compiled
# unfortified too, keeping its diagnostics in last_run.txt as on the console.
if(TARGET snesrecomp_render_workers AND NOT SRPS4_TARGET_PS4)
    target_compile_options(snesrecomp_render_workers PRIVATE -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0)
endif()
