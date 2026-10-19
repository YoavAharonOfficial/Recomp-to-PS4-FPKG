#!/bin/bash
# pgo_train.sh — build a profile-guided-optimization profile for the console
# build from native training runs.
#
# The console's compiler is clang 18, the same as the host's clang-18, so a
# profile recorded by an instrumented *native* build of the same sources is
# consumed by the PS4 build (-DSRPS4_PGO_PROFILE=<file>). The few functions
# that differ between the two (SRPS4_CONSOLE branches) are reported as
# mismatched and compiled without profile data; nothing else changes.
#
#   scripts/pgo_train.sh --game-root <recomp repo> --rom <rom> [--out file]
#
# Training input: the deterministic scripts in tests/ (intro, Highway with
# random input, Boss Rush), widescreen on, pipelined compose on.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT=""; ROM=""; OUT="$HERE/games/megamanx/pgo.profdata"; GAME=megamanx
while [ $# -gt 0 ]; do
  case "$1" in
    --game-root) ROOT="$2"; shift 2;;
    --rom) ROM="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --game) GAME="$2"; shift 2;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
done
[ -n "$ROOT" ] && [ -n "$ROM" ] || { echo "need --game-root and --rom" >&2; exit 2; }
B="$HERE/build-pgo-train"
FLAGS="-march=btver2 -fprofile-instr-generate"
cmake -S "$HERE" -B "$B" -G Ninja -DSRPS4_GAME="$GAME" -DSRPS4_GAME_ROOT="$ROOT" \
  -DSRPS4_ROM="$ROM" -DCMAKE_C_COMPILER=clang-18 -DCMAKE_CXX_COMPILER=clang++-18 \
  -DCMAKE_BUILD_TYPE=Release "-DCMAKE_C_FLAGS_RELEASE=-O2 -DNDEBUG" \
  "-DCMAKE_CXX_FLAGS_RELEASE=-O2 -DNDEBUG" "-DCMAKE_C_FLAGS=$FLAGS" \
  "-DCMAKE_CXX_FLAGS=$FLAGS" -DCMAKE_EXE_LINKER_FLAGS=-fprofile-instr-generate
ninja -C "$B"
RAW="$B/profraw"; rm -rf "$RAW"; mkdir -p "$RAW"
for s in "$HERE"/tests/*.script; do
  D=$(mktemp -d); mkdir -p "$D/MegaManX"; cp "$s" "$D/MegaManX/s.script"
  echo "training: $(basename "$s")"
  (cd "$D/MegaManX" && SRPS4_PKG_DIR="$B/pkg_MegaManX" SRPS4_DATA_ROOT="$D" \
     SDL_AUDIODRIVER=dummy MMX_RENDER_PIPELINE=1 LLVM_PROFILE_FILE="$RAW/%p.profraw" \
     xvfb-run -a -s "-screen 0 1920x1080x24" "$B/MegaManX" --script s.script \
     --benchmark 100000 >/dev/null 2>&1) || true
  rm -rf "$D"
done
llvm-profdata-18 merge -o "$OUT" "$RAW"/*.profraw 2>/dev/null || llvm-profdata merge -o "$OUT" "$RAW"/*.profraw
echo "profile: $OUT ($(du -h "$OUT" | cut -f1))"
