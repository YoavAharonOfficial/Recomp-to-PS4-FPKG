# recomp_ui.cmake (snesrecomp-ps4 stub) — stands in for the shared recomp-ui
# launcher when a title's own CMakeLists is built for the console.
#
# The launcher is Dear ImGui on desktop GL / GLES2 with shaders compiled at
# run time; retail PS4 firmware has no shader compiler, and the console boots
# straight into the game anyway. Every recomp-ui entry point a title may call
# is defined here as a no-op, except that recomp_target_launcher_ui() still
# exposes the real checkout's headers (mod plugins use its C types) WITHOUT
# defining RECOMP_LAUNCHER, so the host's launcher block compiles out.
set(SRPS4_REAL_RECOMP_UI "" CACHE PATH "The title's real recomp-ui checkout (headers only)")
option(RECOMP_UI_ENABLE_MODS "accepted for compatibility; launcher is not built" OFF)
option(RECOMP_UI_SDL3 "accepted for compatibility" OFF)
enable_language(CXX)

function(recomp_target_launcher_language TGT LANGUAGE)
endfunction()
function(recomp_target_launcher_ui TGT)
    if(SRPS4_REAL_RECOMP_UI AND EXISTS "${SRPS4_REAL_RECOMP_UI}/src")
        target_include_directories(${TGT} PRIVATE
            "${SRPS4_REAL_RECOMP_UI}/src" "${SRPS4_REAL_RECOMP_UI}/src/common")
    endif()
    target_compile_definitions(${TGT} PRIVATE
        RECOMP_UI_ENABLE_MODS=0 SDL_MAIN_HANDLED)
    set_target_properties(${TGT} PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
endfunction()
function(recomp_target_runtime_ui_sdlrenderer2 TGT)
endfunction()
function(recomp_stage_launcher_assets TGT)
endfunction()
function(recomp_target_launcher_netplay TGT)
endfunction()
function(recomp_resolve_gl out_var)
    set(${out_var} "" PARENT_SCOPE)
endfunction()
