#!/usr/bin/env bash
# pgo_train_genesis.sh — PGO profile for a segagenesisrecomp title's console
# build, from instrumented native runs of the title's own regression scripts.
#
#   scripts/pgo_train_genesis.sh --game sonic3k --game-root <title checkout>
#
# The console's clang is clang 18, the same as the host's clang-18, so a
# profile recorded by an instrumented native build of the same sources applies
# (-march=btver2 for the same code shapes). Functions that differ between the
# two builds (SRPS4 branches in the runner) are compiled without profile data.
# Needs the title's ROM already staged where profile.sh says (build_genesis.sh
# does that) and libclang-rt-18-dev for the profile runtime.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
GAME="" ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --game) GAME="$2"; shift 2;;
    --game-root) ROOT="$2"; shift 2;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
done
[ -n "$GAME" ] && [ -n "$ROOT" ] || { sed -n 2,12p "$0"; exit 2; }
PROFILE="$HERE/games/$GAME"
. "$PROFILE/profile.sh"
OUT="$PROFILE/pgo.profdata"
B="$ROOT/build-pgo"
# btver2 minus SSE4A: training hosts are often Intel (no EXTRQ/INSERTQ), and
# instrumentation counts are taken before codegen, so the profile still matches.
F="-march=btver2 -mno-sse4a -fprofile-instr-generate"
cmake -S "$ROOT" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang-18 -DCMAKE_CXX_COMPILER=clang++-18 \
    "-DCMAKE_C_FLAGS=$F" "-DCMAKE_CXX_FLAGS=$F" -DCMAKE_EXE_LINKER_FLAGS=-fprofile-instr-generate \
    -DBUILD_TESTING=OFF -DGEN_ENABLE_TRACE=OFF -DGEN_DEV_TRACE=OFF -DSONIC_REVERSE_DEBUG=OFF \
    -DGENESIS_BUILD_COSIM=OFF -DGENESISRECOMP_NETPLAY=OFF -DGENESISRECOMP_NET_ICE=OFF \
    -DGENESIS_NATIVE_IPO=OFF
ninja -C "$B" "$GAME_TARGET"
RAW="$B/profraw"; rm -rf "$RAW"; mkdir -p "$RAW"
# Train the configuration the console runs: the shipped settings files and
# environment defaults, plus the profile's PGO_ENV (e.g. renderer workers).
ENV=()
[ -f "$PROFILE/env_defaults.txt" ] && while IFS= read -r l; do
  case "$l" in ''|'#'*) ;; *) ENV+=("$l");; esac
done < "$PROFILE/env_defaults.txt"
for e in ${PGO_ENV:-}; do ENV+=("$e"); done
for s in $PGO_SCRIPTS; do
  D=$(mktemp -d)
  [ -d "$PROFILE/defaults" ] && cp -r "$PROFILE/defaults/." "$D/"
  echo "training: $s ($PGO_FRAMES frames)"
  (cd "$B" && env "${ENV[@]}" GENESIS_USER_DIR="$D" SDL_AUDIODRIVER=dummy LLVM_PROFILE_FILE="$RAW/%p.profraw" \
     xvfb-run -a -s "-screen 0 1920x1080x24" "./$GAME_TARGET" "$ROOT/$ROM_STAGE_NAME" \
     --benchmark "$PGO_FRAMES" --input-script "$ROOT/$s" >"$D.log" 2>&1) ||
     { echo "  run failed, see $D.log" >&2; continue; }
  grep -h GENESISRECOMP_BENCHMARK "$D.log" | cut -c1-160 || true
  rm -rf "$D" "$D.log"
done
llvm-profdata-18 merge -o "$OUT" "$RAW"/*.profraw
echo "profile: $OUT ($(du -h "$OUT" | cut -f1))"
