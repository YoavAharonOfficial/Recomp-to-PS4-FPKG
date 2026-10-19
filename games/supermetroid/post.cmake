# Super Metroid: the widescreen renderer's per-pixel composition runs on the
# framework's render worker pool (patches/0001-*), pinned to cores 1-4 on the
# console. SNESRECOMP_RENDER_WORKERS=1 restores the serial path at run time.
include("${SNESRECOMP_ROOT}/runner/render_workers.cmake")
snesrecomp_target_render_workers(${SRPS4_GAME_TARGET})
set_property(SOURCE "${SRPS4_GAME_ROOT}/src/sm_renderer.c" DIRECTORY "${SRPS4_GAME_ROOT}"
    APPEND PROPERTY COMPILE_DEFINITIONS SM_RENDER_PARALLEL=1)
