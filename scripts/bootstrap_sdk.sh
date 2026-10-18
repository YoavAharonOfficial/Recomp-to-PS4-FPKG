#!/usr/bin/env bash
# bootstrap_sdk.sh — build the PS4 homebrew SDK this port uses, from source,
# in PacBrew's layout (OpenOrbis toolchain + musl + libc++ 12 + SDL2/Piglet).
#
#   scripts/bootstrap_sdk.sh [SDK_DIR] [WORK_DIR]
#
# Defaults: SDK_DIR=$HOME/ps4sdk  WORK_DIR=$HOME/ps4sdk-src
# Needs: clang/lld/llvm-ar (any recent LLVM; tested with 18), cmake, ninja,
#        git, go, dotnet-sdk-8.0, python3.
#
# Why not the prebuilt OpenOrbis release? It works too (point SRPS4_SDK at a
# PacBrew install). This script exists so the whole chain is reproducible from
# git sources alone, and it fixes three things that matter for C++ titles:
#   * libc++ is built against the same musl and triple the game uses;
#   * libSceLibcInternal's stub is trimmed to symbols our static runtime does
#     NOT provide, so operator new, __cxa_*, _Unwind_*, locale and wide-char
#     functions bind to libc++/musl instead of Sony's (16-bit wchar_t) libc;
#   * CFLAGS/CXXFLAGS are kept out of CMake builds (see scripts/env.sh).
set -euo pipefail

SDK="${1:-$HOME/ps4sdk}"
WORK="${2:-$HOME/ps4sdk-src}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$SDK"/{bin/linux,bin/data/modules,lib,include,usr/include,usr/lib,usr/bin,cmake} "$WORK"
cd "$WORK"

clone() { # url dir [ref]
  [ -d "$2/.git" ] && return 0
  if [ -n "${3:-}" ]; then
    git clone -q --filter=blob:none "$1" "$2" && git -C "$2" checkout -q "$3"
  else
    git clone -q --depth 1 "$1" "$2"
  fi
}

echo "== sources"
clone https://github.com/OpenOrbis/OpenOrbis-PS4-Toolchain oo
clone https://github.com/OpenOrbis/create-fself create-fself
clone https://github.com/OpenOrbis/create-gp4 create-gp4
clone https://github.com/OpenOrbis/orbis-lib-gen orbis-lib-gen
clone https://github.com/OpenOrbis/LibOrbisPkg LibOrbisPkg
clone https://github.com/PacBrew/ps4-openorbis pacbrew                     # recipes + patches
clone https://github.com/PacBrew/ps4-openorbis-musl musl 140a653299ffcb1457bc63a5ab1f507d7bb37c54
clone https://github.com/PacBrew/SDL sdl bf797a5315c7dbc0757d8ae7228e2dff1bf370cb
[ -d ps4libdoc/.git ] || git clone -q --depth 1 -b 5.05 https://github.com/idc/ps4libdoc ps4libdoc
if [ ! -d llvm12/.git ]; then
  git clone -q --depth 1 -b llvmorg-12.0.1 --filter=blob:none --sparse https://github.com/llvm/llvm-project llvm12
  git -C llvm12 sparse-checkout set compiler-rt libunwind libcxx libcxxabi llvm/cmake llvm/utils/llvm-lit
  sed 's|llvm-project-12.0.1.src-ps4/|b/|g; s|llvm-project-12.0.1.src/|a/|g' \
      pacbrew/libcxx/001-ps4.patch > libcxx-ps4.patch
  git -C llvm12 apply -p2 --exclude='llvm/*' ../libcxx-ps4.patch
fi

echo "== host tools into $SDK/bin"
for t in clang clang++ ld.lld llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-strip; do
  ln -sf "$(command -v $t)" "$SDK/bin/$t"
done
cp pacbrew/vars/ps4.cmake "$SDK/cmake/"
install -m755 pacbrew/vars/openorbis-cmake "$SDK/usr/bin/"
sed -e "s|^export PACBREW=.*|export PACBREW=$(dirname "$SDK")|" \
    -e "s|^export OPENORBIS=.*|export OPENORBIS=$SDK|" \
    -e "s|^export OO_PS4_TOOLCHAIN=.*|export OO_PS4_TOOLCHAIN=$SDK|" \
    -e "s|^export PS4SDK=.*|export PS4SDK=$SDK|" pacbrew/vars/ps4vars.sh > "$SDK/ps4vars.sh"
cp oo/link.x "$SDK/"
cp -r oo/include/* "$SDK/include/"

echo "== create-fself / create-gp4 / PkgTool.Core"
( cd create-fself/cmd/create-fself
  # upstream go.mod points its replace directives at Windows paths
  sed -i -E 's#(pkg/fself =>).*#\1 ../../pkg/fself#; s#(pkg/oelf =>).*#\1 ../../pkg/oelf#' go.mod
  GOFLAGS=-mod=mod go build -o "$SDK/bin/create-fself" . )
cp "$SDK/bin/create-fself" "$SDK/bin/linux/create-fself"
( cd create-gp4/cmd/create-gp4 && go build -o "$SDK/bin/linux/create-gp4" . )
mkdir -p "$WORK/emptyfeed"
DOTNET_CLI_TELEMETRY_OPTOUT=1 dotnet publish LibOrbisPkg/PkgTool.Core/PkgTool.Core.csproj \
    -c Release -o "$SDK/bin/linux" --source "$WORK/emptyfeed" >/dev/null

echo "== musl (PacBrew fork, flexible memory)"
# libkernel implements pthreads with FreeBSD libthr's ABI, where the attr
# objects are pointers and pthread_once_t is { int; pthread_mutex_t } (16 B).
# Upstream musl's 4-byte pthread_{mutex,cond,barrier}attr_t / pthread_once_t
# let libkernel write past the caller's object: stack/static corruption that
# shows up as clobbered callee-saved registers (found running this port in
# shadPS4: SDL_CreateMutex trashed the caller's rbx).
python3 - "$WORK/musl" <<'PYEOF'
import sys, os
root = sys.argv[1]
p = os.path.join(root, "include/alltypes.h.in")
s = open(p).read()
rep = {
 "TYPEDEF int pthread_once_t;": "TYPEDEF struct { int __state; void *__mutex; } pthread_once_t;",
 "TYPEDEF struct { unsigned __attr; } pthread_mutexattr_t;": "TYPEDEF struct { unsigned long __attr; } pthread_mutexattr_t;",
 "TYPEDEF struct { unsigned __attr; } pthread_condattr_t;": "TYPEDEF struct { unsigned long __attr; } pthread_condattr_t;",
 "TYPEDEF struct { unsigned __attr; } pthread_barrierattr_t;": "TYPEDEF struct { unsigned long __attr; } pthread_barrierattr_t;",
}
for a, b in rep.items():
    if a in s: s = s.replace(a, b)
open(p, "w").write(s)
p = os.path.join(root, "include/pthread.h")
s = open(p).read()
s = s.replace("#define PTHREAD_ONCE_INIT 0", "#define PTHREAD_ONCE_INIT { 0, 0 }")
open(p, "w").write(s)
PYEOF
# Do NOT add -DPS4_FLEXIBLE_MEMORY: PacBrew's opt-in "mini app" heap maps
# 2.5 GiB of system flexible memory on the first malloc and fails silently
# (NULL mspace) in a normal game-type fpkg, which segfaults before main
# (CE-34878-0). musl's default mmap-backed malloc is what PacBrew apps use.
( cd musl && ./configure --target=x86_64-scei-ps4 --prefix="$SDK" --disable-shared CC="$SDK/bin/clang" \
      CFLAGS="-fPIC -DPS4 -D_LIBUNWIND_IS_BAREMETAL=1" >/dev/null &&
  make -j"$(nproc)" >/dev/null && make install >/dev/null )
"$SDK/bin/clang" -c -o "$SDK/lib/crtlib.o" oo/src/crt/crtlib.c

echo "== compiler-rt builtins"
mkdir -p rtb && rm -f rtb/*.o
( cd llvm12/compiler-rt/lib/builtins
  for f in *.c x86_64/*.c x86_64/*.S; do
    case "$f" in emutls.c|enable_execute_stack.c|clear_cache.c|os_version_check.c|gcc_personality_v0.c|eprintf.c|trampoline_setup.c|*arm*|*ppc*) continue;; esac
    "$SDK/bin/clang" -fPIC -O2 -D__PS4__ --sysroot="$SDK" -nostdinc -isystem "$SDK/include" \
      -isystem "$(clang -print-resource-dir)/include" -w -c "$f" -o "$WORK/rtb/$(echo "$f" | tr / _).o"
  done )
llvm-ar rcs "$SDK/lib/libclang_rt.builtins-x86_64.a" rtb/*.o

echo "== libunwind / libc++abi / libc++ 12.0.1 (+PacBrew PS4 patch)"
L="$WORK/llvm12"
COMMON=(-G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DLLVM_COMPILER_CHECKED=ON -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_C_COMPILER="$SDK/bin/clang" -DCMAKE_CXX_COMPILER="$SDK/bin/clang++"
        -DLLVM_PATH="$L/llvm" -DLLVM_CONFIG_PATH=/nonexistent
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCMAKE_INSTALL_PREFIX="$SDK")
F="-fPIC -D__PS4__ -D_LIBUNWIND_IS_BAREMETAL=1 --sysroot=$SDK"
build_rt() { # dir extra-cmake-args...
  local d="$1"; shift
  rm -rf "$L/$d/build" && mkdir "$L/$d/build"
  cmake -S "$L/$d" -B "$L/$d/build" "${COMMON[@]}" "$@" >/dev/null
  ninja -C "$L/$d/build" >/dev/null && ninja -C "$L/$d/build" install >/dev/null
}
build_rt libunwind -DCMAKE_C_FLAGS="$F" -DCMAKE_CXX_FLAGS="$F" -DLIBUNWIND_USE_COMPILER_RT=YES \
    -DLIBUNWIND_ENABLE_STATIC=ON -DLIBUNWIND_ENABLE_SHARED=OFF
build_rt libcxxabi -DCMAKE_C_FLAGS="$F" -DCMAKE_CXX_FLAGS="$F" -DLIBCXXABI_ENABLE_SHARED=NO \
    -DLIBCXXABI_ENABLE_STATIC=YES -DLIBCXXABI_ENABLE_EXCEPTIONS=YES -DLIBCXXABI_USE_COMPILER_RT=YES \
    -DLIBCXXABI_USE_LLVM_UNWINDER=YES -DLIBCXXABI_ENABLE_PIC=YES \
    -DLIBCXXABI_LIBUNWIND_PATH="$L/libunwind" -DLIBCXXABI_LIBCXX_INCLUDES="$L/libcxx/include"
build_rt libcxx -DCMAKE_C_FLAGS="-fPIC -D__PS4__ --sysroot=$SDK" -DCMAKE_CXX_FLAGS="-fPIC -D__PS4__ --sysroot=$SDK" \
    -DLIBCXX_ENABLE_RTTI=YES -DLIBCXX_HAS_MUSL_LIBC=1 -DLIBCXX_HAS_GCC_S_LIB=0 -DLIBCXX_ENABLE_SHARED=NO \
    -DLIBCXX_ENABLE_THREADS=1 -DLIBCXX_HAS_THREAD_API_PTHREAD=1 -DLIBCXX_CXX_ABI=libcxxabi \
    -DLIBCXX_CXX_ABI_INCLUDE_PATHS="$L/libcxxabi/include" -DLIBCXX_CXX_ABI_LIBRARY_PATH="$L/libcxxabi/build/lib" \
    -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON -DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLIBCXX_INCLUDE_TESTS=OFF
( cd "$SDK/lib" && printf 'CREATE libc++M.a\nADDLIB libunwind.a\nADDLIB libc++abi.a\nADDLIB libc++.a\nSAVE\nEND\n' |
  llvm-ar -M && mv libc++M.a libc++.a )

echo "== system library stubs (ps4libdoc 5.05)"
( cd orbis-lib-gen && rm -rf build && python3 generate.py ../ps4libdoc/system/common/lib >/dev/null &&
  cd build && for c in *.c; do
    n="${c%.c}"
    case "$n" in libc) continue;; esac          # Sony libc: musl replaces it
    if [ "$n" = libSceLibcInternal ]; then
      # Keep only what the static runtime lacks (mainly the sceLibcMspace*
      # heap musl's malloc sits on).
      grep -oE '^void [A-Za-z0-9_]+\(\)' "$c" | sed 's/void //; s/()//' > all.txt
      for a in libc.a libc++.a libclang_rt.builtins-x86_64.a; do
        llvm-nm --defined-only -g "$SDK/lib/$a" 2>/dev/null | awk 'NF==3 && $2 ~ /[TDBRVWiu]/ {print $3}'
      done | sort -u > static.txt
      grep -Fxvf static.txt all.txt | grep -vE '^(__sync_|__atomic_)' |
        sed 's/.*/void &() { for(;;){} }/' > "${n}_trimmed.c"
      c="${n}_trimmed.c"
    fi
    clang -shared -ffreestanding -nostdlib -fno-builtin -fPIC -w "$c" -o "$SDK/lib/$n.so" || echo "stub failed: $n"
  done )

echo "== stub modules (libc.prx, libSceFios2.prx, right.sprx)"
( export OO_PS4_TOOLCHAIN="$SDK" PATH="$SDK/bin:$PATH"
  cd oo/src/modules
  for m in libc libSceFios2 right; do (cd "$m" && make clean >/dev/null 2>&1; make >/dev/null 2>&1); done
  cp libc/libc.prx libSceFios2/libSceFios2.prx right/right.sprx "$SDK/bin/data/modules/" )

echo "== SDL2 2.0.18 (PacBrew, GLES2 via Piglet)"
# PacBrew forces libsamplerate ON for PS4, and its header probe can see the
# *host's* /usr/include/samplerate.h, which bakes `-lsamplerate` (no PS4 build
# exists in this SDK) into SDL2's link interface. The snesrecomp host resamples
# 32040 Hz itself, so SDL's resampler is unused: force it off.
sed -i 's/^\(\s*\)set(SDL_LIBSAMPLERATE ON)/\1set(SDL_LIBSAMPLERATE OFF)/' sdl/CMakeLists.txt
# Port patches to the PS4 video driver (Piglet in app flexible memory; SDL's
# PS4 log callback through stdio so it reaches the host log). Idempotent.
for p in "$HERE"/../patches/sdl/*.patch; do
  git -C sdl apply --reverse --check "$p" 2>/dev/null || git -C sdl apply "$p"
done
( . "$SDK/ps4vars.sh"
  rm -rf sdl/build && openorbis-cmake -S sdl -B sdl/build -G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_INSTALL_PREFIX="$SDK/usr" -DCMAKE_BUILD_TYPE=Release -DSDL_TEST=OFF \
      -DHAVE_GCC_WERROR_DECLARATION_AFTER_STATEMENT=OFF >/dev/null &&
  ninja -C sdl/build >/dev/null && ninja -C sdl/build install >/dev/null )

echo "SDK ready at $SDK  (source scripts/env.sh with SRPS4_SDK=$SDK)"
