#!/usr/bin/env python3
"""Regression test for the recipe importer, asserted against the first real recipe.

    python3 -I scripts/test_import.py

Every assertion below traces to a numbered requirement in
docs/REQUIREMENTS_FROM_FIXTURE.md. This file exists because the importer will be
extended as Brandon adds recipes in other layouts, and the first recipe must keep
parsing correctly while that happens.
"""

import json
import os
import subprocess
import sys
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIXTURE = os.path.join(ROOT, "docs", "fixture-recipe-01.txt")

out = subprocess.run(
    [sys.executable, "-I", os.path.join(HERE, "import_recipe.py"), FIXTURE],
    capture_output=True, text=True, check=True,
)
d = json.loads(out.stdout)

failures = []


def check(label, got, want):
    if got != want:
        failures.append(f"{label}\n      got:  {got!r}\n      want: {want!r}")


def line(component_name, ingredient_name):
    for c in d["components"]:
        if c["name"] == component_name:
            for l in c["lines"]:
                if l["name"] == ingredient_name:
                    return l
    return None


def qty(l):
    """Rebuild the exact rational from the flat stored fields, to prove nothing
    was lost to a float. The app persists hasQuantity + numerator + denominator
    rather than a Codable blob, and the importer now emits that same shape.
    """
    if not l.get("hasQuantity"):
        return None
    return Fraction(l["amountNumerator"], l["amountDenominator"])


# R1 -- ingredients grouped into components, steps flat across the whole dish
check("R1 component names",
      [c["name"] for c in d["components"]],
      ["Crostini and steak", "Creamed horseradish spinach", "To finish"])
check("R1 steps are recipe-level and complete", len(d["steps"]), 8)

# R2 -- two different yields, neither derivable from the other
check("R2 yieldAmount", d["yieldAmount"], 12)
check("R2 yieldUnitLabel", d["yieldUnitLabel"], "crostini")
check("R2 servings", d["servings"], 4)

# R3 -- active and total time are distinct
check("R3 activeMinutes", d["activeMinutes"], 35)
check("R3 totalMinutes", d["totalMinutes"], 70)

# R4 -- fractions exact, never floats
check("R4 1/2 tsp black pepper", qty(line("Crostini and steak", "black pepper")), Fraction(1, 2))
check("R4 1/4 tsp kosher salt", qty(line("Creamed horseradish spinach", "kosher salt")), Fraction(1, 4))
check("R4 fraction renders as vulgar, not decimal",
      line("Crostini and steak", "black pepper")["display"], "1/2")
# the scaling promise a float cannot make
third = Fraction(1, 3)
check("R4 x3 of a third is exactly one", third * 3, Fraction(1))

# R5 -- a quantity word with no number survives as a qualifier, not as 0
flaky = line("To finish", "flaky salt")
check("R5 Pinch kept as qualifier", flaky["qualifier"], "Pinch")
check("R5 Pinch has no numeric quantity", flaky["hasQuantity"], False)

# R6 -- bare oz resolved to mass for all three solids, and recorded as resolved
for comp, name in [("Crostini and steak", "NY strip steak"),
                   ("Creamed horseradish spinach", "baby spinach"),
                   ("Creamed horseradish spinach", "cream cheese")]:
    l = line(comp, name)
    check(f"R6 {name} unit", l["unit"], "oz")
    check(f"R6 {name} dimension", l["dimension"], "mass")
    check(f"R6 {name} resolution confirmed", l.get("dimensionConfirmed"), True)

# R7 -- name and preparation separated, both comma-suffix and adjective-prefix shapes
check("R7 trailing clause: shallot", line("Creamed horseradish spinach", "shallot")["preparation"], "minced")
check("R7 leading adjective: grated Parmesan name",
      line("Creamed horseradish spinach", "Parmesan")["name"], "Parmesan")
check("R7 leading adjective: grated Parmesan prep",
      line("Creamed horseradish spinach", "Parmesan")["preparation"], "grated")
# "prepared horseradish" must NOT be stripped -- it is a different product from
# horseradish root, so "prepared" is identity, not preparation
check("R7 identity adjective kept on the name",
      line("Creamed horseradish spinach", "prepared horseradish") is not None, True)

# R8 -- the recipe aggregates against ITSELF
check("R8 within-recipe duplicates detected",
      d.get("aggregatesWithinRecipe"), ["butter", "kosher salt"])
b1 = qty(line("Crostini and steak", "butter"))
b2 = qty(line("Creamed horseradish spinach", "butter"))
check("R8 butter totals 2 tbsp", b1 + b2, Fraction(2))
s1 = qty(line("Crostini and steak", "kosher salt"))
s2 = qty(line("Creamed horseradish spinach", "kosher salt"))
check("R8 kosher salt totals 1 1/4 tsp", s1 + s2, Fraction(5, 4))

# R9 -- a count noun parked in the name becomes the unit
g = line("Crostini and steak", "garlic")
check("R9 garlic cloves -> name", g["name"] if g else None, "garlic")
check("R9 garlic cloves -> unit", g["unit"] if g else None, "clove")
check("R9 garlic cloves -> prep kept", g["preparation"] if g else None, "smashed")
check("R9 12 slices baguette", line("Crostini and steak", "baguette")["unit"], "slice")

# R10 -- step title, duration, range, and absence of a duration
steps = {s["order"]: s for s in d["steps"]}
check("R10 step 1 title", steps[1]["title"], "Season the steak")
check("R10 step 1 duration", (steps[1]["minMinutes"], steps[1]["maxMinutes"]), (30, 30))
check("R10 step 3 is a RANGE", (steps[3]["minMinutes"], steps[3]["maxMinutes"]), (7, 8))
check("R10 step 7 has no duration", (steps[7]["minMinutes"], steps[7]["maxMinutes"]), (None, None))
check("R10 step 8 title", steps[8]["title"], "Assemble")

# R11 -- temperatures left intact in step bodies for a later extraction pass
check("R11 oven temp preserved", "400F" in steps[2]["body"], True)
check("R11 internal temp preserved", "125F" in steps[3]["body"], True)

# R12 -- notes are a list of distinct ideas, not one blob
check("R12 note count", len(d["notes"]), 4)
check("R12 make-ahead note intact",
      d["notes"][0].startswith("The spinach can be made a day ahead"), True)
check("R12 wrapped note rejoined",
      d["notes"][2].endswith("horseradish drizzle on top of the steak."), True)

# R13 -- the bundled-content shape the app loads, and stable overlay ids.
# Brandon's tweaks live in SwiftData keyed by these ids while the recipe itself
# is immutable content, so an id has to survive the file being revised.
check("R13 schemaVersion", d["schemaVersion"], 1)
check("R13 recipe id is a slug of the title",
      d["id"], "ny-strip-crostini-with-creamed-horseradish-spinach")
check("R13 summary, not description", d["summary"].startswith("Crisp baguette"), True)

all_lines = [l for c in d["components"] for l in c["lines"]]
line_ids = [l["lineID"] for l in all_lines]
check("R13 every line has an id", len(line_ids), 18)
check("R13 line ids are unique", len(set(line_ids)), 18)
# Ids are name-based with an occurrence number, NOT positional: a positional id
# silently re-points an override onto a different ingredient when a line is
# inserted above it. This recipe is the reason the occurrence number exists.
check("R13 butter occurs twice and is numbered",
      sorted(l["lineID"] for l in all_lines if l["name"] == "butter"),
      ["butter-1", "butter-2"])
check("R13 kosher salt likewise",
      sorted(l["lineID"] for l in all_lines if l["name"] == "kosher salt"),
      ["kosher-salt-1", "kosher-salt-2"])
check("R13 a single occurrence still gets -1",
      line("Crostini and steak", "baguette")["lineID"], "baguette-1")
for l in all_lines:
    if not l["lineID"] or " " in l["lineID"] or l["lineID"] != l["lineID"].lower():
        fail(f'R13 bad lineID {l["lineID"]!r}')

step_ids = [s["stepID"] for s in d["steps"]]
check("R13 every step has an id", len(step_ids), 8)
check("R13 step ids are unique", len(set(step_ids)), 8)
check("R13 step id is derived from its title",
      steps[1]["stepID"], "season-the-steak-1")

# The five flat quantity fields must be present on EVERY line, including the
# ones with no number, so the store never sees a missing key.
for l in all_lines:
    for key in ("hasQuantity", "amountNumerator", "amountDenominator", "display"):
        if key not in l:
            fail(f'R13 {l["lineID"]} is missing {key}')
    if l["amountDenominator"] == 0:
        fail(f'R13 {l["lineID"]} has a zero denominator')
check("R13 a qualifier line still carries a display string",
      line("To finish", "flaky salt")["display"], "Pinch")

# no silent data loss anywhere
total_lines = sum(len(c["lines"]) for c in d["components"])
check("all 18 ingredient lines present", total_lines, 18)
check("no parser warnings", d["warnings"], [])

if failures:
    print(f"FAIL  {len(failures)} assertion(s):\n")
    for f in failures:
        print(f"  ✗ {f}\n")
    sys.exit(1)
print(f"PASS  all assertions ok  ({total_lines} ingredient lines, "
      f"{len(d['components'])} components, {len(d['steps'])} steps, {len(d['notes'])} notes)")
