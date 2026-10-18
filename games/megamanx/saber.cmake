# Saber Zero: same sources and embedded sidecars as the game's cmake/saber.cmake,
# but its one build-time helper (the .ogg -> sidecar converter) is compiled
# with the HOST compiler via a custom command, so the PS4 cross build never
# tries to produce a PS4 binary it would then have to run.
set(S "${SRPS4_GAME_ROOT}")
set(SRPS4_HOST_CC "cc" CACHE STRING "Host C compiler for build-time tools")
set(_cache_dir "${CMAKE_CURRENT_BINARY_DIR}/cache/mmx-source")
set(_saber_cache "${_cache_dir}/saber-v1.bin")
set(_ride_cache "${_cache_dir}/ride-zero-v1.bin")
set(_sfx_cache "${_cache_dir}/saber-sfx-v2.bin")
set(_conv "${CMAKE_CURRENT_BINARY_DIR}/host-tools/mmx_saber_sfx_convert")
file(GLOB _sfx_inputs CONFIGURE_DEPENDS "${S}/assets/saber-zero/sfx/*.ogg")
file(GLOB _donor CONFIGURE_DEPENDS "${S}/assets/saber-zero/sprites/*.png")

add_custom_command(OUTPUT "${_conv}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/host-tools"
    COMMAND ${CMAKE_COMMAND} -E env --unset=CFLAGS --unset=LDFLAGS
        ${SRPS4_HOST_CC} -O2 -o "${_conv}"
        "${S}/tools/saber/mmx_saber_sfx_convert.c" "${S}/tools/saber/mmx_saber_sfx_codec.c"
        "${S}/tools/saber/third_party/stb_vorbis.c"
        -I "${S}/src/saber" -I "${S}/tools/saber" -lm
    DEPENDS "${S}/tools/saber/mmx_saber_sfx_convert.c" "${S}/tools/saber/mmx_saber_sfx_codec.c"
    VERBATIM)
add_custom_command(OUTPUT "${_sfx_cache}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_cache_dir}"
    COMMAND "${_conv}" --source-dir "${S}/assets/saber-zero/sfx" --out "${_sfx_cache}"
    DEPENDS "${_conv}" ${_sfx_inputs} WORKING_DIRECTORY "${S}" VERBATIM)
foreach(pair "saber;${_saber_cache}" "ride;${_ride_cache}")
    list(GET pair 0 kind)
    list(GET pair 1 out)
    if(kind STREQUAL "saber")
        set(manifest "${S}/tools/saber/saber_zero_manifest.json")
    else()
        set(manifest "${S}/tools/saber/ride_zero_manifest.json")
    endif()
    add_custom_command(OUTPUT "${out}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${_cache_dir}"
        COMMAND ${Python3_EXECUTABLE} -I "${S}/tools/saber/convert_saber_zero.py"
            --manifest "${manifest}" --source-dir "${S}/assets/saber-zero/sprites" --out "${out}"
        DEPENDS "${S}/tools/saber/convert_saber_zero.py" "${manifest}" ${_donor}
        WORKING_DIRECTORY "${S}" VERBATIM)
endforeach()
set(_embedded "${CMAKE_CURRENT_BINARY_DIR}/generated/mmx_saber_embedded.c")
add_custom_command(OUTPUT "${_embedded}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/generated"
    COMMAND ${CMAKE_COMMAND} "-DOUT=${_embedded}" "-DSABER=${_saber_cache}"
        "-DRIDE=${_ride_cache}" "-DSFX=${_sfx_cache}"
        -P "${S}/cmake/embed_saber_sidecars.cmake"
    DEPENDS "${_saber_cache}" "${_ride_cache}" "${_sfx_cache}" "${S}/cmake/embed_saber_sidecars.cmake"
    VERBATIM)
target_sources(${TARGET} PRIVATE "${_embedded}"
    ${S}/src/mods/mmx_saber_plugin.c ${S}/src/saber/mmx_saber_assets.c
    ${S}/src/saber/mmx_saber_wave.c ${S}/src/saber/mmx_saber_wave_assets.c
    ${S}/src/saber/mmx_saber_wave_runtime.c ${S}/src/saber/mmx_saber_sfx.c
    ${S}/src/saber/mmx_saber_input.c ${S}/src/saber/mmx_saber_combo.c
    ${S}/src/saber/mmx_saber_attack.c ${S}/src/saber/mmx_saber_priority.c
    ${S}/src/saber/mmx_saber_frame.c ${S}/src/saber/mmx_saber_hitbox_debug.c
    ${S}/src/saber/mmx_saber_render.c ${S}/src/saber/mmx_saber_tuning.c)
