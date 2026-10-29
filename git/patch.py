#!/usr/bin/env python3
"""Small fixes to a-Shell's lg2 commands: plain `git branch` lists branches, and status prints no debug line."""
import pathlib, sys

examples = pathlib.Path(sys.argv[1])

def patch(name, old, new):
    file = examples / name
    text = file.read_text()
    if new and new in text:
        return
    if text.count(old) != 1:
        sys.exit(f"{name}: expected one match for {old[:60]!r}")
    file.write_text(text.replace(old, new))

patch("status.c", '\t\tfprintf(stderr, "header= %d listing_index_changes: %d\\n", header, listing_index_changes);\n', "")
patch("branch.c", 'int list_branches = (argc == 2 && strcmp(argv[1], "--list") == 0);',
      'int list_branches = argc == 1 || (argc == 2 && strcmp(argv[1], "--list") == 0);')
patch("branch.c", "if (argc < 2 || argc > 3 || (argc == 3 && !delete_branch && !set_upstream)\n\t\t\t\t|| strcmp(argv[1], \"-h\") == 0 || strcmp(argv[1], \"--help\") == 0) {",
      "if ((argc < 2 && !list_branches) || argc > 3 || (argc == 3 && !delete_branch && !set_upstream)\n\t\t\t\t|| (argc >= 2 && (strcmp(argv[1], \"-h\") == 0 || strcmp(argv[1], \"--help\") == 0))) {")
