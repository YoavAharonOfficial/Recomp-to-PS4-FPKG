# Genesis titles (segagenesisrecomp) on the PS4

mstan's Genesis recompilations (`SonicTheHedgehogRecomp`,
`Sonic3AndKnucklesRecomp`, …) share one engine, `segagenesisrecomp`, as a
pinned submodule. This port builds them with the same host layer, SDK and
packaging as the snesrecomp titles. Only the way the title is configured
differs.

```
scripts/build_genesis.sh --game sonic3k --rom /path/sonic3k.bin
```

## How the build works

```
title repo @ pin ──► patches/segagenesisrecomp/*.patch   (engine: console host support)
                └──► games/<id>/patches/*.patch          (title: launcher-stub hook)
     │
     ├─ native release build ─► GenesisRecomp, M68kStepRecomp  (generator tools)
     │                          (+ the title's Clone Driver software, reused)
     ▼
openorbis-cmake -S <title repo> -DCMAKE_PROJECT_INCLUDE=cmake/srps4_inject_genesis.cmake
     │   injected right after the title's project():
     │     release options forced (no trace server, reverse debugging,
     │     co-simulation, netplay, tests); whole-program IPO off on the console
     │     generator tools imported from the native build (the cross build
     │     cannot run its own)
     │     recomp-ui swapped for the stub (no run-time shader compiler on retail)
     │   deferred until the title has defined its targets:
     │     srps4_add_host(<target> WRAP_MAIN)  — main() entered through --wrap=main
     │     ROM passed positionally; /data/<Title> named as the user directory
     │     srps4_package(): eboot, param.sfo, defaults/ (settings.ini), the ROM
     ▼
IV0000-<TITLE_ID>_00-<LABEL>.pkg
```

Genesis titles address their own files through `CMAKE_SOURCE_DIR`, so unlike
snesrecomp titles they cannot be `add_subdirectory()`'d. Configuring the
title as the top-level project, with this port injected, keeps every title
file where the title expects it.

## Engine patch (`patches/segagenesisrecomp/0001-console-host-support.patch`)

All of it is under `#if defined(SRPS4)`; the desktop build is unchanged.

| Change | Why |
|---|---|
| User directory falls back to `SRPS4_DATA_DIR` | `/app0` is read-only; settings, SRAM, rewind and logs go to `/data/<Title>` |
| Fixed 1920×1080 window, no resize/high-DPI/fullscreen flags | PacBrew's SDL creates the Piglet EGL surface once, at the window's size; the frame scales into it through `SDL_RenderSetLogicalSize` |
| Software-renderer fallback | No launcher to change the setting from; degrade rather than exit if GLES2 fails |
| Desktop-GL "HD GPU" upscaler compiled out | Piglet has no run-time shader compiler (same as the Android build) |
| Pacer target 60.00 Hz instead of 59.94 | Output is a fixed 60 Hz with vsync. At 59.94 one vblank in every ~1,000 gets no new picture, a hitch every ~17 s. Audio DRC absorbs the 0.1% |
| `[srps4-perf]` line every 600 frames | Simulation (incl. widescreen rendering), audio, present and rewind costs, plus frame intervals over 18 ms, written to the log |

## Port-layer additions (all titles)

| File | What |
|---|---|
| `src/srps4_sdl_compat.{c,h}` | `SDL_RenderGetWindow` (2.0.22) and `SDL_ResetHint` (2.24) for PacBrew's SDL 2.0.18. The header is force-included into the title's hand-written C only (never the generated C, so a flag change does not recompile it). The renderer→window map is recorded by wrapping `SDL_CreateRenderer` |

## Sonic 3 & Knuckles (`games/sonic3k`)

- Title `Sonic3AndKnucklesRecomp` @ `64139c6`, engine @ `79fb2b8`. ROM:
  Sonic & Knuckles + Sonic 3 lock-on, 4 MiB, SHA-1
  `CFBF98C36C776677290A872547AC47C53D2761D6`. The pkg carries only the
  lock-on mode (`Sonic3KRecomp`).
- Widescreen: the title's own 16:9 renderer (`[mods.widescreen]`), 398×224,
  reconstructed from the level layout rather than stretched.
- Pad (PacBrew's SDL mapping): Cross/Circle/Square = B/A/C (all jump),
  OPTIONS = Start, touchpad click = Mode, OPTIONS+R1 = save-state menu,
  OPTIONS+R3 = rewind.
- Data: `/data/Sonic3K/` holds `settings.ini`, the SRAM save, rewind and
  `logs/`.

## Validation

- **Determinism, console code vs desktop.** The console eboot (the exact
  `eboot.bin` in the pkg) ran under shadPS4 with the title's own
  `sonic3k_benchmark_gameplay.input` for 1,800 frames: title screen, menus,
  the Angel Island intro and gameplay. Its machine-state fingerprint
  (`RUN_DONE state=b475d0de7638d649`) and its last widescreen frame (398×224
  PNG) are byte-identical to the native desktop build's. Clean exit, code 0.
- **What that run does not cover:** Piglet/GLES2 presentation and audio
  output (the emulator run uses SDL's dummy video and has no audio device),
  and Jaguar timing.
- The emulator found one real bug before release: an `mmap`/`sysconf`
  translation layer added for this port was wrong (PacBrew's musl headers
  already carry the FreeBSD values), so every musl `malloc` failed and the
  first `fopen` looped forever. It was removed; nothing else was needed.

## Cost on the Jaguar

Measured natively (clang 18, `-march=btver2`, the same `-O3`) and scaled by
the Jaguar factor calibrated on Mega Man X (about 5.5× a desktop core).

| | native, no PGO | native, PGO | Jaguar estimate (PGO) |
|---|---|---|---|
| Angel Island gameplay, average per frame | 3.29 ms | 2.38 ms | ~13 ms |
| Dense-foliage stretches (~25 frames, a few per minute) | | ~1.5× average | ~19 ms |

- **Where the time goes** (callgrind, 6,000 gameplay frames): the title's
  widescreen renderer (`sonic3_video.c`, per scanline, inline with
  emulation) is 79% of the main thread; FM synthesis (ymfm) about 8%; the
  68000 code itself is small.
- **PGO** (`scripts/pgo_train_genesis.sh`, the title's regression inputs)
  is worth 28% here, with an identical state hash.
- **Reading:** 60 fps with ~3 ms to spare in ordinary play; brief dips are
  possible in the densest Angel Island foliage. The estimate carries the
  factor's uncertainty. The `[srps4-perf]` line in
  `/data/Sonic3K/logs/last_run.txt` reports the real numbers every 600
  frames.
- **If it dips:** the fix is the one Mega Man X needed: render the
  widescreen rows off the emulation thread (the renderer already reads
  per-frame snapshots plus per-line palette/scroll, so rows can be queued
  to workers), and move FM synthesis to the existing engine worker.
