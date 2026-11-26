#!/usr/bin/env python3
"""Sanity checks for a hand-edited project.pbxproj.

The real validator is Xcode; this catches the mistakes a scripted edit makes:
an id that is referenced but never defined, a file added to the group but not
to the Sources phase (or the reverse), and unbalanced braces.
"""

import re
import sys
from pathlib import Path

PBX = Path("src/ios/Minis.xcodeproj/project.pbxproj")
# Files this change is responsible for; each must appear in exactly one
# PBXBuildFile, one PBXFileReference, one group and one Sources entry.
REQUIRED = ["PluginStore.swift", "PluginsSettingsView.swift"]


def main() -> int:
    text = PBX.read_text(encoding="utf-8")
    problems = []

    if text.count("{") != text.count("}"):
        problems.append(f"unbalanced braces: {text.count('{')} open, {text.count('}')} close")
    if text.count("(") != text.count(")"):
        problems.append(f"unbalanced parens: {text.count('(')} open, {text.count(')')} close")

    for name in REQUIRED:
        build = len(re.findall(r"/\* " + re.escape(name) + r" in Sources \*/ = \{isa = PBXBuildFile", text))
        ref = len(re.findall(r"/\* " + re.escape(name) + r" \*/ = \{isa = PBXFileReference", text))
        listed = len(re.findall(r"^\t+[A-Z0-9]+ /\* " + re.escape(name) + r" in Sources \*/,", text, re.M))
        group = len(re.findall(r"^\t+[A-Z0-9]+ /\* " + re.escape(name) + r" \*/,", text, re.M))
        for label, count in (("PBXBuildFile", build), ("PBXFileReference", ref),
                             ("Sources phase", listed), ("group child", group)):
            if count != 1:
                problems.append(f"{name}: expected 1 {label} entry, found {count}")

    # Every id used in a fileRef must be declared somewhere.
    declared = set(re.findall(r"^\t\t([A-Za-z0-9]+) /\*", text, re.M))
    for ref in re.findall(r"fileRef = ([A-Za-z0-9]+) /\*", text):
        if ref not in declared:
            problems.append(f"fileRef {ref} is referenced but never declared")

    if problems:
        for p in problems:
            print(f"::error::{p}")
        return 1
    print("project.pbxproj: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())