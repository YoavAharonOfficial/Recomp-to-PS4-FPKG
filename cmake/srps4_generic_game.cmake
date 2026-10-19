# srps4_generic_game.cmake — build ANY snesrecomp title for the console from
# the title's own CMakeLists.txt.
#
# A curated profile (games/megamanx/game.cmake) re-states a title's source
# list by hand. A generic profile instead adds the title's repository as a
# subdirectory and adapts what it defines:
#
#   * framework options are forced before the title configures (SDL2 backend,
#     no netplay/Lua/trace/tests), exactly as for curated titles;
#   * recomp-ui is replaced by a stub (cmake/recomp_ui_stub): the ImGui
#     launcher needs a run-time shader compiler the console does not have;
#   * the title's executable is found among the targets its directory
#     defines, and gets the PS4 host layer (srps4_add_host WRAP_MAIN: the
#     title's own main() is entered through --wrap=main, untouched);
#   * the package payload is assembled from the conventions every snesrecomp
#     title follows (config.ini, logging.ini, mods/preloaded/packages, the
#     framework's shader presets) plus the profile's own overrides.
#
# The profile directory provides profile.cmake (identity) and optional
# config_ps4.ini, defaults/ (files seeded into /data/<Title>/), env_defaults.txt
# and patches/ (applied by the converter before configuring).

include("${SRPS4_PROFILE_DIR}/profile.cmake")
foreach(v TITLE TITLE_ID LABEL DATA_DIR)
    if(NOT SRPS4_P_${v})
        message(FATAL_ERROR "profile.cmake must set SRPS4_P_${v}")
    endif()
endforeach()
if(NOT SRPS4_P_VERSION)
    set(SRPS4_P_VERSION "01.00")
endif()
set(G "${SRPS4_GAME_ROOT}")

# --- the title's own build, adapted -------------------------------------------
set(SRPS4_REAL_RECOMP_UI "${G}/recomp-ui" CACHE PATH "" FORCE)
set(RECOMP_UI_ROOT "${SRPS4_ROOT}/cmake/recomp_ui_stub" CACHE PATH "" FORCE)
set(SNESRECOMP_ROOT "${G}/snesrecomp" CACHE PATH "" FORCE)
set(SNESRECOMP_BUILD_VERSION "ps4-${SRPS4_P_VERSION}" CACHE STRING "" FORCE)
# Speed over reference fidelity for the console's slow CPU; correctness of
# both implementations is the framework's own contract.
set(SNESRECOMP_FRAME_IMPL "HLE" CACHE STRING "" FORCE)
add_subdirectory("${G}" srps4_game EXCLUDE_FROM_ALL)

# The title's executable: the profile may name it; otherwise the one
# executable target (tests are off) the title's directory defines.
set(_tgt "${SRPS4_P_TARGET}")
if(NOT _tgt)
    get_property(_targets DIRECTORY "${G}" PROPERTY BUILDSYSTEM_TARGETS)
    set(_exes "")
    foreach(t IN LISTS _targets)
        get_target_property(_type ${t} TYPE)
        if(_type STREQUAL "EXECUTABLE")
            list(APPEND _exes ${t})
        endif()
    endforeach()
    list(LENGTH _exes _n)
    if(NOT _n EQUAL 1)
        message(FATAL_ERROR "srps4: expected one executable in ${G}, found [${_exes}]; "
                            "set SRPS4_P_TARGET in profile.cmake")
    endif()
    set(_tgt ${_exes})
endif()
message(STATUS "srps4: generic profile, title target '${_tgt}'")
set_target_properties(${_tgt} PROPERTIES EXCLUDE_FROM_ALL OFF)
set(SRPS4_GAME_TARGET ${_tgt} CACHE INTERNAL "")

srps4_add_host(${_tgt} WRAP_MAIN DATA_DIR "${SRPS4_P_DATA_DIR}" TITLE "${SRPS4_P_TITLE}")
target_compile_definitions(${_tgt} PRIVATE SRPS4_ROM_NAME="rom.sfc")
# Title-specific build tweaks (e.g. putting a widescreen renderer on the
# worker pool) live in the profile, next to the patches they accompany.
if(EXISTS "${SRPS4_PROFILE_DIR}/post.cmake")
    include("${SRPS4_PROFILE_DIR}/post.cmake")
endif()
# Widescreen renderers that run on the framework's worker pool pin to cores
# 1-4 on the console (render_workers.c); nothing to do per title here.

# --- payload --------------------------------------------------------------------
find_package(Python3 COMPONENTS Interpreter REQUIRED)
set(_config "${CMAKE_CURRENT_BINARY_DIR}/srps4_config.ini")
set(_overlays "${SRPS4_ROOT}/games/_generic/config_ps4.ini")
if(EXISTS "${SRPS4_PROFILE_DIR}/config_ps4.ini")
    list(APPEND _overlays "${SRPS4_PROFILE_DIR}/config_ps4.ini")
endif()
set(_base "${G}/config.ini")
if(NOT EXISTS "${_base}")
    set(_base "${SRPS4_ROOT}/games/_generic/empty.ini")
endif()
set(_in "${_base}")
set(_i 0)
foreach(o IN LISTS _overlays)
    math(EXPR _i "${_i}+1")
    set(_out "${CMAKE_CURRENT_BINARY_DIR}/srps4_config_${_i}.ini")
    execute_process(COMMAND ${Python3_EXECUTABLE} "${SRPS4_ROOT}/scripts/merge_ini.py"
        "${_in}" "${o}" "${_out}" RESULT_VARIABLE _rc)
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "merge_ini.py failed on ${o}")
    endif()
    set(_in "${_out}")
endforeach()
configure_file("${_in}" "${_config}" COPYONLY)

set(stage_files
    "${_config}=srps4/defaults/config.ini"
    "${SRPS4_PROFILE_DIR}/version.txt=srps4/version.txt")
if(EXISTS "${G}/logging.ini")
    list(APPEND stage_files "${G}/logging.ini=srps4/defaults/logging.ini")
endif()
if(EXISTS "${SRPS4_PROFILE_DIR}/env_defaults.txt")
    list(APPEND stage_files "${SRPS4_PROFILE_DIR}/env_defaults.txt=srps4/env_defaults.txt")
endif()
set(SRPS4_ROM "" CACHE FILEPATH "ROM to bundle (personal use)")
if(SRPS4_ROM)
    list(APPEND stage_files "${SRPS4_ROM}=srps4/defaults/rom.sfc")
endif()
set(stage_dirs "")
if(EXISTS "${SRPS4_PROFILE_DIR}/defaults")
    list(APPEND stage_dirs "${SRPS4_PROFILE_DIR}/defaults=srps4/defaults")
endif()
if(NOT SNESRECOMP_MOD_CATALOG_DEST)
    set(SNESRECOMP_MOD_CATALOG_DEST "mods/preloaded/packages")   # runner.cmake's constant
endif()
if(EXISTS "${G}/mods/preloaded/packages")
    list(APPEND stage_dirs
        "${G}/mods/preloaded/packages=srps4/refresh/${SNESRECOMP_MOD_CATALOG_DEST}")
endif()
if(EXISTS "${SNESRECOMP_ROOT}/runner/assets/shaders")
    list(APPEND stage_dirs "${SNESRECOMP_ROOT}/runner/assets/shaders=srps4/refresh/assets/shaders")
endif()

set(_icon "${SRPS4_PROFILE_DIR}/icon0.png")
if(NOT EXISTS "${_icon}")
    set(_icon "${SRPS4_ROOT}/games/_generic/icon0.png")
endif()
srps4_package(${_tgt}
    TITLE_ID "${SRPS4_P_TITLE_ID}" TITLE "${SRPS4_P_TITLE}" VERSION "${SRPS4_P_VERSION}"
    LABEL "${SRPS4_P_LABEL}" ICON "${_icon}"
    STAGE_FILES ${stage_files}
    STAGE_DIRS ${stage_dirs})
