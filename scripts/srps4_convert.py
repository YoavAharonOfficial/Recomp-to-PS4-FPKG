#!/usr/bin/env python3
"""srps4_convert.py — turn a snesrecomp title into a GoldHEN-installable fpkg.

    scripts/srps4_convert.py --repo <git URL | local checkout> --rom <your ROM>

One command takes a title's recomp repository and your own ROM through the
whole port: fetch, identify, patch the framework, regenerate the recompiled C
from the ROM, write (or reuse) a console profile, build and verify the same
code natively, train a profile-guided-optimization profile, cross-compile,
package, and smoke-test the console build under shadPS4 when it is installed.
Every stage logs to <work>/<id>/logs/ and a summary lands in
<out>/<id>-report.md. Stages are resumable (--from STAGE).

What is generic and what is per title is described in docs/CONVERTER.md.
The ROM never leaves your machine; with --no-bundle-rom the package holds only
code and the game asks for /data/<Title>/rom.sfc at first boot.
"""
import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import tomllib
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
STAGES = ["fetch", "identify", "patch", "regen", "profile", "native", "verify",
          "pgo", "ps4", "emulator", "report"]
# Per-thread speed of the PS4's 1.6 GHz Jaguar relative to the reference
# desktop core these scripts were calibrated on (Mega Man X: console stage
# times from the profiler divided by native single-thread clang-18 -O2
# times of the same scripts; guest 4.1-4.6 / 0.89, capture 3.5 / 0.63).
JAGUAR_FACTOR = 5.5
FRAME_BUDGET_MS = 1000 / 59.94


# --------------------------------------------------------------------------
class Converter:
    def __init__(self, a):
        self.a = a
        self.work = Path(a.work).resolve()
        self.out = Path(a.out).resolve()
        self.rom_in = Path(a.rom).resolve()
        self.state_path = None
        self.state = {}
        self.report = []
        self.stage = "identify"

    # ---- utilities -------------------------------------------------------
    def log(self, msg):
        line = f"[srps4-convert] {msg}"
        print(line, flush=True)
        self.report.append(msg)
        self.state.setdefault("stage_log", {}).setdefault(self.stage, []).append(msg)

    def run(self, cmd, stage, cwd=None, env=None, check=True, timeout=None):
        logdir = self.work / self.id / "logs" if getattr(self, "id", None) else self.work
        logdir.mkdir(parents=True, exist_ok=True)
        logf = logdir / f"{stage}.log"
        e = dict(os.environ)
        if env:
            e.update(env)
        with open(logf, "a") as f:
            f.write(f"\n$ {cmd if isinstance(cmd, str) else ' '.join(map(str, cmd))}\n")
            f.flush()
            r = subprocess.run(cmd, cwd=cwd, env=e, stdout=f, stderr=subprocess.STDOUT,
                               shell=isinstance(cmd, str), timeout=timeout)
        if check and r.returncode != 0:
            tail = logf.read_text(errors="replace").splitlines()[-25:]
            raise SystemExit(f"stage {stage} failed (exit {r.returncode}); see {logf}\n" +
                             "\n".join(tail))
        return r.returncode

    def save_state(self):
        self.state_path.write_text(json.dumps(self.state, indent=2))

    # ---- stages ----------------------------------------------------------
    def fetch(self):
        repo = self.a.repo
        if Path(repo).is_dir():
            self.repo = Path(repo).resolve()
            self.log(f"using local checkout {self.repo}")
        else:
            name = re.sub(r"\.git$", "", repo.rstrip("/").split("/")[-1])
            self.repo = self.work / "repos" / name
            if not (self.repo / ".git").exists():
                self.repo.parent.mkdir(parents=True, exist_ok=True)
                self.log(f"cloning {repo}")
                subprocess.run(["git", "clone", "--recurse-submodules", repo, str(self.repo)],
                               check=True)
            if self.a.ref:
                subprocess.run(["git", "-C", str(self.repo), "checkout", "-q", self.a.ref], check=True)
            subprocess.run(["git", "-C", str(self.repo), "submodule", "update", "--init",
                            "--recursive"], check=True)
        if not (self.repo / "snesrecomp").is_dir():
            raise SystemExit(f"{self.repo} has no snesrecomp/ submodule: not a snesrecomp title")
        self.commit = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"],
                                     capture_output=True, text=True).stdout.strip()

    def identify(self):
        ident = {}
        f = self.repo / "rom_identity.txt"
        if f.exists():
            for line in f.read_text().splitlines():
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    ident[k.strip()] = v.strip().strip('"')
        if "display_name" not in ident:
            m = re.search(r"project\(\s*([A-Za-z0-9_]+)", (self.repo / "CMakeLists.txt").read_text())
            ident["display_name"] = re.sub(r"(SNES)?Recomp$", "", m.group(1)) if m else self.repo.name
        self.ident = ident
        self.title = self.a.title or ident["display_name"]
        self.id = self.a.id or re.sub(r"[^a-z0-9]", "", self.title.lower())
        (self.work / self.id).mkdir(parents=True, exist_ok=True)
        # ROM: strip a copier header, check it against the identity.
        data = self.rom_in.read_bytes()
        if len(data) % 1024 == 512:
            data = data[512:]
            self.log("stripped a 512-byte copier header from the ROM")
        self.rom = self.work / self.id / "rom.sfc"
        self.rom.write_bytes(data)
        sha1 = hashlib.sha1(data).hexdigest()
        sha256 = hashlib.sha256(data).hexdigest()
        crc = f"{zlib.crc32(data) & 0xffffffff:08x}"
        want = {k: ident.get(k, "").lower() for k in ("expected_sha1", "expected_sha256", "expected_crc32")}
        got = {"expected_sha1": sha1, "expected_sha256": sha256, "expected_crc32": crc}
        checked = [k for k in want if want[k]]
        bad = [k for k in checked if want[k] != got[k]]
        if bad:
            raise SystemExit(f"ROM does not match {self.repo.name}'s rom_identity.txt "
                             f"({', '.join(bad)}): got sha1 {sha1}")
        self.log(f"title '{self.title}' (id {self.id}), ROM sha1 {sha1}"
                 + (" verified" if checked else " (title declares no digest)"))
        self.state.update(id=self.id, title=self.title, sha1=sha1)

    def patch(self):
        def apply(repo, patch):
            if subprocess.run(["git", "-C", str(repo), "apply", "--reverse", "--check", str(patch)],
                              capture_output=True).returncode == 0:
                return "already applied"
            if subprocess.run(["git", "-C", str(repo), "apply", "--check", str(patch)],
                              capture_output=True).returncode == 0:
                subprocess.run(["git", "-C", str(repo), "apply", str(patch)], check=True)
                return "applied"
            # Framework drift: let git merge the hunks against its history.
            r = subprocess.run(["git", "-C", str(repo), "apply", "--3way", str(patch)],
                               capture_output=True, text=True)
            if r.returncode != 0:
                raise SystemExit(f"{patch.name} does not apply to {repo}:\n{r.stderr}")
            return "applied with 3-way merge"
        for p in sorted((HERE / "patches" / "snesrecomp").glob("*.patch")):
            self.log(f"framework patch {p.name}: {apply(self.repo / 'snesrecomp', p)}")
        for p in sorted((self.profile_dir / "patches").glob("*.patch")):
            self.log(f"title patch {p.name}: {apply(self.repo, p)}")

    @property
    def profile_dir(self):
        return HERE / "games" / self.id

    def regen(self):
        gen = self.repo / "src" / "gen"
        stamp = gen / ".srps4_regen"
        key = f"{self.commit} {self.state['sha1']}"
        if stamp.exists() and stamp.read_text().strip() == key and not self.a.force_regen:
            self.log("generated C is current for this commit and ROM")
            return
        env = {"RUSTUP_TOOLCHAIN": os.environ.get("RUSTUP_TOOLCHAIN", "stable")}
        rom_name = self.ident.get("rom_file")
        if rom_name:
            shutil.copyfile(self.rom, self.repo / rom_name)
        prof = self.profile_dir / "profile.sh"
        regen_py = self.repo / "tools" / "regen.py"
        if prof.exists() and "regen_game" in prof.read_text():
            cmd = f'. "{prof}"; regen_game'
            if "ROM_STAGE_NAME" in prof.read_text():
                stage = re.search(r'ROM_STAGE_NAME="([^"]+)"', prof.read_text()).group(1)
                shutil.copyfile(self.rom, self.repo / stage)
        elif regen_py.exists() and "--rom" in regen_py.read_text():
            cmd = [sys.executable, str(regen_py), "--rom", str(self.rom)]
        elif (self.repo / "tools" / "regen.sh").exists():
            cmd = ["bash", "tools/regen.sh"]
        else:
            raise SystemExit("no regeneration entry point (tools/regen.py or tools/regen.sh)")
        self.log("regenerating the recompiled C from your ROM")
        t = time.time()
        self.run(cmd if isinstance(cmd, list) else ["bash", "-c", cmd], "regen", cwd=self.repo, env=env)
        n = len(list(gen.glob("*.c")))
        if n == 0:
            raise SystemExit("regeneration produced no C in src/gen")
        stamp.write_text(key)
        self.log(f"regenerated {n} C files in {time.time() - t:.0f}s")

    def profile(self):
        d = self.profile_dir
        if (d / "game.cmake").exists() and "srps4_generic_game" not in (d / "game.cmake").read_text():
            self.log(f"curated profile games/{self.id} (kept as is)")
            self.generic = False
            return
        self.generic = True
        d.mkdir(parents=True, exist_ok=True)
        made = []
        def write(name, text):
            p = d / name
            if not p.exists():
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(text)
                made.append(name)
        slug = re.sub(r"[^A-Za-z0-9]", "", self.title)
        words = re.findall(r"[A-Za-z0-9]+", self.title.upper())
        letters = ("".join(w[0] for w in words) + slug.upper())[:3].ljust(3, "X") + "R"
        digits = int(hashlib.sha1(self.id.encode()).hexdigest(), 16) % 10000
        title_id = f"{letters}0{digits:04d}"
        label = (slug.upper() + "RECOMP")[:16].ljust(16, "0")
        write("game.cmake", 'include("${SRPS4_ROOT}/cmake/srps4_generic_game.cmake")\n')
        write("profile.cmake",
              "# Generated by scripts/srps4_convert.py: this title's package identity.\n"
              f'set(SRPS4_P_TITLE "{self.title}")\n'
              f'set(SRPS4_P_TITLE_ID "{title_id}")\n'
              f'set(SRPS4_P_LABEL "{label}")\n'
              f'set(SRPS4_P_DATA_DIR "{slug}")\n'
              'set(SRPS4_P_VERSION "01.00")\n')
        write("version.txt", "1.00-1\n")
        if not (d / "env_defaults.txt").exists():
            env_lines, notes = self.widescreen_defaults(d, write)
            write("env_defaults.txt",
                  "# Package defaults applied before /data/<Title>/srps4_env.txt (which wins).\n"
                  + "".join(f"{l}\n" for l in env_lines))
        else:
            notes = ["widescreen: the profile's existing defaults are kept"]
        if not (d / "icon0.png").exists():
            subprocess.run([sys.executable, str(HERE / "scripts" / "make_icon.py"),
                            str(d / "icon0.png"), self.title, "Recompiled"], check=True)
            made.append("icon0.png")
        for n in notes:
            self.log(n)
        self.log(f"profile games/{self.id}: " + (f"wrote {', '.join(made)}" if made else "reused"))

    def widescreen_defaults(self, d, write):
        """Find how this title turns widescreen on and default it on at 16:9."""
        env, notes = [], []
        # 1. A preloaded mod package with a widescreen feature.
        pk = self.repo / "mods" / "preloaded" / "packages"
        entries = []
        for manifest in sorted(pk.glob("*/*/manifest.toml")) if pk.is_dir() else []:
            try:
                m = tomllib.loads(manifest.read_text())
            except Exception:
                continue
            for feat in m.get("feature", []):
                if "widescreen" in (feat.get("id", "") + feat.get("name", "")).lower():
                    values = {}
                    for opt in m.get("option", []):
                        if opt.get("feature") == feat["id"] and opt.get("type") == "choice":
                            if any(c.get("value") == "16:9" for c in opt.get("choice", [])):
                                values[opt["id"]] = "16:9"
                    entries.append((m["id"], m.get("version", "1.0.0"), feat["id"], values))
        if entries:
            t = "format_version = 1\n"
            for pid, ver, _, _ in entries:
                t += f'\n[[package]]\nid = "{pid}"\nversion = "{ver}"\n'
            for pid, _, fid, values in entries:
                t += f'\n[[feature]]\npackage_id = "{pid}"\nid = "{fid}"\nenabled = true\n'
                if values:
                    t += "\n[feature.values]\n" + "".join(f'{k} = "{v}"\n' for k, v in values.items())
            write("defaults/mods/preloaded/state.toml", t)
            notes.append("widescreen: preloaded mod " + ", ".join(e[0] for e in entries) + " enabled at 16:9")
        # 2. Environment switches the title's own code honours.
        src = "\n".join(p.read_text(errors="replace") for p in (self.repo / "src").glob("*.c"))
        if 'getenv("SNESRECOMP_WIDESCREEN")' in src:
            env.append("SNESRECOMP_WIDESCREEN=1")
            notes.append("widescreen: title honours SNESRECOMP_WIDESCREEN; defaulted to 1")
        for var in sorted(set(re.findall(r'getenv\("([A-Z0-9_]*ASPECT)"\)', src))):
            env.append(f"{var}=16:9")
            notes.append(f"widescreen: {var} defaulted to 16:9")
        if not entries and not env:
            notes.append("widescreen: no switch found; the package runs at the title's default")
        return env, notes

    # ---- builds ----------------------------------------------------------
    def cmake_native(self, bdir, cflags, ldflags="", opt="-O2"):
        args = ["cmake", "-S", str(HERE), "-B", str(bdir), "-G", "Ninja",
                f"-DSRPS4_GAME={self.id}", f"-DSRPS4_GAME_ROOT={self.repo}", f"-DSRPS4_ROM={self.rom}",
                "-DCMAKE_C_COMPILER=clang-18", "-DCMAKE_CXX_COMPILER=clang++-18",
                "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_C_FLAGS_RELEASE={opt} -DNDEBUG",
                f"-DCMAKE_CXX_FLAGS_RELEASE={opt} -DNDEBUG",
                f"-DCMAKE_C_FLAGS=-march=btver2 {cflags}", f"-DCMAKE_CXX_FLAGS=-march=btver2 {cflags}",
                f"-DCMAKE_EXE_LINKER_FLAGS={ldflags}"]
        return args

    def build(self, bdir, args, stage):
        self.run(args, stage)
        t = time.time()
        self.run(["ninja", "-C", str(bdir)] + (["-j", str(self.a.jobs)] if self.a.jobs else []), stage)
        return time.time() - t

    def target_info(self, bdir):
        cache = (bdir / "CMakeCache.txt").read_text()
        m = re.search(r"^SRPS4_GAME_TARGET:INTERNAL=(.*)$", cache, re.M)
        tgt = m.group(1) if m else None
        if not tgt:   # curated profile: the target is the profile's
            gc = (self.profile_dir / "game.cmake").read_text()
            tgt = re.search(r"set\(TARGET\s+(\S+)\)", gc).group(1)
        exe = next((p for p in [bdir / "srps4_game" / tgt, bdir / tgt] if p.exists()), None)
        prof = (self.profile_dir / "profile.cmake")
        data_dir = re.search(r'SRPS4_P_DATA_DIR "([^"]+)"', prof.read_text()).group(1) if prof.exists() \
            else re.search(r'DATA_DIR "([^"]+)"', (self.profile_dir / "game.cmake").read_text()).group(1)
        return tgt, exe, bdir / f"pkg_{tgt}", data_dir

    def native(self):
        self.bn = self.work / self.id / "build-native"
        dt = self.build(self.bn, self.cmake_native(self.bn, ""), "native")
        self.log(f"native build ({dt:.0f}s)")

    def scripts(self):
        """Inputs to run: the profile's deterministic scripts, else attract mode."""
        s = sorted((self.profile_dir / "tests").glob("*.script")) if (self.profile_dir / "tests").is_dir() else []
        if self.id == "megamanx":
            s = sorted((HERE / "tests").glob("*.script"))
        return s or [None]

    def native_run(self, bdir, script, frames, present, extra_env=None, profile_start=None):
        tgt, exe, pkg, data_dir = self.target_info(bdir)
        tmp = Path(tempfile.mkdtemp(prefix="srps4run-", dir=self.work / self.id))
        dd = tmp / data_dir
        dd.mkdir(parents=True)
        # Uncapped: DisableFrameDelay in the player's config (seeded only once).
        over = tmp / "over.ini"
        over.write_text("[General]\nDisableFrameDelay = 1\n")
        subprocess.run([sys.executable, str(HERE / "scripts" / "merge_ini.py"),
                        str(pkg / "srps4" / "defaults" / "config.ini"), str(over), str(dd / "config.ini")],
                       check=True)
        args = []
        if script:
            shutil.copyfile(script, dd / "s.script")
            args = ["--script", "s.script"]
            if self.id == "megamanx":
                args += ["--benchmark", "100000"]
        env = {"SRPS4_PKG_DIR": str(pkg), "SRPS4_DATA_ROOT": str(tmp), "SDL_AUDIODRIVER": "dummy",
               "SNESRECOMP_HOST_PROFILE": "1", "SNESRECOMP_RUN_FRAMES": str(frames),
               "SNESRECOMP_PRESENT_LOG": str(present)}
        if profile_start:
            env["SNESRECOMP_HOST_PROFILE_START_FRAME"] = str(profile_start)
        env.update(extra_env or {})
        cmd = ["xvfb-run", "-a", "-s", "-screen 0 1920x1080x24", str(exe)] + args
        self.run(cmd, "verify", cwd=dd, env=env, check=False, timeout=7200)
        logtxt = (dd / "logs" / "last_run.txt").read_text(errors="replace") \
            if (dd / "logs" / "last_run.txt").exists() else ""
        shutil.rmtree(tmp, ignore_errors=True)
        return logtxt

    @staticmethod
    def stages_from(log):
        st = {}
        for m in re.finditer(r"stage=([a-z-]+) count=(\d+) total_ms=[0-9.]+ mean_ms=([0-9.]+) max_ms=([0-9.]+)", log):
            st[m.group(1)] = (int(m.group(2)), float(m.group(3)), float(m.group(4)))
        pipes = [float(x) for x in re.findall(r"pipe\] jobs=600 compose_ms/job=([0-9.]+)", log)]
        return st, pipes

    def verify(self):
        frames = self.a.frames
        results = []
        for script in self.scripts():
            name = script.stem if script else "attract"
            csvp = self.work / self.id / f"present_{name}.csv"
            # Single-threaded and synchronous, so the stage times measure code
            # speed; the pipelined compose is checked separately below.
            env = {"SNESRECOMP_RENDER_WORKERS": "1", "MMX_RENDER_PIPELINE": "0", "SM_RENDER_PIPELINE": "0"}
            log = self.native_run(self.bn, script, frames if not script else 10 ** 6, csvp, env,
                                  profile_start=self.a.profile_start)
            ok_exit = bool(re.search(r"exit: (RUN_FRAMES reached|script quit)", log))
            rows = list(csv.DictReader(open(csvp))) if csvp.exists() else []
            crcs = [r["crc32"] for r in rows]
            nonblank = sum(c != "00000000" for c in crcs)
            st, _ = self.stages_from(log)
            results.append((name, ok_exit, len(crcs), nonblank, len(set(crcs)), st))
            if not ok_exit or not crcs or nonblank == 0:
                raise SystemExit(f"native verification failed for {name}: exit_ok={ok_exit} "
                                 f"presents={len(crcs)} nonblank={nonblank}")
            # Pipelined compose (when the title has one): every present must
            # equal the synchronous present one frame earlier.
            if self.has_pipeline():
                csv2 = self.work / self.id / f"present_{name}_pipe.csv"
                penv = {"MMX_RENDER_PIPELINE": "1", "SM_RENDER_PIPELINE": "1"}
                self.native_run(self.bn, script, frames if not script else 10 ** 6, csv2, penv)
                b = [r["crc32"] for r in csv.DictReader(open(csv2))]
                mism = sum(1 for k in range(1, min(len(b), len(crcs))) if b[k] != crcs[k - 1])
                self.log(f"verify {name}: pipelined presents vs synchronous at one-frame offset: "
                         f"{mism} mismatches of {min(len(b), len(crcs)) - 1}")
                if mism:
                    raise SystemExit("pipelined compose does not reproduce the synchronous frames")
        self.verify_results = results
        for name, ok, n, nb, distinct, st in results:
            g = st.get("guest", (0, 0, 0))[1]
            r = st.get("raster-capture", (0, 0, 0))[1]
            c = st.get("compose", (0, 0, 0))[1]
            self.log(f"verify {name}: {n} presents ({nb} non-blank, {distinct} distinct); "
                     f"native single-thread guest {g:.3f} ms, capture {r:.3f} ms, compose {c:.3f} ms")
        self.estimate()

    def has_pipeline(self):
        root = self.repo / "src"
        return any("PipelineSubmit" in p.read_text(errors="replace") for p in root.glob("*_renderer.c"))

    def estimate(self):
        """Console frame-time estimate from native single-thread stage means."""
        lines = []
        for name, _, _, _, _, st in self.verify_results:
            g = st.get("guest", (0, 0, 0))[1] * JAGUAR_FACTOR
            r = st.get("raster-capture", (0, 0, 0))[1] * JAGUAR_FACTOR
            c = st.get("compose", (0, 0, 0))[1] * JAGUAR_FACTOR
            if self.has_pipeline():
                main = g + r + 1.5
                comp = c / 3.5   # 5 participants, part of each frame stays serial
                fits = main < FRAME_BUDGET_MS * 0.8 and comp < FRAME_BUDGET_MS * 0.9
                lines.append(f"estimate {name}: main thread ~{main:.1f} ms (guest {g:.1f} + capture {r:.1f} "
                             f"+ present), compose thread ~{comp:.1f} ms -> "
                             f"{'60 fps expected' if fits else 'AT RISK of dropping below 60 fps'}")
            else:
                main = g + r + c + 1.5
                fits = main < FRAME_BUDGET_MS * 0.8
                lines.append(f"estimate {name}: main thread ~{main:.1f} ms (guest {g:.1f} + capture {r:.1f} "
                             f"+ compose {c:.1f} + present) -> "
                             f"{'60 fps expected' if fits else 'AT RISK: needs a title patch (parallel/pipelined compose)'}")
        for l in lines:
            self.log(l)

    def pgo(self):
        if self.a.skip_pgo:
            self.log("PGO skipped")
            return
        bp = self.work / self.id / "build-pgo-train"
        self.build(bp, self.cmake_native(bp, "-fprofile-instr-generate", "-fprofile-instr-generate"), "pgo")
        raw = bp / "profraw"
        shutil.rmtree(raw, ignore_errors=True)
        raw.mkdir()
        for script in self.scripts():
            csvp = self.work / self.id / "pgo_present.csv"
            self.native_run(bp, script, self.a.frames if not script else 10 ** 6, csvp,
                            {"LLVM_PROFILE_FILE": str(raw / "%p.profraw"),
                             "MMX_RENDER_PIPELINE": "1", "SM_RENDER_PIPELINE": "1"})
        prof = self.profile_dir / "pgo.profdata"
        self.run(["llvm-profdata", "merge", "-o", str(prof)] + [str(p) for p in raw.glob("*.profraw")], "pgo")
        self.log(f"PGO profile {prof.relative_to(HERE)} ({prof.stat().st_size // 1024} KiB)")

    def ps4(self):
        sdk = Path(self.a.sdk).resolve()
        bdir = self.work / self.id / "build-ps4"
        env_sh = HERE / "scripts" / "env.sh"
        rom_arg = "" if self.a.no_bundle_rom else f'-DSRPS4_ROM="{self.rom}"'
        cmd = (f'export SRPS4_SDK="{sdk}"; . "{env_sh}"; '
               f'openorbis-cmake -S "{HERE}" -B "{bdir}" -G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 '
               f'-DCMAKE_BUILD_TYPE=Release -DSRPS4_GAME={self.id} -DSRPS4_GAME_ROOT="{self.repo}" '
               f'-DSDL2_DIR="$OPENORBIS/usr/lib/cmake/SDL2" {rom_arg} && ninja -C "{bdir}"'
               + (f" -j {self.a.jobs}" if self.a.jobs else ""))
        t = time.time()
        self.run(["bash", "-c", cmd], "ps4")
        pkgs = sorted(bdir.glob("*.pkg"))
        if not pkgs:
            raise SystemExit("PS4 build produced no .pkg")
        self.out.mkdir(parents=True, exist_ok=True)
        self.pkg = self.out / pkgs[0].name
        shutil.copyfile(pkgs[0], self.pkg)
        sha = hashlib.sha256(self.pkg.read_bytes()).hexdigest()
        self.state.update(pkg=str(self.pkg), pkg_sha256=sha)
        self.log(f"package {self.pkg.name} ({self.pkg.stat().st_size // (1 << 20)} MiB, sha256 {sha}) "
                 f"built in {time.time() - t:.0f}s")

    def emulator(self):
        emu = Path(self.a.emulator) if self.a.emulator else None
        if not emu or not emu.exists():
            self.log("emulator check skipped (no shadPS4 given)")
            return
        sdk = Path(self.a.sdk).resolve()
        emu_sdk = Path(self.a.emu_sdk) if self.a.emu_sdk else None
        bdir = self.work / self.id / "build-ps4"
        tgt, _, pkg, data_dir = self.target_info(bdir)
        # shadPS4 stubs sceLibcMspace*: relink against musl's own allocator.
        link = subprocess.run(["ninja", "-C", str(bdir), "-t", "commands", tgt],
                              capture_output=True, text=True).stdout.strip().splitlines()[-1]
        link = link.split(" && cd ")[0]
        elf = bdir / f"{tgt}.emu"
        if emu_sdk and (emu_sdk / "lib").is_dir():
            link = link.replace(f" -L{sdk}/lib ", f" -L{emu_sdk}/lib -L{sdk}/lib ") \
                       .replace(f"{sdk}/lib/crt1.o", f"{emu_sdk}/lib/crt1.o")
        link = re.sub(r" -o \S+ ", f" -o {elf} ", link, count=1)
        self.run(["bash", "-c", f"cd {bdir} && {link}"], "emulator")
        app = self.work / self.id / "emu-app"
        shutil.rmtree(app, ignore_errors=True)
        shutil.copytree(pkg, app, ignore=shutil.ignore_patterns("*.gp4"))
        self.run([str(sdk / "bin" / "create-fself"), f"-in={elf}", f"-out={bdir / (tgt + '.emu.oelf')}",
                  "--eboot", str(app / "eboot.bin"), "--paid", "0x3800000000000035"], "emulator",
                 env={"OO_PS4_TOOLCHAIN": str(sdk)})
        # shadPS4 needs an initialized home (users.json, input config): a
        # brand-new one stalls at boot, so reuse the one given, resetting only
        # this title's data directory.
        if self.a.emu_home:
            home = Path(self.a.emu_home).resolve()
        else:
            home = self.work / self.id / "emu-home"
            shutil.rmtree(home, ignore_errors=True)
        dd = home / ".local" / "share" / "shadPS4" / "data" / data_dir
        shutil.rmtree(dd, ignore_errors=True)
        dd.mkdir(parents=True)
        frames = min(self.a.frames, 2400)
        (dd / "srps4_env.txt").write_text(
            f"SDL_VIDEODRIVER=dummy\nSNESRECOMP_RUN_FRAMES={frames}\n"
            f"SNESRECOMP_PRESENT_LOG=/data/{data_dir}/emu_presents.csv\n")
        try:
            self.run(["xvfb-run", "-a", str(emu), "-g", str(app / "eboot.bin")], "emulator",
                     env={"HOME": str(home)}, check=False, timeout=self.a.emu_timeout)
        except subprocess.TimeoutExpired:
            subprocess.run(["pkill", "-f", f"-g {app / 'eboot.bin'}"])
            self.log(f"emulator: no exit within {self.a.emu_timeout}s")
        last = dd / "logs" / "last_run.txt"
        txt = last.read_text(errors="replace") if last.exists() else ""
        ok = bool(re.search(r"exit: RUN_FRAMES reached", txt))
        pres = dd / "emu_presents.csv"
        crcs = [r["crc32"] for r in csv.DictReader(open(pres))] if pres.exists() else []
        nonblank = sum(c != "00000000" for c in crcs)
        self.log(f"emulator: console eboot ran {len(crcs)} presents ({nonblank} non-blank), "
                 f"clean exit: {ok}")
        # The console build against the native synchronous run of the same
        # input (attract mode): pipelined titles present one frame later.
        native = self.work / self.id / "present_attract.csv"
        if native.exists() and crcs:
            ref = [r["crc32"] for r in csv.DictReader(open(native))]
            off = 1 if self.has_pipeline() else 0
            n = min(len(crcs), len(ref) + off) - off
            mism = sum(1 for k in range(off, off + n) if crcs[k] != ref[k - off])
            self.log(f"emulator: console presents vs native presents"
                     f"{' at one-frame offset' if off else ''}: {mism} mismatches of {n}"
                     + ("" if not mism else " (shadPS4 can differ from native for environmental "
                        "reasons; boot and clean exit are the gate)"))
        if not ok or nonblank == 0:
            raise SystemExit(f"console eboot failed under shadPS4; see {last}")

    def write_report(self):
        self.out.mkdir(parents=True, exist_ok=True)
        rp = self.out / f"{self.id}-report.md"
        body = ""
        for st in STAGES:
            lines = self.state.get("stage_log", {}).get(st)
            if lines:
                body += f"\n## {st}\n\n" + "".join(f"- {l}\n" for l in lines)
        rp.write_text(f"# {self.title}: srps4-convert report\n\n"
                      f"Source: `{self.a.repo}` @ `{self.commit}`\n" + body)
        print(f"report: {rp}")

    # ---- driver ----------------------------------------------------------
    def main(self):
        start = STAGES.index(self.a.from_stage) if self.a.from_stage else 0
        stop = STAGES.index(self.a.to_stage) if self.a.to_stage else len(STAGES) - 1
        self.fetch()
        self.identify()
        self.state_path = self.work / self.id / "state.json"
        if self.state_path.exists():
            # Resume: keep earlier stages' results for the report.
            prev = json.loads(self.state_path.read_text())
            fresh = self.state.get("stage_log", {})
            prev.update({k: v for k, v in self.state.items() if k != "stage_log"})
            prev.setdefault("stage_log", {}).update(fresh)
            self.state = prev
        self.bn = self.work / self.id / "build-native"
        for i, st in enumerate(STAGES):
            if st in ("fetch", "identify"):
                continue
            if i < start or i > stop:
                if st == "profile":
                    self.generic = (self.profile_dir / "game.cmake").exists() and \
                        "srps4_generic_game" in (self.profile_dir / "game.cmake").read_text()
                continue
            if st == "native" and self.a.skip_native:
                continue
            if st in ("verify", "pgo") and self.a.skip_native:
                continue
            self.stage = st
            self.state.setdefault("stage_log", {})[st] = []
            getattr(self, "write_report" if st == "report" else st)()
            self.state.setdefault("done", []).append(st)
            self.save_state()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", required=True, help="title repository: git URL or local checkout")
    ap.add_argument("--rom", required=True, help="your ROM (.sfc/.smc)")
    ap.add_argument("--ref", help="commit/tag to build (default: the repository's HEAD)")
    ap.add_argument("--id", help="profile id (default: from the title's display name)")
    ap.add_argument("--title", help="title shown on the PS4 (default: rom_identity display_name)")
    ap.add_argument("--work", default=str(HERE / "work"))
    ap.add_argument("--out", default=str(HERE / "out"))
    ap.add_argument("--sdk", default=os.environ.get("SRPS4_SDK", str(Path.home() / "ps4sdk")))
    ap.add_argument("--emulator", default=os.environ.get("SHADPS4"), help="shadPS4 binary for the smoke test")
    ap.add_argument("--emu-sdk", default=os.environ.get("SRPS4_EMU_SDK"),
                    help="musl-malloc libc dir for the emulator relink (shadPS4 stubs sceLibcMspace)")
    ap.add_argument("--emu-home", default=os.environ.get("SHADPS4_HOME"),
                    help="an initialized shadPS4 HOME to reuse (a fresh one stalls at boot)")
    ap.add_argument("--emu-timeout", type=int, default=2400, help="seconds before the emulator run is abandoned")
    ap.add_argument("--frames", type=int, default=6000, help="frames per attract-mode verification run")
    ap.add_argument("--profile-start", type=int, default=0, help="first profiled frame (skip boot/title)")
    ap.add_argument("--jobs", type=int, default=0)
    ap.add_argument("--no-bundle-rom", action="store_true")
    ap.add_argument("--skip-native", action="store_true", help="skip native build, verification and PGO")
    ap.add_argument("--skip-pgo", action="store_true")
    ap.add_argument("--force-regen", action="store_true")
    ap.add_argument("--from", dest="from_stage", choices=STAGES)
    ap.add_argument("--to", dest="to_stage", choices=STAGES)
    Converter(ap.parse_args()).main()


if __name__ == "__main__":
    main()
