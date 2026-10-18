# Mega Man X (USA Rev 1) — consumed by scripts/build.sh
GAME_TITLE="Mega Man X"
GAME_REPO_URL="https://github.com/mstan/MegaManXSNESRecomp.git"
GAME_COMMIT="42040fdb5a0418ef7f34410c695c119d4aa37eb6"
ROM_STAGE_NAME="mmx.sfc"
ROM_SHA1="C65216760BA99178100A10D98457CF11496C2097"   # unheadered USA Rev 1
regen_game() { bash tools/regen.sh usa --no-tests; }
