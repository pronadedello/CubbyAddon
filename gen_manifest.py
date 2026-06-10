#!/usr/bin/env python3
"""Generate manifest.json for the Cubby live-installer.

The manifest lists exactly the addon runtime files the WoW client loads — the
modules declared in Cubby.toc, plus the .toc and .tga themselves — each with a
SHA-256 hash, plus a version string. install.ps1 polls this file and downloads
anything whose local hash doesn't match into Interface\\AddOns\\Cubby.

Run from anywhere; paths resolve relative to the repo root.
"""
import datetime
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TOC = ROOT / "Cubby.toc"


def toc_modules(toc_text: str) -> list[str]:
    """Lua/XML files listed (one per line) in the .toc, in load order."""
    out = []
    for line in toc_text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if re.search(r"\.(lua|xml)$", line, re.IGNORECASE):
            out.append(line)
    return out


def main() -> int:
    toc_text = TOC.read_text(encoding="utf-8")

    m = re.search(r"^##\s*Version:\s*(.+)$", toc_text, re.MULTILINE)
    base_ver = m.group(1).strip() if m else "0.0.0"
    # Timestamp suffix makes every regen a distinct version, so the installer
    # logs a transition on each push. File hashes still gate actual downloads.
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M%S")
    # `-` rather than `+`: `+` is reserved in URL query strings (decoded as
    # space), which made it brittle when the version got echoed into URLs.
    version = f"{base_ver}-{stamp}"

    payload = ["Cubby.toc", *toc_modules(toc_text), "Cubby.tga"]
    files = []
    for name in payload:
        p = ROOT / name
        if not p.exists():
            print(f"WARN: {name} listed but missing on disk", file=sys.stderr)
            continue
        digest = hashlib.sha256(p.read_bytes()).hexdigest()
        files.append({"name": name, "hash": digest})

    manifest = {"name": "Cubby", "version": version, "files": files}
    out = ROOT / "manifest.json"
    out.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out.name}: v{version}, {len(files)} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
