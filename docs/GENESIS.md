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
                └──► games/<id>/patches/*.patch          (title: launcher-stub hook, renderer)
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
| Vsync is the frame clock | Waiting for the software pacer and then for the next vblank ran two 60 Hz clocks against each other: stutter, plus a frame of input lag, whenever their phases drifted. The pacer now stands in only if presents stop being vsync-throttled |
| SDL audio thread moved to core 1 | The main thread is pinned to core 0 before SDL starts and FreeBSD threads inherit their creator's cpuset, so the audio callback shared a core with ~13 ms of emulation per frame (crackle) |
| Audio makeup gain + soft limiter | The native mix peaks near -7 dBFS at about -26 dBFS RMS, 8-10 dB under mastered soundtrack releases. +6 dB by default (`SRPS4_AUDIO_GAIN_DB`), bending smoothly into full scale above -3 dBFS |
| Smaller audio queue | The 200 ms boot cushion drained at the servo's 0.5% limit, so audio trailed the picture by ~0.2 s for half a minute. Target and preroll 40 ms, 512-sample device buffer (`SRPS4_AUDIO_TARGET_MS`, `SRPS4_AUDIO_SAMPLES`) |
| `[srps4-perf]` line every 600 frames | Simulation (incl. widescreen rendering), audio, present and rewind costs, plus frame intervals over 18 ms, written to the log |
| Optional `genesis_video_flush_deferred()` after each simulation step | A title renderer that defers rows to worker threads (Sonic 3 & Knuckles, below) finishes them before anything reads the frame. Weak symbol; absent in other titles |

## Port-layer additions (all titles)

| File | What |
|---|---|
| `src/srps4_pagesize.c` | `sysconf` resolves to libkernel, which uses FreeBSD's `_SC_*` numbers; titles pass musl's. `_SC_PAGESIZE` (musl 30) came back 4096 on retail, but pages are 16 KiB, so the game-fiber guard page rounded down over the fiber header and the first boot crashed. Names are translated and the page size is floored at 16 KiB. (shadPS4 answers 16384 to any name, which hid it.) |
| `src/srps4_realloc.c` | PacBrew musl's `realloc` shrinks mmapped (>~224 KiB) blocks with `mremap`, which PS4 lacks; its fallback copies the *old* size into the smaller new block and overruns the next chunk. The rewind ring shrinks its snapshot buffer entering a special stage: the next `malloc` crashed. Shrinks now keep the block. Found with a hardware watchpoint under shadPS4 |
| `src/srps4_threads.c` | The main thread is pinned to core 0 before the title starts and FreeBSD threads inherit their creator's cpuset, so SDL's audio thread, the engine worker and file writers all shared the emulation core. New threads now start on cores 2-5 (`SRPS4_THREAD_CORES`), set by the thread itself before the title's entry so self-pinning threads still win |
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
- Sound: enhanced FM on by default (`env_defaults.txt`: a second, ladder-free
  YM3438 model with the hardware output low-pass relaxed, verified against the
  canonical chip and substituted only after a proven window; it runs on the
  engine worker), `bypass_filter = 1`, and Clone Driver + Mega PCM (`sonic3k-sound.ini`,
  `enabled=0` for the original driver); no measurable cost.
- Data: `/data/Sonic3K/` holds `settings.ini`, the SRAM save, rewind and
  `logs/`.

### Widescreen rows off the emulation thread (`patches/0002-deferred-rows.patch`)

The title's 398-px renderer drew every row inline, on the emulation core, at
its raster time: about 80% of a gameplay frame. During level play the
renderer now records each row (lines 1-223) instead of drawing it, with the
per-line state the raster would have used: CRAM, VSRAM, registers, and the
HUD digit pixels. At the end of active display it draws the recorded rows on
four worker threads (cores 2-5) plus the emulation thread, then composites
the overlay pixels captured for each row. Line 0, menus, special and bonus
stages, competition and the interpolated presentation mode stay inline.

What makes this exact rather than approximate:

- Rows read the line-0 snapshots (VRAM, world RAM) the inline path already
  used. A direct RAM read inside a row job reads the world snapshot; an
  instrumented run checked that no RAM the renderer reads during active
  display differs from that snapshot.
- Lazily decoded art caches (13 of them) are published only after decoding
  completes, under a lock, so a concurrent row never reads a half-decoded
  cache. Code that keeps static scratch (preview and margin-pose overlays)
  runs under one lock. The sprite-priority buffer is per thread.
- A worker claims a job only for the batch it was woken for, so a worker that
  wakes late can never take a later frame's rows.
- Rows are drawn before vertical blank, which replaces sprite patterns and
  presentation banks the rows still read.

`GENESIS_S3_ROW_WORKERS=N` (in `srps4_env.txt`) sets the worker count; 0
draws inline as before. The log reports coverage every 600 frames
(`[s3-video] deferred rows: 223.0 of 224 per frame`).

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
- **Measured on the console (1.00-3):** about 13 ms of simulation in
  ordinary play, but 14-17 ms averages with 18-24 ms peaks in heavy stretches
  (Angel Island on fire: 470 of 600 frames late). The widescreen renderer
  was the cause.
- **Since 1.00-4** those rows are drawn on five threads (above). Natively,
  with only one extra thread on a two-core machine, the same gameplay input
  drops from 2.29 to 1.61 ms per frame (state hash identical). With the
  renderer at ~80% of a level frame split over five cores, the Jaguar
  estimate for those 13-24 ms frames is roughly 5-9 ms.
- **Exactness:** per-frame framebuffer hashes are identical with 0 and 4
  workers over all four regression inputs (attract 12,000 frames, gameplay
  4,000, fuzz 5,859, native services 8,000) plus a special-stage run, and the
  console eboot under shadPS4 gives identical hashes and machine state with
  0 and 4 workers over 2,200 frames. ThreadSanitizer, with the renderer
  instrumented, reports no races in it over the same inputs.
- **PGO** now trains with the shipped `settings.ini`, `env_defaults.txt` and
  the profile's `PGO_ENV` (renderer workers on), i.e. the configuration the
  console runs.
