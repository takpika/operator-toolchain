#!/usr/bin/env python3
"""Removes DWARF (`.debug_*` custom sections) from WebAssembly modules in place, keeping everything else (`dylink.0`,
`name`, ...). Usage: strip-debug.py FILE..."""
import sys


def leb(data, i):
    result = shift = 0
    while True:
        byte = data[i]
        i += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return result, i


for path in sys.argv[1:]:
    data = open(path, "rb").read()
    if data[:4] != b"\0asm":
        continue
    out = bytearray(data[:8])
    i = 8
    while i < len(data):
        start = i
        section = data[i]
        size, body = leb(data, i + 1)
        i = body + size
        if section == 0:
            length, name = leb(data, body)
            if data[name:name + length].startswith(b".debug"):
                continue
        out += data[start:i]
    open(path, "wb").write(out)
