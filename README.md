# snesrecomp-ps4

A PS4 host for **snesrecomp** static recompilations. It packages a recompiled
title as a GoldHEN-installable fake PKG (fpkg). The first title is
**Mega Man X** (mstan/MegaManXSNESRecomp, USA Rev 1).

The game repository is consumed almost unmodified. Everything console-specific
lives here: about 30 lines of `#if SRPS4`-guarded framework patches, one
optional game patch, a process entry point, and the packaging. A new title
needs a profile under `games/`, not a new port.

## How it fits together

```
your ROM ──► regen.sh (game repo) ──► src/gen/*.c  (65816 → C, ROM-derived)
                                          │
snesrecomp runner (desktop host, SDL2 backend) + game sources + srps4 layer
                                          │  clang --target=x86_64-pc-freebsd12-elf
                                          ▼  musl + libc++ 12 (static), libkernel/Piglet stubs
                                     ELF ──create-fself──► eboot.bin
eboot.bin + sce_sys/param.sfo + sce_module + payload ──create-gp4 + PkgTool──► .pkg
```

### Runtime layout on the console

| Location | Purpose |
|---|---|
| `/app0/` (read-only) | `eboot.bin`, `srps4/defaults/` (seed config, mod state, the ROM if bundled), `srps4/refresh/` (mod catalog, shader presets) |
| `/data/<Title>/` | Writable "beside the executable" for the desktop host: `config.ini`, `keybinds.ini`, saves, save states, password SRAM, mod state, `logs/last_run.txt` |

On first boot, and on any package version change, `srps4_main.c` seeds
`/data/<Title>` from `/app0/srps4/defaults`. Files the player has edited are
never overwritten. `refresh/` is re-synced on version changes because it is
code-adjacent. Logs also stream to GoldHEN's klog.

### What the patches change (`patches/snesrecomp/`)

1. **`host_paths.c`.** On SRPS4 builds the executable's directory is the
   writable data dir, so every desktop path (config, saves, mods, ROM)
   resolves there.
2. **`fiber_compat.c`.** It uses `src/srps4_ucontext.{S,c}`, a minimal x86-64
   `getcontext/makecontext/swapcontext`, because PS4 musl has none. Mega Man
   X's task scheduler runs every game object on a fiber. The ucontext backend,
   unlike the thread-per-fiber fallback, keeps fiber snapshots working, and
   rewind, run-ahead and save states depend on those snapshots. The native
   smoke build uses the same implementation.
3. **`host_main.c` / `runner.cmake`.** The desktop-GL presenter is compiled out
   on consoles (the same switch Android uses). Presentation goes through
   SDL_Renderer, which runs on GLES2 via Piglet using SDL's precompiled shader
   binaries, since retail firmware has no shader compiler. If that
   accelerated renderer fails to initialize, the host now falls back to
   SDL's software renderer instead of exiting. The fallback is slower but
   playable, and the log records it as `fell back to the software
   renderer`.
4. **`render_workers.c`.** On the console it reports 6 CPUs. libkernel's
   `sysconf()` uses FreeBSD's `_SC_*` numbering, so musl's query always fails
   there.

The port layer adds two more pieces in `src/`:

- **`srps4_paths.c`.** The port keeps its own working directory, and relative
  paths are resolved against it through linker `--wrap`s. The host does all
  its I/O relative to the cwd, so this removes any dependence on the kernel
  honouring `chdir()`. Under shadPS4, for example, it does not.
- **Optional `/data/<Title>/srps4_env.txt`.** Its `KEY=VALUE` lines are
  applied with `setenv()` at startup. It is the only way to reach the host's
  tuning and diagnostic knobs on a console.

### SDK fix: libkernel pthread ABI

libkernel's pthreads follow FreeBSD libthr. The attribute types are pointers,
and `pthread_once_t` is 16 bytes. musl (and therefore both the OpenOrbis and
PacBrew toolchains) declares 4-byte types, so libkernel writes past the
caller's object. In this port that clobbered a callee-saved register inside
`SDL_CreateMutex` and crashed at boot. `scripts/bootstrap_sdk.sh` patches the
four types and `PTHREAD_ONCE_INIT` before building musl, libc++ and SDL.

### Signing and param.sfo: match PacBrew's apps

`create-fself`'s defaults are paid `0x3800000000000011` with no auth info.
They produce a process that cannot map system flexible memory. On a real
console that showed up twice: PacBrew's mini-app malloc crashed before
`main` (CE-34878-0), and Piglet's `eglGetDisplay()` returned
`EGL_NO_DISPLAY` ("Could not get EGL display"). The eboot is now signed the
way PacBrew's `ps4.cmake` `add_self()` signs its apps: paid
`0x3800000000000035` plus PacBrew's `AUTH_INFO` blob (see
`cmake/srps4_helpers.cmake`). Piglet keeps PacBrew's own configuration from
the same pinned SDL commit. `patches/sdl/` only routes SDL's PS4 log
callback through stdio, so its messages reach `last_run.txt` as well as klog.

`param.sfo` likewise follows PacBrew's `add_pkg()`: `CATEGORY` is `gde`
(non-game application, the class that renders through the VSH Piglet stack)
rather than `gd`, with `FORMAT = obs` and `SYSTEM_VER = 1020`. Under `gd`,
signing alone did not fix `EGL_NO_DISPLAY` on a real console.

### SDK fix: libsamplerate

PacBrew's SDL forces libsamplerate on for PS4. Its header probe can find the
build host's `/usr/include/samplerate.h`, which adds `-lsamplerate` to the
link with no PS4 build of the library to satisfy it. The bootstrap therefore
disables it. Nothing is lost, because the host resamples the SPC's 32040 Hz
output itself.

### Game patch (`games/megamanx/patches/`), widescreen renderer performance

1. **OAM-match memoization.** For each row, the renderer scanned all OAM slots
   for every sprite piece: pieces × 112 × 224 iterations per frame. The result
   depends only on the row's OAM snapshot, which consecutive rows share, so it
   is now memoized per snapshot.
2. **Parallel composition.** Each row's sprite pass is order-dependent and
   stays serial. Per-pixel composition (BG layers, windows, color math) then
   runs on snesrecomp's render worker pool: the caller plus 3 workers on PS4.
   The background caches it reads are filled eagerly beforehand. The boss-door
   memo publishes only final values. `SNESRECOMP_RENDER_WORKERS=1` restores the
   serial path.

Verification: presented-frame CRC32s are identical for the unpatched
renderer, the serial path and 2 workers. That covers a 2,789-frame intro
script, plus a 9,887-frame random-input Highway run comparing serial against
parallel.

## Building

1. **SDK:** `scripts/bootstrap_sdk.sh ~/ps4sdk`. This builds OpenOrbis tools,
   PacBrew musl, libc++ 12, the trimmed system stubs and SDL2 2.0.18 from git.
   An existing PacBrew install also works.
2. **Package:**
   ```
   SRPS4_SDK=~/ps4sdk scripts/build.sh --game megamanx \
       --rom "~/Downloads/Mega Man X (USA) (Rev 1).sfc"
   ```
   Output: `out/IV0000-MMXR00001_00-MEGAMANXRECOMP00.pkg`. Pass
   `--no-bundle-rom` to leave the ROM out; then copy it to
   `/data/MegaManX/mmx.sfc` over FTP before first launch.

### Native smoke test (same code path, headless)

```
cmake -S . -B build-native -G Ninja -DSRPS4_GAME=megamanx -DSRPS4_GAME_ROOT=<repo> -DSRPS4_ROM=<rom>
ninja -C build-native
SRPS4_PKG_DIR=build-native/pkg_MegaManX SRPS4_DATA_ROOT=/tmp/d SDL_AUDIODRIVER=dummy \
  SNESRECOMP_PRESENT_LOG=/tmp/p.csv xvfb-run build-native/MegaManX --script tests/intro.script
```

`SNESRECOMP_SCREENSHOT_DIR` dumps every presented frame. `--benchmark N` reports
uncapped FPS.

## Controls (DualShock 4)

| DS4 | SNES / action |
|---|---|
| D-pad / left stick | D-pad |
| Cross / Square / Circle / Triangle | B (jump) / Y (shoot) / A (dash) / X |
| L1 / R1 | L / R (weapon cycle) |
| OPTIONS | Start |
| Touchpad click | Select |
| R3 | Save-state browser |
| L3 | Rewind |
| hold R2 | Fast-forward |

To remap, edit `[GamepadMap]` in `/data/MegaManX/config.ini`. To change mods,
edit `/data/MegaManX/mods/preloaded/state.toml`: widescreen is `enabled = true`
with `aspect = "16:9"`.

## Adding another title

Copy `games/megamanx/`. Point `game.cmake` at the title's source list, which
mirrors its upstream CMake minus the launcher and netplay. Then set the ROM
name, SHA-1 and regen command in `profile.sh`. Pick a unique 9-character
`TITLE_ID` and a 16-character `LABEL`. The framework patch is title-agnostic.

## Limits and honesty

- Not yet verified on retail hardware by the author. The pkg validates
  (PkgTool hash and signature checks), the ELF binds only to libkernel,
  Piglet, Sce* and `sceLibcMspace*`, and the identical code path plays
  natively. Real-console behaviour (Piglet, pad, audio, timing) still needs
  your test. See TESTING.md.
- Validated in the shadPS4 emulator. The eboot boots through the real PS4
  loader and libkernel/Piglet/pad bindings, provisions `/data`, loads the
  bundled ROM and plays the 2,788-frame intro script to a clean exit. Its
  presented frames are CRC-identical to the native build, 1,301 of 1,301
  compared. One part of that run is not the console code path: the emulator
  stubs `sceLibcMspace*`, so the emulator eboot links musl's own malloc,
  where the console eboot uses the firmware allocator.
- Netplay, the ImGui launcher and the in-game launcher are not built.
  Settings live in `config.ini` and `state.toml`.
- A pkg with a bundled ROM contains copyrighted data. It is for your own use
  only; do not share it.
