# srps4_inject_genesis.cmake — build a segagenesisrecomp title for the PS4
# from the title's OWN top-level CMakeLists.txt.
#
# Genesis titles (mstan's *Recomp repos on segagenesisrecomp) address their
# files through CMAKE_SOURCE_DIR, so they cannot be add_subdirectory()'d the
# way generic snesrecomp titles are. Instead the title is configured as the
# top-level project and this file is injected right after its project() call:
#
#   openorbis-cmake -S <title repo> -B <build> -G Ninja \
#       -DCMAKE_PROJECT_INCLUDE=<this file> -DSRPS4_PROFILE_DIR=<games/<id>> \
#       -DSRPS4_HOST_TOOLS_DIR=<native build of the same repo> ...
#
# It forces the release configuration (no trace server, reverse debugging,
# co-simulation, netplay or tests), points the build at host-built generator
# tools (the cross build cannot run its own), swaps in the launcher stub and,
# once the title has defined its targets, adds the PS4 host layer to the one
# target named by the profile and packages it.

get_property(_srps4_injected GLOBAL PROPERTY SRPS4_INJECTED)
if(_srps4_injected)
    return()   # CMAKE_PROJECT_INCLUDE runs for every project() call
endif()
set_property(GLOBAL PROPERTY SRPS4_INJECTED ON)

get_filename_component(SRPS4_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(SRPS4_ROOT "${SRPS4_ROOT}" CACHE INTERNAL "")
if(NOT SRPS4_PROFILE_DIR OR NOT EXISTS "${SRPS4_PROFILE_DIR}/profile.cmake")
    message(FATAL_ERROR "srps4: set -DSRPS4_PROFILE_DIR=<games/<id>> (with profile.cmake)")
endif()
include("${SRPS4_PROFILE_DIR}/profile.cmake")
enable_language(CXX)
enable_language(ASM)

if(PS4)
    set(SRPS4_TARGET_PS4 ON)
    add_compile_definitions(SRPS4=1 SRPS4_CONSOLE=1)
else()
    set(SRPS4_TARGET_PS4 OFF)
    add_compile_definitions(SRPS4=1 SRPS4_CONSOLE=0)
endif()
include("${SRPS4_ROOT}/cmake/srps4_helpers.cmake")

# --- release configuration ----------------------------------------------------
foreach(_off BUILD_TESTING GEN_ENABLE_TRACE GEN_DEV_TRACE SONIC_REVERSE_DEBUG
             GENESIS_BUILD_COSIM GENESISRECOMP_NETPLAY GENESISRECOMP_NET_ICE)
    set(${_off} OFF CACHE BOOL "" FORCE)
endforeach()
if(SRPS4_TARGET_PS4)
    # Whole-program IPO over ~90 MB of generated C is a desktop release step;
    # the console build compiles normally (-O3 + PGO from the profile).
    set(GENESIS_NATIVE_IPO OFF CACHE STRING "" FORCE)
endif()
set(SRPS4_RECOMP_UI_CMAKE "${SRPS4_ROOT}/cmake/recomp_ui_stub/recomp_ui.cmake" CACHE FILEPATH "" FORCE)
set(SRPS4_REAL_RECOMP_UI "${CMAKE_SOURCE_DIR}/recomp-ui" CACHE PATH "" FORCE)

# --- generator tools from the host build --------------------------------------
set(SRPS4_HOST_TOOLS_DIR "" CACHE PATH "Native build tree of the same title (generator tools)")
if(SRPS4_TARGET_PS4)
    if(NOT SRPS4_HOST_TOOLS_DIR OR NOT EXISTS "${SRPS4_HOST_TOOLS_DIR}/GenesisRecomp")
        message(FATAL_ERROR "srps4: -DSRPS4_HOST_TOOLS_DIR must name a native build with GenesisRecomp")
    endif()
    set(GENESIS_RECOMPILER_EXE "${SRPS4_HOST_TOOLS_DIR}/GenesisRecomp" CACHE FILEPATH "" FORCE)
    add_executable(M68kStepRecomp IMPORTED GLOBAL)
    set_target_properties(M68kStepRecomp PROPERTIES
        IMPORTED_LOCATION "${SRPS4_HOST_TOOLS_DIR}/M68kStepRecomp")
endif()

# --- after the title has defined its targets ----------------------------------
function(srps4_genesis_finalize)
    set(_tgt "${SRPS4_P_TARGET}")
    if(NOT TARGET ${_tgt})
        message(FATAL_ERROR "srps4: profile target '${_tgt}' is not defined by the title")
    endif()
    message(STATUS "srps4: Genesis profile, title target '${_tgt}'")
    srps4_add_host(${_tgt} WRAP_MAIN DATA_DIR "${SRPS4_P_DATA_DIR}" TITLE "${SRPS4_P_TITLE}")
    target_compile_definitions(${_tgt} PRIVATE
        SRPS4_ROM_NAME="${SRPS4_P_ROM_NAME}" SRPS4_ROM_POSITIONAL=1)
    if(EXISTS "${SRPS4_PROFILE_DIR}/post.cmake")
        include("${SRPS4_PROFILE_DIR}/post.cmake")
    endif()

    set(stage_files "${SRPS4_PROFILE_DIR}/version.txt=srps4/version.txt")
    if(EXISTS "${SRPS4_PROFILE_DIR}/env_defaults.txt")
        list(APPEND stage_files "${SRPS4_PROFILE_DIR}/env_defaults.txt=srps4/env_defaults.txt")
    endif()
    set(SRPS4_ROM "" CACHE FILEPATH "ROM to bundle (personal use)")
    if(SRPS4_ROM)
        list(APPEND stage_files "${SRPS4_ROM}=srps4/defaults/${SRPS4_P_ROM_NAME}")
    endif()
    set(stage_dirs "")
    if(EXISTS "${SRPS4_PROFILE_DIR}/defaults")
        list(APPEND stage_dirs "${SRPS4_PROFILE_DIR}/defaults=srps4/defaults")
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
endfunction()
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL srps4_genesis_finalize)
