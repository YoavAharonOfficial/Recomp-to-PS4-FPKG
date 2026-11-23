# Sonic 3 & Knuckles — inputs for scripts/build_genesis.sh.
GAME_REPO_URL=https://github.com/mstan/Sonic3AndKnucklesRecomp.git
GAME_COMMIT=64139c65a7c8e7975e70a03eb38ce8d64f93fc49     # engine submodule 79fb2b8
ROM_SHA1=CFBF98C36C776677290A872547AC47C53D2761D6          # Sonic & Knuckles + Sonic 3 (USA) lock-on, 4 MiB
ROM_STAGE_NAME=game/sonic3k/sonic3k.bin                    # where the title's CMake reads it
GAME_TARGET=Sonic3KRecomp
# PGO training: the title's own deterministic regression inputs (attract demos
# across several zones, Angel Island gameplay with jumps, spindash/reverse fuzz).
PGO_SCRIPTS="tests/regression/sonic3k_attract_12000.input tests/regression/sonic3k_benchmark_gameplay.input tests/regression/sonic3k_gameplay_fuzz.input"
PGO_FRAMES=12000
