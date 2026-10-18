#!/usr/bin/env bash
# build.sh — one command from a recomp repo + your ROM to an installable fpkg.
#
#   scripts/build.sh --game megamanx --rom "/path/Mega Man X (USA) (Rev 1).sfc" \
#                    [--game-repo DIR] [--sdk DIR] [--out DIR] [--no-bundle-rom]
#
# Steps: clone/pin the game repo -> apply the framework + game patches ->
# regenerate the recompiled C from YOUR ROM -> cross-compile -> fake PKG.
# The ROM never leaves your machine; with --no-bundle-rom the package holds
# only code and the game asks for /data/<Title>/<rom> at first boot.
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
[ -n "$GAME" ] && [ -n "$ROM" ] || { sed -n 2,10p "$0"; exit 2; }
PROFILE="$HERE/games/$GAME"
. "$PROFILE/profile.sh"
export SRPS4_SDK

# 1. ROM check (strip a 512-byte copier header if present)
ROM_ABS="$(readlink -f "$ROM")"
size=$(stat -c %s "$ROM_ABS")
if [ $((size % 1024)) -eq 512 ]; then
  tail -c +513 "$ROM_ABS" > "$OUT.rom.tmp"; ROM_ABS="$OUT.rom.tmp"
fi
sha=$(sha1sum "$ROM_ABS" | awk '{print toupper($1)}')
[ "$sha" = "$ROM_SHA1" ] || { echo "ROM SHA-1 $sha does not match the expected $ROM_SHA1" >&2; exit 1; }

# 2. Game repo at the pinned commit, with submodules
REPO="${REPO:-$HERE/work/$GAME}"
if [ ! -d "$REPO/.git" ]; then
  git clone --recurse-submodules "$GAME_REPO_URL" "$REPO"
  git -C "$REPO" checkout -q "$GAME_COMMIT"
  git -C "$REPO" submodule update --init --recursive
fi

# 3. Patches (idempotent: skip when already applied)
apply() { # repo patch
  if git -C "$1" apply --reverse --check "$2" 2>/dev/null; then return; fi
  git -C "$1" apply "$2"
}
for p in "$HERE"/patches/snesrecomp/*.patch; do apply "$REPO/snesrecomp" "$p"; done
for p in "$PROFILE"/patches/*.patch; do [ -e "$p" ] && apply "$REPO" "$p"; done

# 4. Regenerate recompiled C from the ROM (rustup pins may be offline: use stable)
cp "$ROM_ABS" "$REPO/$ROM_STAGE_NAME"
( cd "$REPO" && RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-stable}" regen_game )

# 5. Cross-compile + package
. "$HERE/scripts/env.sh"
B="$HERE/build-ps4-$GAME"
args=(-DSRPS4_GAME="$GAME" -DSRPS4_GAME_ROOT="$REPO" -DSNESRECOMP_FRAME_IMPL=HLE
      -DSDL2_DIR="$OPENORBIS/usr/lib/cmake/SDL2")
[ "$BUNDLE" = 1 ] && args+=(-DSRPS4_ROM="$ROM_ABS") || args+=(-DSRPS4_ROM=)
openorbis-cmake -S "$HERE" -B "$B" -G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release "${args[@]}"
ninja -C "$B"
mkdir -p "$OUT"
cp "$B"/*.pkg "$OUT/"
rm -f "$OUT.rom.tmp"
echo "Package(s) in $OUT:"; ls -la "$OUT"/*.pkg
