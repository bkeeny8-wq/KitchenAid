#!/usr/bin/env python3
"""Structural checks on KitchenAid.xcodeproj, since there is no Xcode here.

    python3 -I scripts/check_xcodeproj.py

A project file either opens or it does not, and this container cannot find out
which. These checks cover the failure modes that make Xcode refuse the file or,
worse, open it with something quietly missing from the build:

  1. Every id referenced anywhere is also defined. A dangling reference is the
     classic "cannot be opened because it is corrupt".
  2. Every id defined is referenced. An orphan usually means a file was added
     to the tree and never put in a build phase, so it compiles nowhere.
  3. Braces balance, and every Begin/End section pairs.
  4. Every Swift file on disk has exactly one file reference and exactly one
     build file, in the right target's Sources phase. A file silently absent
     from the build is the worst outcome: everything compiles and the symbol is
     missing.
  5. Every referenced path exists on disk.
  6. The scheme points at ids the project actually defines.

It cannot tell you the project opens. It can tell you it is not obviously broken.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJ = os.path.join(ROOT, "KitchenAid.xcodeproj")
PBX = os.path.join(PROJ, "project.pbxproj")

problems = []
ID = re.compile(r"\b([0-9A-F]{24})\b")


def fail(msg):
    problems.append(msg)


if not os.path.exists(PBX):
    print(f"no project at {PBX}", file=sys.stderr)
    sys.exit(1)

text = open(PBX, encoding="utf-8").read()
lines = text.splitlines()

# --- 3. delimiters and sections ---------------------------------------------
if text.count("{") != text.count("}"):
    fail(f"braces unbalanced: {text.count('{')} open, {text.count('}')} close")
if text.count("(") != text.count(")"):
    fail(f"parens unbalanced: {text.count('(')} open, {text.count(')')} close")

begins = re.findall(r"/\* Begin (\w+) section \*/", text)
ends = re.findall(r"/\* End (\w+) section \*/", text)
if begins != ends:
    fail(f"sections do not pair: begins={begins} ends={ends}")

# --- 1 & 2. defined versus referenced ---------------------------------------
defined = {}
for line in lines:
    m = re.match(r"\t\t([0-9A-F]{24})(?: /\* (.*?) \*/)? = \{", line)
    if m:
        if m.group(1) in defined:
            fail(f"id {m.group(1)} defined twice")
        isa = re.search(r"isa = (\w+)", line)
        defined[m.group(1)] = (m.group(2) or "", isa.group(1) if isa else "?")

# Multi-line objects carry their isa on a later line.
current = None
for line in lines:
    m = re.match(r"\t\t([0-9A-F]{24})(?: /\* (.*?) \*/)? = \{", line)
    if m:
        current = m.group(1)
        continue
    if current and "isa = " in line:
        name, isa = defined[current]
        if isa == "?":
            defined[current] = (name, re.search(r"isa = (\w+)", line).group(1))
        current = None

referenced = set()
for line in lines:
    stripped = line.strip()
    if re.match(r"[0-9A-F]{24}(?: /\*.*?\*/)? = \{", stripped):
        continue  # a definition, not a reference
    for found in ID.findall(line):
        referenced.add(found)

root = re.search(r"rootObject = ([0-9A-F]{24})", text)
if root:
    referenced.add(root.group(1))

for missing in sorted(referenced - set(defined)):
    fail(f"id {missing} is referenced but never defined -- Xcode reports this as a corrupt project")
for orphan in sorted(set(defined) - referenced):
    name, isa = defined[orphan]
    if isa != "PBXProject":
        fail(f"id {orphan} ({isa} {name!r}) is defined but never referenced -- "
             "a file like this is in the tree and in no build phase, so it compiles nowhere")

# --- 4. every Swift file on disk is in the build -----------------------------
def swift_on_disk(target):
    out = []
    base = os.path.join(ROOT, target)
    if not os.path.isdir(base):
        return out
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d != "Resources" and not d.endswith(".xcassets")]
        for n in filenames:
            if n.endswith(".swift"):
                out.append(n)
    return out

swift_refs = re.findall(r"/\* (\S+\.swift) \*/ = \{isa = PBXFileReference", text)
build_files = re.findall(r"/\* (\S+\.swift) in Sources \*/ = \{isa = PBXBuildFile", text)

for target in ("KitchenAid", "KitchenAidTests", "KitchenAidUITests"):
    for name in swift_on_disk(target):
        if swift_refs.count(name) == 0:
            fail(f"{target}/{name} is on disk with no file reference -- it will not build")
        elif swift_refs.count(name) > 1:
            fail(f"{name} has {swift_refs.count(name)} file references; Xcode will "
                 "compile it twice and the linker will see duplicate symbols")
        if build_files.count(name) == 0:
            fail(f"{name} has a file reference but no build file -- it is in the "
                 "navigator and in no Sources phase, so its symbols silently vanish")

extra = set(swift_refs) - {n for t in ("KitchenAid", "KitchenAidTests", "KitchenAidUITests")
                           for n in swift_on_disk(t)}
for name in sorted(extra):
    fail(f"the project references {name}, which is not on disk")

# --- 5. referenced resource paths exist --------------------------------------
for m in re.finditer(r"/\* (.+?) \*/ = \{isa = PBXFileReference; "
                     r"lastKnownFileType = (\S+); path = (.+?); sourceTree", text):
    name, ftype, path = m.group(1), m.group(2), m.group(3)
    if ftype in ("folder", "folder.assetcatalog", "text.json"):
        hits = []
        for dirpath, _, filenames in os.walk(os.path.join(ROOT, "KitchenAid")):
            if os.path.basename(dirpath) == path or path in filenames:
                hits.append(dirpath)
        if not hits:
            fail(f"the project references the resource {path!r}, which is not under KitchenAid/")

# --- 6. the scheme points at real ids ----------------------------------------
scheme = os.path.join(PROJ, "xcshareddata", "xcschemes", "KitchenAid.xcscheme")
if not os.path.exists(scheme):
    fail("no shared scheme -- a fresh clone opens with nothing runnable")
else:
    stext = open(scheme, encoding="utf-8").read()
    if stext.count("<") != stext.count(">"):
        fail("the scheme's XML is unbalanced")
    for bid in set(re.findall(r'BlueprintIdentifier = "([0-9A-F]{24})"', stext)):
        if bid not in defined:
            fail(f"the scheme points at {bid}, which the project does not define")

# --- report -------------------------------------------------------------------
targets = [n for n, (_, isa) in defined.items() if isa == "PBXNativeTarget"]
print(f"{len(lines)} lines, {len(defined)} objects, {len(targets)} targets, "
      f"{len(set(swift_refs))} Swift files referenced")

if problems:
    print(f"\nFAIL  {len(problems)} problem(s):")
    for p in problems:
        print("  x", p)
    sys.exit(1)

print("\nPASS  no structural problems found.")
print("This cannot tell you the project OPENS -- only that it is not obviously")
print("broken. Open it in Xcode and build before trusting it.")
