# Shared helpers for snesrecomp-ps4 game profiles.

set(SRPS4_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." CACHE INTERNAL "")

# srps4_add_host(<target> ENTRY <symbol>)
#   Adds the PS4 platform layer: our own main() (which prepares /data and then
#   calls the game's renamed desktop entry), the offline launcher stub, and the
#   PS4 system libraries SDL2 needs.
function(srps4_add_host target)
    cmake_parse_arguments(H "" "ENTRY;DATA_DIR;TITLE" "" ${ARGN})
    target_sources(${target} PRIVATE
        ${SRPS4_ROOT}/src/srps4_main.c
        ${SRPS4_ROOT}/src/srps4_paths.c
        ${SRPS4_ROOT}/src/srps4_log.c
        ${SRPS4_ROOT}/src/srps4_ucontext.c
        ${SRPS4_ROOT}/src/srps4_ucontext.S)

    target_include_directories(${target} PRIVATE ${SRPS4_ROOT}/src)
    # Route path-taking libc calls through srps4_paths.c (port-owned cwd).
    foreach(fn open stat lstat mkdir rename unlink rmdir truncate chdir getcwd)
        target_link_options(${target} PRIVATE "LINKER:--wrap=${fn}")
    endforeach()
    # Capture stdout/stderr at the stdio-call level (srps4_log.c): retail
    # firmware ignores freopen()/dup2() onto fds 1 and 2.
    foreach(fn fprintf vfprintf printf vprintf fputs puts fputc putc putchar
               fwrite perror fflush)
        target_link_options(${target} PRIVATE "LINKER:--wrap=${fn}")
    endforeach()
    if(NOT SRPS4_TARGET_PS4)
        # glibc's fortified __fprintf_chk & co. would bypass the wraps.
        target_compile_options(${target} PRIVATE -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0)
    endif()
    target_compile_definitions(${target} PRIVATE
        SRPS4_GAME_ENTRY=${H_ENTRY}
        SRPS4_DATA_DIR="${H_DATA_DIR}"
        SRPS4_TITLE="${H_TITLE}")
    if(SRPS4_TARGET_PS4)
        # Jaguar (btver2) codegen: AVX/SSE4.2/BMI, tuned for the console CPU.
        target_compile_options(${target} PRIVATE -march=btver2 -O2)
        # SDL2 (PacBrew) is static; its PS4 backends call into these system
        # modules. Order matters for single-pass resolution, so keep it in a
        # group (the toolchain's link rule already wraps --start-group).
        target_link_libraries(${target} PRIVATE
            SceSystemService SceSysUtil SceSysmodule SceUserService
            SceAudioOut ScePad ScePigletv2VSH SceVideoOut SceNet)
    endif()
endfunction()

# srps4_package(<target> TITLE_ID CUSA..... TITLE "..." VERSION "01.00"
#               ICON <png> [PIC <png>] STAGE_FILES <src>=<dst> ...)
#   eboot.bin + param.sfo + gp4 -> fake PKG (GoldHEN-installable).
function(srps4_package target)
    cmake_parse_arguments(P "" "TITLE_ID;TITLE;VERSION;ICON;PIC;LABEL" "STAGE_FILES;STAGE_DIRS" ${ARGN})
    set(stage "${CMAKE_BINARY_DIR}/pkg_${target}")
    set(sdk "$ENV{OPENORBIS}")
    set(pkgtool "${sdk}/bin/linux/PkgTool.Core")
    string(LENGTH "${P_LABEL}" _ll)
    if(NOT _ll EQUAL 16)
        message(FATAL_ERROR "srps4_package: LABEL must be exactly 16 chars (got '${P_LABEL}')")
    endif()
    set(content_id "IV0000-${P_TITLE_ID}_00-${P_LABEL}")
    set(sfo "${stage}/sce_sys/param.sfo")
    # Payload staging is shared: the native smoke test runs against the very
    # same tree (SRPS4_PKG_DIR=<build>/pkg_<target>) that becomes /app0.
    set(cmds
        COMMAND ${CMAKE_COMMAND} -E rm -rf "${stage}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${stage}/srps4")
    foreach(pair IN LISTS P_STAGE_FILES)
        string(REPLACE "=" ";" kv "${pair}")
        list(GET kv 0 src)
        list(GET kv 1 dst)
        get_filename_component(dstdir "${stage}/${dst}" DIRECTORY)
        list(APPEND cmds
            COMMAND ${CMAKE_COMMAND} -E make_directory "${dstdir}"
            COMMAND ${CMAKE_COMMAND} -E copy "${src}" "${stage}/${dst}")
    endforeach()
    foreach(pair IN LISTS P_STAGE_DIRS)
        string(REPLACE "=" ";" kv "${pair}")
        list(GET kv 0 src)
        list(GET kv 1 dst)
        list(APPEND cmds COMMAND ${CMAKE_COMMAND} -E copy_directory "${src}" "${stage}/${dst}")
    endforeach()
    if(NOT SRPS4_TARGET_PS4)
        add_custom_target(${target}_stage ALL ${cmds}
            DEPENDS ${target} WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
            COMMENT "Staging the package payload for the native smoke test" VERBATIM)
        return()
    endif()
    # Program authority ID + auth info exactly as PacBrew's ps4.cmake add_self()
    # signs its apps. create-fself's defaults (paid 0x...11, no authinfo) give
    # a process that cannot map system flexible memory: the mini-app malloc
    # crashed before main and Piglet's eglGetDisplay() returned EGL_NO_DISPLAY.
    set(SRPS4_PAID "0x3800000000000035")
    set(SRPS4_AUTHINFO "000000000000000000000000001C004000FF000000000080000000000000000000000000000000000000008000400040000000000000008000000000000000080040FFFF000000F000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    list(APPEND cmds
        COMMAND ${CMAKE_COMMAND} -E make_directory "${stage}/sce_sys/about" "${stage}/sce_module"
        COMMAND ${CMAKE_COMMAND} -E env "OO_PS4_TOOLCHAIN=${sdk}"
                "${sdk}/bin/create-fself" "-in=$<TARGET_FILE:${target}>"
                "-out=${CMAKE_BINARY_DIR}/${target}.oelf" "--eboot" "${stage}/eboot.bin"
                "--paid" "${SRPS4_PAID}" "--authinfo" "${SRPS4_AUTHINFO}"
        COMMAND ${CMAKE_COMMAND} -E copy "${sdk}/bin/data/modules/libc.prx" "${stage}/sce_module/libc.prx"
        COMMAND ${CMAKE_COMMAND} -E copy "${sdk}/bin/data/modules/libSceFios2.prx" "${stage}/sce_module/libSceFios2.prx"
        COMMAND ${CMAKE_COMMAND} -E copy "${sdk}/bin/data/modules/right.sprx" "${stage}/sce_sys/about/right.sprx"
        COMMAND ${CMAKE_COMMAND} -E copy "${P_ICON}" "${stage}/sce_sys/icon0.png")
    if(P_PIC)
        list(APPEND cmds COMMAND ${CMAKE_COMMAND} -E copy "${P_PIC}" "${stage}/sce_sys/pic1.png")
    endif()
    set(env ${CMAKE_COMMAND} -E env DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1)
    list(APPEND cmds
        COMMAND ${env} ${pkgtool} sfo_new "${sfo}"
        COMMAND ${env} ${pkgtool} sfo_setentry "${sfo}" APP_TYPE --type Integer --maxsize 4 --value 1
        COMMAND ${env} ${pkgtool} sfo_setentry "${sfo}" APP_VER --type Utf8 --maxsize 8 --value "${P_VERSION}"
        COMMAND ${env} ${pkgtool} sfo_setentry "${sfo}" ATTRIBUTE --type Integer --maxsize 4 --value 0
        COMMAND ${env} ${pkgtool} sfo_setentry "${sfo}" CATEGORY --type Utf8 --maxsize 4 --value gd
        COMMAND ${env} ${pkgtool} sfo_setentry "${sfo}" CONTENT_ID --type Utf8 --maxsize 48 --value "${content_id}"
        COMMAND ${env} ${pkgtool} sfo_setentry "${sfo}" DOWNLOAD_DATA_SIZE --type Integer --maxsize 4 --value 0
        COMMAND ${env} ${pkgtool} sfo_setentry "${sfo}" SYSTEM_VER --type Integer --maxsize 4 --value 0
        COMMAND ${env} ${pkgtool} sfo_setentry "${sfo}" TITLE --type Utf8 --maxsize 128 --value "${P_TITLE}"
        COMMAND ${env} ${pkgtool} sfo_setentry "${sfo}" TITLE_ID --type Utf8 --maxsize 12 --value "${P_TITLE_ID}"
        COMMAND ${env} ${pkgtool} sfo_setentry "${sfo}" VERSION --type Utf8 --maxsize 8 --value "${P_VERSION}"
        COMMAND "${sdk}/bin/linux/create-gp4" -out "${stage}/${target}.gp4"
                --content-id "${content_id}" --path "${stage}"
        COMMAND ${env} ${pkgtool} pkg_build "${stage}/${target}.gp4" "${CMAKE_BINARY_DIR}")
    add_custom_target(${target}_pkg ALL ${cmds}
        DEPENDS ${target}
        WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
        COMMENT "Packaging ${content_id}.pkg"
        VERBATIM)
    set_property(TARGET ${target} PROPERTY SRPS4_CONTENT_ID "${content_id}")
endfunction()
