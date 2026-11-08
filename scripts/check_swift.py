#!/usr/bin/env python3
"""Static checks on the Swift that a compiler would catch, since there isn't one.

    python3 -I scripts/check_swift.py

This project's Swift is written in a Linux container with no Apple toolchain, so
these checks are the only automated feedback that exists before a build on
Brandon's Mac. They are deliberately narrow: each one catches a class of defect
that actually happened here, and none of them pretends to type-check Swift.

  1. Every @Model is in the schema array, and every schema entry is a @Model.
     A model missing from the array is NOT a compile error -- it just has no
     table, and the first fetch fails at runtime on a device with real data.
  2. Braces, parens and brackets balance in every file.
  3. No @Attribute(.unique) -- CloudKit-backed stores reject it (CLAUDE.md).
  4. No symbol from a declined feature has crept back in.
  5. Type names used but declared nowhere in the tree -- in a type position, or
     as a constructor. This is a heuristic with an allowlist, and it is the
     check that found CalendarKey and RecipeLoader being referenced by files
     that compiled against nothing. It FAILS rather than warns, for the reason
     recorded at the check itself.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "KitchenAid")

problems = []


def swift_files():
    for base, _, names in os.walk(SRC):
        for n in sorted(names):
            if n.endswith(".swift"):
                yield os.path.join(base, n)


def rel(p):
    return os.path.relpath(p, ROOT)


def strip_noise(text):
    """Remove string literals and comments so braces and identifiers inside them
    do not count. Crude but sufficient: this codebase has no raw strings and no
    nested block comments."""
    text = re.sub(r'"""(?:.|\n)*?"""', '""', text)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    text = re.sub(r"/\*(?:.|\n)*?\*/", " ", text)
    text = re.sub(r"//[^\n]*", "", text)
    return text


FILES = {p: open(p, encoding="utf-8").read() for p in swift_files()}
CODE = {p: strip_noise(t) for p, t in FILES.items()}

# --- 1. the schema array -----------------------------------------------------
models = {}
for p, code in CODE.items():
    for m in re.finditer(r"@Model\s+final\s+class\s+(\w+)", code):
        models[m.group(1)] = p
    # catch the attribute and declaration on separate lines too
    for m in re.finditer(r"@Model\s*\n\s*final\s+class\s+(\w+)", code):
        models[m.group(1)] = p

schema_path = os.path.join(SRC, "Models", "Schema", "KitchenAidSchema.swift")
if not os.path.exists(schema_path):
    problems.append("no KitchenAid/Models/Schema/KitchenAidSchema.swift -- "
                    "the 21 @Model classes are registered nowhere")
    listed = set()
else:
    block = CODE[schema_path]
    # Scan only the models ARRAY LITERAL, not the rest of the file. Reading to EOF
    # swept up `KitchenAidSchemaV1.self` from the migration plan's `schemas` and
    # reported the schema as listing a non-model -- a false alarm from this script,
    # which is worse than no script.
    listed = set()
    start = block.find("var models")
    if start >= 0:
        # Skip past the RETURN TYPE's brackets to the body. `var models:
        # [any PersistentModel.Type] {` has a `[` before the `{`, and scanning from
        # the first `[` matched the type annotation -- which holds no `.self` at all,
        # so the script reported all 21 models missing. A false alarm this loud would
        # have had someone "fix" a schema array that was already correct.
        brace = block.find("{", start)
        lb = block.find("[", brace if brace >= 0 else start)
        if lb >= 0:
            depth, i = 0, lb
            while i < len(block):
                if block[i] == "[":
                    depth += 1
                elif block[i] == "]":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            listed = set(re.findall(r"(\w+)\.self", block[lb:i + 1]))

missing = sorted(set(models) - listed)
extra = sorted(listed - set(models))
for name in missing:
    problems.append(f"@Model {name} ({rel(models[name])}) is NOT in the schema array -- "
                    "it will have no table and fail at runtime, not at build")
for name in extra:
    problems.append(f"schema array lists {name}, which is not a @Model in this tree")

# --- 2. balance --------------------------------------------------------------
for p, code in CODE.items():
    for open_ch, close_ch, label in (("{", "}", "braces"),
                                     ("(", ")", "parens"),
                                     ("[", "]", "brackets")):
        a, b = code.count(open_ch), code.count(close_ch)
        if a != b:
            problems.append(f"{rel(p)}: {label} unbalanced -- {a} {open_ch} vs {b} {close_ch}")

# --- 3. CloudKit-readiness ---------------------------------------------------
for p, code in CODE.items():
    if ".unique" in code:
        for i, line in enumerate(FILES[p].splitlines(), 1):
            if ".unique" in line and not line.strip().startswith("//"):
                problems.append(f"{rel(p)}:{i}: @Attribute(.unique) is forbidden "
                                "(CloudKit-backed stores reject it)")
    # a non-optional to-many relationship, which CloudKit also rejects
    for m in re.finditer(r"@Relationship\([^)]*\)\s*var\s+(\w+)\s*:\s*\[(\w+)\](?!\?)", code):
        problems.append(f"{rel(p)}: `{m.group(1)}` is a non-optional to-many "
                        "relationship; it must be optional")

# --- 4. declined features ----------------------------------------------------
# Each of these was offered to Brandon and declined, or cut after review.
DECLINED = {
    "RecipePhoto": "photos were declined",
    "imageData": "photos were declined",
    "CookLogEntry": "a cooking journal was declined; only lastMadeAt is kept",
    "DietaryRestriction": "dietary data was declined",
    "DietaryKeyword": "dietary data was declined",
    "AcknowledgedWarning": "allergy warnings were declined",
    "CountEquivalence": "purchase-unit rounding was cut",
    "purchasePack": "purchase-unit rounding was cut",
    "roundToPurchaseUnits": "purchase-unit rounding was cut",
}
for p, code in CODE.items():
    for sym, why in DECLINED.items():
        if re.search(rf"\b{sym}\b", code):
            problems.append(f"{rel(p)}: `{sym}` is present -- {why}")

# --- 5. types used but declared nowhere --------------------------------------
declared = set()
for code in CODE.values():
    for kw in ("class", "struct", "enum", "protocol", "actor"):
        declared |= set(re.findall(rf"\b{kw}\s+(\w+)", code))
    declared |= set(re.findall(r"\btypealias\s+(\w+)", code))
    # Generic parameter names are not types to look up. Without this, the `Key` in
    # `extension KeyedDecodingContainer` was reported as an undeclared type.
    for params in re.findall(r"(?:func|struct|class|enum|extension)\s+\w+\s*<([^>]+)>", code):
        for part in params.split(","):
            declared.add(part.split(":")[0].strip())
    declared |= set(re.findall(r"\bwhere\s+(\w+)\s*:", code))
    # `extension KeyedDecodingContainer` carries its generic parameter implicitly.
    if "extension KeyedDecodingContainer" in code:
        declared.add("Key")

# Apple and stdlib types this tree legitimately uses. Anything not here and not
# declared is reported, so a genuine omission cannot hide -- the cost is that a
# newly used framework type must be added below.
KNOWN = {
    # stdlib
    "String", "Int", "Int64", "Int32", "UInt", "UInt64", "Double", "Float", "Bool",
    "Array", "Dictionary", "Set", "Optional", "Result", "Error", "Void", "Any",
    "AnyObject", "Character", "Substring", "Range", "ClosedRange", "Sequence",
    "Collection", "Comparable", "Equatable", "Hashable", "Codable", "Decodable",
    "Encodable", "CodingKey", "CodingKeys", "Identifiable", "Sendable",
    "CustomStringConvertible", "CustomDebugStringConvertible", "RawRepresentable",
    "CaseIterable", "Numeric", "SignedInteger", "BinaryInteger", "Never",
    # `Self` is a keyword, not a type anyone declares. It appears capitalized in
    # `Self.helper(...)` -- how an instance method of a final class reaches its own
    # static members -- and ShoppingListStore is the first file here to need it.
    "Self",
    "Decoder", "Encoder", "KeyedDecodingContainer", "KeyedEncodingContainer",
    "DecodingError", "EncodingError", "JSONDecoder", "JSONEncoder",
    # Foundation
    "Date", "DateComponents", "DateInterval", "Calendar", "TimeZone", "UUID",
    "URL", "Data", "Locale", "DateFormatter", "NumberFormatter", "Bundle",
    "FileManager", "CharacterSet", "NSRegularExpression", "Measurement",
    "UserDefaults", "ProcessInfo", "Notification", "TimeInterval",
    "DateFormatStyle", "ISO8601DateFormatter",
    # SwiftData
    "Model", "ModelContext", "ModelContainer", "ModelConfiguration", "Schema",
    "VersionedSchema", "SchemaMigrationPlan", "MigrationStage", "PersistentModel",
    "Query", "Predicate", "FetchDescriptor", "SortDescriptor", "Relationship",
    "Attribute", "PersistentIdentifier",
    # SwiftUI / Observation
    "View", "Text", "Image", "Observable", "State", "Environment", "Binding",
    "EnvironmentKey", "EnvironmentValues",
    "App", "Scene", "WindowGroup", "TabView", "NavigationStack", "NavigationLink",
    "List", "Section", "Label", "Color", "Font", "ViewBuilder", "Picker",
    "VStack", "HStack", "ZStack", "Spacer", "Divider", "Group", "ForEach",
    "ScrollView", "LazyVStack", "Button", "Toggle", "TextField", "Stepper",
    "ShareLink", "ToolbarItem", "ToolbarItemPlacement", "Alignment", "Edge",
    "ImageRenderer", "PDFDocument", "PDFPage", "UIImage", "CGSize", "CGRect",
    "CGFloat", "AnyView", "EmptyView", "Namespace", "FocusState",
    "AppStorage", "SceneStorage", "Query", "ModelActor", "MainActor",
    # The grid the attendance screen lays eaters out in, the idle timer the cook
    # screen disables so the phone does not lock mid-step, and the clock
    # `CookTimerBar` redraws its elapsed time from. `TimelineView` is the one
    # name the constructor scan below found missing from this list, which is
    # what that scan costs: it is only ever constructed, so nothing before it
    # looked.
    "GridItem", "LazyVGrid", "UIApplication", "UIDevice", "TimelineView",
    # CoreGraphics / CoreFoundation, for the PDF writer's CGContext path
    "CGContext", "CGDataConsumer", "CGPoint", "CFURL", "CFData", "CFDictionary",
    "ProposedViewSize", "RoundedRectangle", "Rectangle", "Capsule", "Circle",
    "LocalizedError",
    "DynamicTypeSize", "ColorScheme", "UnsafePointer",
    # The Shop tab and the export control. Added when they were first used rather
    # than when the heuristic first complained: it only looks at a type POSITION,
    # so a view type that is only ever constructed is invisible to it until
    # somebody writes one down as a return type and gets a warning for an Apple
    # type that was there all along.
    "DisclosureGroup", "ProgressView", "Menu", "LabeledContent", "DatePicker",
    "ToolbarContent", "ToolbarContentBuilder",
}

used = set()
for p, code in CODE.items():
    # a capitalized identifier in a type position: after `:` `->` `<` `[` or as
    # the receiver of a static member access
    for m in re.finditer(r"(?::\s*|->\s*|<|\[|\bas\s+|\bis\s+)([A-Z]\w+)", code):
        used.add((m.group(1), p))
    for m in re.finditer(r"\b([A-Z]\w+)\.(?:self|init|shared|current)\b", code):
        used.add((m.group(1), p))
    # ...and a capitalized identifier being CONSTRUCTED. Four view types shipped
    # used-and-declared-nowhere while this script printed PASS, because a
    # SwiftUI view that is only ever built -- `CookTimerBar(step: step)` in
    # Views/Cook/CookView.swift -- sits in no type position whatsoever: not
    # after a `:`, not after a `->`, never with `.self`. Nothing above could
    # reach it, so the one check written to catch exactly this missed all four.
    #
    # Scanning CODE and not FILES is what keeps prose out. Nine capitalized
    # words here live only in comments and strings -- Crostini, Rung, Staples,
    # EDGE, RANGE among them -- and every one would be reported off the raw
    # text. The lookbehind drops `foo.Bar(`, which is a member access and not a
    # type.
    #
    # Still invisible, and worth knowing: a type used ONLY with a trailing
    # closure and no parentheses, `MyWrapper { ... }`, matches nothing here.
    for m in re.finditer(r"(?<![\w.])([A-Z]\w+)\s*\(", code):
        used.add((m.group(1), p))

unknown = {}
for name, p in used:
    if name in declared or name in KNOWN:
        continue
    unknown.setdefault(name, set()).add(rel(p))
# A PROBLEM, not a warning. These were warnings, and the four missing views are
# what that cost: the script listed them and then printed PASS, which is the
# word anybody reads. A name here is one of exactly two things -- a declaration
# this tree does not have, or a framework type missing from KNOWN -- and both
# want doing before a build, so neither is something to note and walk past.
#
# The price is that a newly used Apple type fails this script until it is added
# to KNOWN above. That is a one-line edit, and it is the cheaper half of the
# trade.
for name in sorted(unknown):
    where = ", ".join(sorted(unknown[name]))
    problems.append(f"`{name}` used but declared nowhere in this tree ({where}) -- "
                    "either its declaration is missing, or it is a framework type "
                    "to add to KNOWN in this script")

# --- 6. every key the importer emits is read by the Swift --------------------
# Recipe 02 added nine fields -- ranges, the recipe's own gram equivalents, and
# choice rows -- and the Swift silently dropped all nine on decode. The file was
# right, the app was wrong, and nothing said so. A JSON key the content types
# never mention is the one failure this project cannot see any other way.
import glob

RECIPES = sorted(glob.glob(os.path.join(SRC, "Resources", "Recipes", "*.json")))
if RECIPES:
    import json as _json
    content = "\n".join(t for p, t in FILES.items() if "/Models/Content/" in p)
    buckets = {"recipe": set(), "component": set(), "line": set(), "step": set()}
    for path in RECIPES:
        d = _json.load(open(path, encoding="utf-8"))
        buckets["recipe"] |= set(d)
        for comp in d.get("components", []):
            buckets["component"] |= set(comp)
            for line in comp.get("lines", []):
                buckets["line"] |= set(line)
        for step in d.get("steps", []):
            buckets["step"] |= set(step)
    # Keys the importer emits for its own diagnostics, never for the app.
    # Build provenance, not app data: `warnings` and `overrides` describe how
    # the file was produced. `raw` and `display` are the importer's own
    # renderings, which the Swift reproduces rather than stores.
    # `warnings` is deliberately NOT here. It was, as "build provenance", and
    # that judgement was wrong: a warning about a recipe is the most useful
    # thing the app can tell Brandon after he adds one. Classifying it as
    # provenance is what let it be dropped on decode in the first place.
    IGNORED = {"aggregatesWithinRecipe", "raw", "display", "overrides", "why"}
    for kind, keys in buckets.items():
        for key in sorted(keys - IGNORED):
            if not re.search(rf"\b{re.escape(key)}\b", content):
                problems.append(
                    f"the importer emits {kind} key `{key}` and nothing in "
                    "Models/Content reads it -- it is dropped on decode")

# --- 7. a screen nobody can reach --------------------------------------------
#
# Check 5 answers "does this type exist". This answers the question that cost
# more: CAN HE GET TO IT. Code review 01 found three of its ten blocking defects
# were not broken code at all -- `CookView` and `HouseholdView` were written,
# correct, and constructed from NOWHERE, while this repo's commit messages said
# the tabs were done. A compiler would not have complained either: an
# unreferenced `struct SomeView: View` is perfectly legal Swift.
#
# So: walk the reference graph out from the file holding `@main` and report any
# `View` a walk never reaches.
#
# FILES are the nodes, not types. A namespace `enum` like `PDFExportService`
# builds fifteen page-content views inside its own functions, and attributing
# those construction sites to a declaring *type* leaves every one of them
# looking orphaned. Per file is coarser and right: these files are organised one
# feature per file, and a View sitting in a file the app demonstrably reaches is
# not the failure this is looking for.
#
# An edge is any capitalised identifier followed by `(` or `.` -- construction,
# or a static member on a namespace, which is how `PDFExportService` gets
# reached at all. Deliberately broad. A missed orphan is a shame; a false alarm
# would teach the next reader to ignore this check, and then it is worth
# nothing.
view_decl = re.compile(
    r"^\s*(?:public\s+|private\s+|internal\s+)?struct\s+(\w+)\s*:\s*([^{]*)\{", re.M)
any_decl = re.compile(
    r"^\s*(?:public\s+|private\s+|internal\s+|final\s+)*"
    r"(?:struct|class|enum|actor|protocol)\s+(\w+)", re.M)
reference = re.compile(r"(?<![\w.])([A-Z]\w+)\s*[(.]")

declared_in = {}
views_in = {}
edges = {}
main_file = None
for path, text in FILES.items():
    for m in any_decl.finditer(text):
        declared_in.setdefault(m.group(1), path)
    for m in view_decl.finditer(text):
        # `: View`, `: View, Identifiable`, `: SomeProtocol & View` -- a word
        # boundary, so `ViewModifier` and `ViewBuilder` do not count.
        if re.search(r"\bView\b", m.group(2)):
            views_in[m.group(1)] = path
    edges[path] = {m.group(1) for m in reference.finditer(CODE[path])}
    if "@main" in CODE[path]:
        main_file = path

if main_file is None:
    problems.append("no @main anywhere in the tree -- nothing to walk the view "
                    "graph out from")
else:
    reached = set()
    stack = [main_file]
    while stack:
        here = stack.pop()
        if here in reached:
            continue
        reached.add(here)
        for name in edges.get(here, ()):
            target = declared_in.get(name)
            if target is not None and target not in reached:
                stack.append(target)

    for name in sorted(views_in):
        if views_in[name] not in reached:
            problems.append(
                f"`{name}` ({rel(views_in[name])}) is a View that nothing "
                "reachable from @main ever builds -- it is written, it compiles, "
                "and no tap gets to it")

# --- report ------------------------------------------------------------------
print(f"{len(FILES)} Swift files, "
      f"{sum(len(t.splitlines()) for t in FILES.values())} lines, "
      f"{len(models)} @Model classes, {len(listed)} schema entries")

if problems:
    print(f"\nFAIL  {len(problems)} problem(s):")
    for p in problems:
        print("  x", p)
    sys.exit(1)

print("\nPASS  no structural problems found.")
print("This is NOT a compiler. It cannot see a type error, a bad argument label "
      "or a protocol\nconformance that is not satisfied. Build on a Mac.")
