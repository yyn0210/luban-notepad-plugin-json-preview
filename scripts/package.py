#!/usr/bin/env python3
"""Build the plugin zip and validate its manifest.

Usage:
    python3 scripts/package.py            # writes dist/<id>-<version>.zip
    python3 scripts/package.py --check    # validates and builds in memory
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "plugin.json"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
SEMVER_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$")
FILES = ("plugin.json", "main.lua", "json/parser.lua", "json/display.lua",
         "json/path.lua", "json/tree.lua", "json/meta.lua",
         "README.md", "LICENSE", "CHANGELOG.md")
MAX_MANIFEST = 256 * 1024
MAX_MAIN = 2 * 1024 * 1024


def load_manifest() -> dict:
    raw = MANIFEST.read_bytes()
    if len(raw) > MAX_MANIFEST:
        raise SystemExit(f"plugin.json is larger than {MAX_MANIFEST} bytes")
    try:
        manifest = json.loads(raw)
    except json.JSONDecodeError as error:
        raise SystemExit(f"invalid plugin.json: {error}") from error
    for key in ("id", "name", "version", "api_version", "main"):
        if key not in manifest:
            raise SystemExit(f"plugin.json is missing '{key}'")
    if not ID_RE.match(manifest["id"]):
        raise SystemExit(f"invalid plugin id: {manifest['id']}")
    if not SEMVER_RE.match(manifest["version"]):
        raise SystemExit(f"invalid version: {manifest['version']}")
    if manifest["api_version"] != 2:
        raise SystemExit("this plugin targets api_version 2")
    # Every Lua module main.lua requires must be packaged. The zip keeps the
    # plugin-root layout (json/parser.lua etc.) so the sandboxed in-plugin
    # `require` can resolve `json.parser` -> json/parser.lua.
    required_modules = ("json/parser.lua", "json/display.lua", "json/path.lua",
                        "json/tree.lua", "json/meta.lua")
    for module in required_modules:
        if not (ROOT / module).is_file():
            raise SystemExit(f"module file not found: {module}")
    main = (ROOT / manifest["main"]).resolve()
    if ROOT not in main.parents:
        raise SystemExit("main escapes the plugin directory")
    if main.suffix != ".lua" or not main.is_file():
        raise SystemExit(f"main file not found: {manifest['main']}")
    if main.stat().st_size > MAX_MAIN:
        raise SystemExit(f"{manifest['main']} is larger than {MAX_MAIN} bytes")
    tag = os.environ.get("GITHUB_REF_NAME", "")
    if tag.startswith("v") and tag != f"v{manifest['version']}":
        raise SystemExit(f"tag {tag} does not match version v{manifest['version']}")
    return manifest


def build_zip(manifest: dict, target: io.BufferedIOBase) -> None:
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in FILES:
            path = ROOT / name
            if not path.is_file():
                continue
            info = zipfile.ZipInfo(name, date_time=(2026, 11, 8, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="validate without writing dist/")
    args = parser.parse_args()

    manifest = load_manifest()
    filename = f"{manifest['id']}-{manifest['version']}.zip"

    if args.check:
        buffer = io.BytesIO()
        build_zip(manifest, buffer)
        with zipfile.ZipFile(io.BytesIO(buffer.getvalue())) as archive:
            names = archive.namelist()
            if names.count("plugin.json") != 1:
                raise SystemExit("the archive must contain exactly one plugin.json")
            for name in FILES:
                if name.endswith(".lua") and names.count(name) != 1:
                    raise SystemExit(f"the archive must contain {name}")
            with archive.open("plugin.json") as handle:
                packaged = json.load(handle)
            if packaged.get("id") != manifest["id"] or packaged.get("version") != manifest["version"]:
                raise SystemExit("packaged manifest identity does not match")
        print(f"ok: {filename} ({len(buffer.getvalue())} bytes)")
        print(f"sha256: {hashlib.sha256(buffer.getvalue()).hexdigest()}")
        return 0

    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    output = dist / filename
    with output.open("wb") as handle:
        build_zip(manifest, handle)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    print(f"built {output.relative_to(ROOT)}")
    print(f"sha256: {digest}")
    print(f"size: {output.stat().st_size}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
