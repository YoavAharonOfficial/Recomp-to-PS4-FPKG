#!/usr/bin/env python3
"""merge_ini.py BASE OVERRIDES OUT

Layer OVERRIDES on top of BASE, keeping BASE's comments, order and layout.
A key present in OVERRIDES replaces the value of the same key in the same
[section] of BASE; keys/sections BASE lacks are appended. Lines starting with
';' or '#' in OVERRIDES are ignored."""
import re
import sys


def parse_overrides(path):
    out, section = {}, None
    for raw in open(path, encoding="utf-8"):
        line = raw.strip()
        if not line or line[0] in ";#":
            continue
        m = re.match(r"\[(.+)\]$", line)
        if m:
            section = m.group(1).strip()
            out.setdefault(section, {})
            continue
        if "=" in line and section:
            k, v = line.split("=", 1)
            out[section][k.strip()] = v.strip()
    return out


def main(base, overrides, dest):
    ov = parse_overrides(overrides)
    pending = {s: dict(kv) for s, kv in ov.items()}
    lines, section = [], None

    def flush(sec):
        for k, v in pending.get(sec, {}).items():
            lines.append(f"{k} = {v}\n")
        pending.pop(sec, None)

    for raw in open(base, encoding="utf-8"):
        stripped = raw.strip()
        m = re.match(r"\[(.+)\]$", stripped)
        if m:
            if section is not None:
                flush(section)
            section = m.group(1).strip()
            lines.append(raw)
            continue
        if section and "=" in stripped and stripped[0] not in ";#":
            key = stripped.split("=", 1)[0].strip()
            if key in pending.get(section, {}):
                lines.append(f"{key} = {pending[section].pop(key)}\n")
                continue
        lines.append(raw)
    if section is not None:
        flush(section)
    for sec in list(pending):
        lines.append(f"\n[{sec}]\n")
        flush(sec)
    with open(dest, "w", encoding="utf-8") as f:
        f.writelines(lines)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
