# Testing on a PS4 (GoldHEN)

## Install

1. Run GoldHEN as usual (your firmware is 9.03–11.00).
2. Copy `IV0000-MMXR00001_00-MEGAMANXRECOMP00.pkg` to a FAT32 or exFAT USB
   stick, at its root. Alternatively, send it with GoldHEN's Remote Package
   Installer.
3. Open *Settings → Debug Settings → Game → Package Installer*, or GoldHEN's
   installer, and install it. The tile reads **Mega Man X Recompiled**
   (title ID `MMXR00001`).

## First boot checklist

| Expect | If not |
|---|---|
| A black screen for about 1 s, then the Capcom logo with sound | Read the log (below). The app closes by itself if SDL/Piglet init fails. |
| The DualShock 4 works right away | Press PS and pick your user. The pad binds to the logged-in user. |
| The title screen and gameplay fill a 16:9 TV, with the HUD anchored at the edges | Widescreen is off; check `mods/preloaded/state.toml` |
| 60 fps with smooth scrolling | See *Performance* |

## Logs

Lifecycle lines (`[srps4] ...`: start, data-dir provisioning, exit code)
stream to GoldHEN's **klog**. Enable it in the GoldHEN settings, then run
`nc <ps4-ip> 3232` on your PC.

The full host log (`[host +N.NNNs] ...` breadcrumbs, SDL errors) is
line-buffered to a file. Fetch it over FTP (GoldHEN's FTP server, port 2121):

```
/data/MegaManX/logs/last_run.txt      stderr/stdout of the last session
/data/MegaManX/last_run_report.json   the host's exit/crash report
/data/MegaManX/crash_report_*.json    present only after a crash
```

Please send these along with any problem report.

## Files you may edit (FTP, `/data/MegaManX/`)

- `config.ini`: graphics, audio and pad mapping (`[GamepadMap]`).
- `mods/preloaded/state.toml`: mod toggles. Widescreen is the feature
  `id = "widescreen"`. Set `enabled = false` for the original 4:3 view.
  `aspect` may be `"16:9"` or `"adaptive"`.
- Deleting a file restores its default on the next launch. A package update
  (new `version.txt`) refreshes only the mod catalog and shader presets,
  never your settings.

## Performance

The PS4's Jaguar cores are several times slower per clock than a desktop's.

- **Vanilla 4:3** costs well under the 16.7 ms frame budget.
- **Widescreen** reconstructs and composes a wider view every frame. This
  build splits that composition across four CPU cores, which is new in this
  port; desktop builds run it on one core.

If you see slowdown in a busy scene, try these in order:

1. Edit `config.ini`, under `[Sound]`, and set `AudioSamples = 2048`. This
   gives more audio slack on frame spikes.
2. Turn widescreen off in `state.toml`. That is the original renderer path.
3. Report which stage and moment slowed down. A save state via R3 is ideal.

### Tuning and diagnostics without a rebuild

Create `/data/MegaManX/srps4_env.txt` with `KEY=VALUE` lines. They are
applied before the game starts, and each one is echoed to klog. Useful keys:

```
SNESRECOMP_RENDER_WORKERS=1       # widescreen composition on one core (original path)
SNESRECOMP_RENDER_WORKERS=4       # caller + 3 workers (the console default)
SNESRECOMP_OSD_FPS=1              # on-screen FPS counter
SNESRECOMP_HOST_PROFILE=1         # per-frame timing breakdown into the log
```

Delete the file to return to the defaults.

## Known gaps

- No launcher UI, so the mods and options menus are files (above).
- Netplay is not built.
- MSU-1 audio, Zero and X2/X3 weapon mods need extra files or ROMs. They
  are left off.
