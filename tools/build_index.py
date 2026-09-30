#!/usr/bin/env python3
"""index.json for the Lumen plugin store from the folders in plugins/.

    python tools/build_index.py

Every file of a plugin is listed with its SHA-256 sum; files below bin/<platform>/
are marked with that platform (windows, macos, linux) and only installed there.
Hidden files, sources (src/) and READMEs of the repository itself are not part of
an installation, the plugin's README.md is.
"""
import hashlib
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLATFORMS = ("windows", "macos", "linux")


def main():
    plugins = []
    base = os.path.join(ROOT, "plugins")
    for pid in sorted(os.listdir(base)):
        folder = os.path.join(base, pid)
        manifest = os.path.join(folder, "plugin.json")
        if not os.path.isfile(manifest):
            continue
        meta = json.load(open(manifest, encoding="utf-8"))
        files = []
        for dirpath, dirnames, filenames in os.walk(folder):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d != "src")
            for fn in sorted(filenames):
                if fn.startswith("."):
                    continue
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, folder).replace(os.sep, "/")
                entry = {"path": rel, "sha256": hashlib.sha256(open(full, "rb").read()).hexdigest()}
                parts = rel.split("/")
                if len(parts) > 2 and parts[0] == "bin" and parts[1] in PLATFORMS:
                    entry["platform"] = parts[1]
                files.append(entry)
        plugins.append({
            "id": meta.get("id", pid),
            "name": meta.get("name", pid),
            "version": meta.get("version", "0"),
            "description": meta.get("description", ""),
            "author": meta.get("author", ""),
            "path": f"plugins/{pid}",
            "files": files,
        })
    index = {"format": 1, "name": "Lumen Plugins (official)", "plugins": plugins}
    with open(os.path.join(ROOT, "index.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(index, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"index.json: {len(plugins)} plugin(s)")


if __name__ == "__main__":
    sys.exit(main())
