# Converting any snesrecomp title to a PS4 fpkg — metaplan and tool

`scripts/srps4_convert.py --repo <title repo> --rom <your ROM>` takes a
snesrecomp title from source to an installable package. This document is the
plan behind it: what the Mega Man X port taught, which parts are generic,
what still needs a per-title patch to reach 60 fps in widescreen, and how
each step is checked.

## 1. Goal and constraints

- **Input:** a snesrecomp title repository (mstan's `*Recomp` repos) and the
  owner's ROM. **Output:** a GoldHEN fpkg (FW 9.03–11.00) that boots straight
  into the game, in widescreen, at 60 fps.
- **The ROM is never redistributed.** It is bundled only for personal use,
  and `--no-bundle-rom` leaves it out.
- **Upstream repositories are never edited.** Every change is a patch file
  in this repo, and the patches apply idempotently.
- **Unattended.** The tool asks no questions. Every stage logs, gates on a
  check, and can be resumed with `--from`.

## 2. What the Mega Man X port established

| Lesson (MMX, 1.00-1 → 1.00-11) | Generic rule in the converter |
|---|---|
| fself signing (`paid 0x3800000000000035` + auth info) and `CATEGORY gde` were required for system flexible memory and Piglet EGL | Lives in `srps4_package()`; every title inherits it |
| musl/libkernel ABI mismatches: pthread types, `sysconf`, clock ids; retail firmware ignores `freopen`/`dup2` | SDK bootstrap and the port layer (`src/srps4_*.c`); title-independent |
| A non-zero `_Thread_local` initializer crashes on the PS4 loader | Rule for every title patch: zero-initialized TLS only |
| The framework pacer gated a late frame a full period past its end, so on the Jaguar it cascaded into missed vblanks | Framework patch (`host_clock.c`); every title inherits it |
| Capture copied 64 KiB of VRAM per scanline (14.7 MB/frame) | Per-title patch, the same recipe for every custom renderer (§5.1) |
| Compose (widescreen) did not fit beside emulation in 16.7 ms | Per-title patch: parallel pixel pass plus pipelined compose (§5.2, §5.3) |
| The console build silently ran at `-O2`; PGO from native clang-18 runs gave about 20% | Generic: `-O3` plus a PGO profile trained by the converter |

## 3. Architecture: generic by construction, curated where needed

```
title repo ──(fetch, identify: rom_identity.txt)──► ROM verified (sha1/sha256/crc32)
      │
      ├─ patches/snesrecomp/*.patch    framework: console host support (all titles)
      ├─ games/<id>/patches/*.patch    title: renderer performance (when needed)
      ├─ tools/regen.{py,sh}           recompiled C from the owner's ROM
      ▼
games/<id>/  profile: generated when missing, kept when curated
      │      profile.cmake (identity), env_defaults.txt, defaults/ (widescreen
      │      on), post.cmake (per-title build tweaks), icon0.png, pgo.profdata
      ▼
cmake/srps4_generic_game.cmake  ── add_subdirectory(<title repo>) and adapt:
      │   framework options forced (SDL2, no net/Lua/trace/tests),
      │   recomp-ui swapped for a stub (the ImGui launcher needs a shader compiler
      │   the retail console does not have), the title's one executable target found,
      │   srps4_add_host(... WRAP_MAIN): the title's main() is entered through
      │   --wrap=main, so no title source needs to be known or edited
      ▼
native build (clang-18 -O2 -march=btver2) ─► verify ─► PGO train ─► PS4 build (-O3 + PGO)
                                                                        │
                                                    shadPS4 smoke test ◄┘ ─► out/<id>-report.md
```

The **curated** path (`games/megamanx/game.cmake`, a hand-restated source
list) predates the generic one. The converter still builds it. A **generic**
profile needs no title knowledge beyond what the repository declares.

### Widescreen discovery (generic)

1. If a preloaded mod package has a feature whose id or name contains
   `widescreen`, the converter writes `state.toml` enabling it, with every
   choice option that offers `16:9` set to it. This is the MMX family.
2. If the title's own source honours `getenv("SNESRECOMP_WIDESCREEN")` or a
   `*_ASPECT` variable, the converter sets them in the package's
   `env_defaults.txt` (1 and `16:9`). This is the Super Metroid family.
3. A curated profile may also ship the title's own settings file under
   `defaults/`, for example `sm-video.ini`.

Defaults seed `/data/<Title>/` once. Player edits and `srps4_env.txt` win.

## 4. Stages and their gates

| Stage | What it does | Gate |
|---|---|---|
| fetch | Clone with submodules, or use a local checkout | `snesrecomp/` present |
| identify | `rom_identity.txt` gives the title, the id and the expected digests; strips a copier header | ROM digest equals the declared one |
| patch | Framework patch, then title patches; idempotent, with a 3-way fallback for framework drift | Every patch applies |
| regen | The title's own generator on the owner's ROM, stamped by commit and ROM | `src/gen/*.c` produced |
| profile | Writes missing profile files: title id, label, data dir, widescreen defaults, original abstract icon | |
| native | The same CMake graph built for the host with the console's compiler | Builds |
| verify | Headless runs (the profile's scripts, or attract mode), uncapped and single-threaded | Clean exit; non-blank, varied presents; pipelined presents equal synchronous ones one frame later |
| estimate | Native stage means × Jaguar factor 5.5 (calibrated on MMX) against a 16.7 ms frame | Reported as *60 fps expected* or *at risk* |
| pgo | Instrumented native build replays the verification inputs, writing `games/<id>/pgo.profdata` | Profile merged |
| ps4 | `openorbis-cmake` with `-O3` + PGO, then fself + `param.sfo` + PkgTool | `.pkg` produced, sha256 recorded |
| emulator | The console eboot, relinked against musl malloc because shadPS4 stubs `sceLibcMspace`, under shadPS4 | Clean exit after N frames, non-blank presents |
| report | `out/<id>-report.md` with every stage's result and estimate | |

## 5. The per-title performance playbook

The estimate decides whether a title needs a renderer patch. The three
optimizations below are the same for every snesrecomp custom renderer,
because all of them follow one capture/compose shape: per-line raster
snapshots during the frame, then a read-only widescreen compose. Each must
be bit-exact, checked by present-CRC equality against the unmodified renderer.

1. **Per-line VRAM sharing.** A line copies VRAM only when the PPU's
   `vramWriteCount` moved since the last copied line; otherwise it points
   at that copy through a side table. Capture files are materialized before
   a save. `<PREFIX>_VRAM_VERIFY=1` re-checks every shared line.
2. **Parallel pixel pass.** The order-dependent sprite pass stays serial.
   Each row's per-pixel composition is recorded as a job and run on the
   framework's render worker pool, pinned to cores 1–4.
3. **Pipelined compose.** A compose thread on core 5 draws frame N while the
   main thread on core 0 emulates and captures N+1. A present shows exactly
   frame N-1, so there is no judder, at a cost of one frame of latency.
   - The frame ring grows to three slots when the renderer reads the
     previous frame.
   - Submit waits for idle before the capture slots rotate.
   - The thread-local or world state is zero-initialized (see §2).

## 6. Risks and limits

- **The Jaguar factor is an average.** It comes from one title's profile.
  Memory-bound and branchy code scale differently, so the estimate is a
  screen, not a guarantee. The console profile (`SNESRECOMP_HOST_PROFILE`,
  `[<prefix> pipe]` lines) is the ground truth.
- **Framework drift.** Titles pin different snesrecomp revisions. The
  framework patch is small and guarded by `#if SRPS4`, and the 3-way apply
  absorbs context drift. A real conflict stops the stage.
- **Native and emulator presents differ.** Under shadPS4 they are not
  CRC-identical to native even with the pipeline off (an environmental
  difference seen with MMX), so the emulator gate is boot plus clean exit
  plus non-blank presents, not CRC equality.
- **Chip titles.** SuperFX and SA-1 games add co-processor emulation to the
  main thread and may not reach 60 fps on the Jaguar.
- **Launcher-only settings** become files (`config.ini`, `state.toml`,
  title inis), because there is no launcher on the console.

## 7. Results

Each converted title gets `out/<id>-report.md`.

**Super Metroid** (`mstan/SuperMetroidRecomp` @ `494df85`, JU ROM). This is
the first title built through the generic path, with no hand-written build
file.

Native build and correctness:

- The native build ran on the first attempt.
- **Renderer patch** (the three §5 optimizations):
  - Across 12,000 attract-mode frames (title, intro and gameplay demos), the
    output is CRC-identical to the unmodified renderer.
  - With the pipeline on, every present equals the synchronous one, one
    frame later.
  - `SM_VRAM_VERIFY` found no shared line that differed.
- **ThreadSanitizer**, 4,200 frames with the pipeline on: no races in the
  port's or the title's code. The only two reports are inside Mesa's
  llvmpipe, which the console does not use.

Speed (native, gameplay window):

| Stage | Before | After |
|---|---|---|
| Capture | 2.27 ms | 0.78 ms |
| Compose | 3.8 ms | moved off the main thread |

Console:

- **Estimate:** main thread about 11.2 ms (guest 5.4, capture 4.3, present)
  and compose thread about 5.9 ms, against a 16.7 ms frame. 60 fps is
  expected, but this is not yet measured on hardware.
- **Under shadPS4:** the console eboot (`-O3` + PGO, pipelined) booted with
  widescreen on, ran 2,400 frames and exited cleanly.
- **Console against native:** its presents equal the native unmodified
  renderer's one frame later, all 2,400 of them.
