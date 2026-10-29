#!/usr/bin/env python3
"""Rewrites the shims' and bindgen's package imports (@bytecodealliance/preview2-shim/cli) to relative paths, so the
files work as plain ES modules in a web view without an import map. Node-only entry points are left alone."""
import os, pathlib, re, sys

root = pathlib.Path(sys.argv[1])
packages = {"@bytecodealliance/preview2-shim": root / "p2/dist/browser",
            "@bytecodealliance/preview3-shim": root / "p3/dist/browser"}
pattern = re.compile(r"""((?:from|import)\s*\(?\s*)(['"])(@bytecodealliance/preview[23]-shim)(?:/([\w/-]+))?\2""")

def relink(file, match):
    path = packages[match.group(3)] / ((match.group(4) or "index") + ".js")
    if not path.exists():
        return match.group(0)
    relative = os.path.relpath(path, file.parent)
    return f"{match.group(1)}{match.group(2)}{relative if relative.startswith('..') else './' + relative}{match.group(2)}"

for file in root.rglob("*.js"):
    text = file.read_text()
    new = pattern.sub(lambda m: relink(file, m), text)
    if new != text:
        file.write_text(new)
