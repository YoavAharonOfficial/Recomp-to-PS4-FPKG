#!/usr/bin/env bash
# build_genesis.sh — a segagenesisrecomp title (mstan's *Recomp repos) + your ROM
# to an installable fpkg.
#
#   scripts/build_genesis.sh --game sonic3k --rom /path/sonic3k.bin \
#                            [--game-repo DIR] [--sdk DIR] [--out DIR] [--no-bundle-rom]
#
# Steps: clone/pin the title -> apply patches/segagenesisrecomp + the profile's
# patches -> native release build of the generator tools (GenesisRecomp,
# M68kStepRecomp; the cross build cannot run its own) -> cross-configure the
# title's OWN CMakeLists with cmake/srps4_inject_genesis.cmake -> fake PKG.
# Generated C is produced from YOUR ROM in the build trees; nothing is fetched
# or shipped except what the title's build itself pulls (Clone Driver tools).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
GAME="" ROM="" REPO="" OUT="$HERE/out" BUNDLE=1
SRPS4_SDK="${SRPS4_SDK:-$HOME/ps4sdk}"
while [ $# -gt 0 ]; do
  case "$1" in
    --game) GAME="$2"; shift 2;;
    --rom) ROM="$2"; shift 2;;
    --game-repo) REPO="$2"; shift 2;;
    --sdk) SRPS4_SDK="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --no-bundle-rom) BUNDLE=0; shift;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
[ -n "$GAME" ] && [ -n "$ROM" ] || { sed -n 2,12p "$0"; exit 2; }
PROFILE="$HERE/games/$GAME"
. "$PROFILE/profile.sh"
export SRPS4_SDK

# 1. ROM check
ROM_ABS="$(readlink -f "$ROM")"
sha=$(sha1sum "$ROM_ABS" | awk '{print toupper($1)}')
[ "$sha" = "$ROM_SHA1" ] || { echo "ROM SHA-1 $sha does not match the expected $ROM_SHA1" >&2; exit 1; }

# 2. Title at the pinned commit, with submodules
REPO="${REPO:-$HERE/work/$GAME}"
if [ ! -d "$REPO/.git" ]; then
  git clone "$GAME_REPO_URL" "$REPO"
  git -C "$REPO" checkout -q "$GAME_COMMIT"
  git -C "$REPO" submodule update --init --recursive
fi

# 3. Patches (idempotent)
apply() { # repo patch
  if git -C "$1" apply --reverse --check "$2" 2>/dev/null; then return; fi
  git -C "$1" apply "$2"
}
for p in "$HERE"/patches/segagenesisrecomp/*.patch; do apply "$REPO/segagenesisrecomp" "$p"; done
for p in "$PROFILE"/patches/*.patch; do [ -e "$p" ] && apply "$REPO" "$p"; done
cp "$ROM_ABS" "$REPO/$ROM_STAGE_NAME"

# 4. Native release build of the generator tools
H="$REPO/build-host"
cmake -S "$REPO" -B "$H" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
    -DGEN_ENABLE_TRACE=OFF -DGEN_DEV_TRACE=OFF -DSONIC_REVERSE_DEBUG=OFF -DGENESIS_BUILD_COSIM=OFF
ninja -C "$H" GenesisRecomp M68kStepRecomp
clone=$(sed -n 's/^S3_CLONE_PROGRAM_DIR:PATH=//p' "$H/CMakeCache.txt" 2>/dev/null || true)

# 5. Cross-compile + package
. "$HERE/scripts/env.sh"
B="$REPO/build-ps4"
args=(-DCMAKE_PROJECT_INCLUDE="$HERE/cmake/srps4_inject_genesis.cmake"
      -DSRPS4_PROFILE_DIR="$PROFILE" -DSRPS4_HOST_TOOLS_DIR="$H")
[ -n "$clone" ] && args+=(-DS3_CLONE_PROGRAM_DIR="$clone")
[ "$BUNDLE" = 1 ] && args+=(-DSRPS4_ROM="$REPO/$ROM_STAGE_NAME") || args+=(-DSRPS4_ROM=)
openorbis-cmake -S "$REPO" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release "${args[@]}"
ninja -C "$B" "${GAME_TARGET}_pkg"
mkdir -p "$OUT"
cp "$B"/*.pkg "$OUT/"
echo "Package(s) in $OUT:"; ls -la "$OUT"/*.pkg
