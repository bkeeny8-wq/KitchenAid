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
doc = json.loads(out.stdout)

# The importer emits a DOCUMENT envelope now, because recipe 02 is four recipes
# in one PDF. A single-recipe document still comes back as one entry.
assert doc["schemaVersion"] == 1, doc.get("schemaVersion")
assert len(doc["recipes"]) == 1, f'recipe 01 is one recipe, got {len(doc["recipes"])}'
d = doc["recipes"][0]

failures = []


def check(label, got, want):
    if got != want:
        failures.append(f"{label}\n      got:  {got!r}\n      want: {want!r}")


def fail(label):
    failures.append(label)


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


# =============================================================================
# Recipe 02 — docs/fixture-recipe-02.txt
#
# Four recipes in ONE document: a pancake batter and three compotes, one per
# page. Parsed by the recipe-01 rules it produced a single recipe with one
# component, sixteen merged steps and a total time of three minutes lifted from
# "about 3 minutes" in a whipping instruction — and reported NO warnings while
# doing it. The silence was the worst part; everything below exists so that
# shape of failure is loud next time.
# =============================================================================

FIXTURE2 = os.path.join(ROOT, "docs", "fixture-recipe-02.txt")
out2 = subprocess.run(
    [sys.executable, "-I", os.path.join(HERE, "import_recipe.py"), FIXTURE2],
    capture_output=True, text=True, check=True,
)
doc2 = json.loads(out2.stdout)


def line2(recipe, ingredient_name):
    for c in recipe["components"]:
        for l in c["lines"]:
            if l["name"] == ingredient_name:
                return l
    return None


# R14 -- one document, four recipes, split on the page footer
check("R14 four recipes", len(doc2["recipes"]), 4)
check("R14 document title", doc2["documentTitle"],
      "Fluffy Whipped Egg White Pancakes and Compotes")
check("R14 titles in order",
      [r["title"] for r in doc2["recipes"]],
      ["Fluffy Whipped Egg White Pancakes", "Blueberry Compote",
       "Mixed Berry Compote", "Apple Compote"])
check("R14 each gets its own id",
      len({r["id"] for r in doc2["recipes"]}), 4)

pancake, blueberry, mixed, apple = doc2["recipes"]

# R15 -- steps belong to their own recipe, not to the first one
check("R15 pancake steps", len(pancake["steps"]), 7)
check("R15 blueberry steps", len(blueberry["steps"]), 3)
check("R15 apple steps", len(apple["steps"]), 3)

# R16 -- a yield written into the description, not tabulated
check("R16 yieldAmount", pancake["yieldAmount"], 8)
check("R16 yieldUnitLabel", pancake["yieldUnitLabel"], "pancakes")
check("R16 servings", pancake["servings"], 4)

# R17 -- times are read from the header ONLY
# "about 3 minutes" appears in step 3 and must not become the recipe's time.
check("R17 no false total time", pancake["totalMinutes"], None)
check("R17 no false active time", pancake["activeMinutes"], None)
check("R17 and it SAYS so", "no active or total time found" in pancake["warnings"], True)

# R18 -- ingredient groups with no "Ingredients" header at all
check("R18 pancake groups",
      [c["name"] for c in pancake["components"]],
      ["Pancake Batter", "Spice Mix-Ins (add to the dry ingredients)"])
check("R18 the Makes/serves row is not an ingredient",
      any("Makes" in (l["raw"] or "") for c in pancake["components"] for l in c["lines"]),
      False)

# R19 -- an ALTERNATIVES group, where the first column names a choice and the
# amount is in the second. Forced into the ingredient shape this produced an
# ingredient called "Cinnamon" with no quantity.
spices = pancake["components"][1]["lines"]
check("R19 three options", len(spices), 3)
check("R19 all marked as options", all(l["isOption"] for l in spices), True)
check("R19 option labels", [l["name"] for l in spices], ["Cinnamon", "Nutmeg", "Both"])
check("R19 the amount is kept as the option's text",
      spices[0]["optionText"], "1/2 tsp, good with the apple compote")
check("R19 an option has no quantity", spices[0]["hasQuantity"], False)

# R20 -- quantity RANGES. Read as one number this became quantity 2 with the
# unit "to 3 tbsp".
syrup = line2(blueberry, "maple syrup")
check("R20 is a range", syrup["isRange"], True)
check("R20 low", (syrup["amountNumerator"], syrup["amountDenominator"]), (2, 1))
check("R20 high", (syrup["amountMaxNumerator"], syrup["amountMaxDenominator"]), (3, 1))
check("R20 unit", syrup["unit"], "tbsp")
check("R20 display keeps both", syrup["display"], "2 to 3")

# R21 -- the recipe's OWN second measurement, which is the volume-and-weight
# pair Brandon asked for, handed over by the document itself.
flour = line2(pancake, "all-purpose flour")
check("R21 flour volume", (flour["amountNumerator"], flour["amountDenominator"]), (3, 2))
check("R21 flour volume unit", flour["unit"], "cup")
check("R21 flour weight too", flour["hasAltAmount"], True)
check("R21 flour grams", flour["altAmountNumerator"], 190)
check("R21 flour alt unit", flour["altUnit"], "g")
check("R21 and the prep survived", flour["preparation"], "spooned and leveled, not scooped")
check("R21 berries grams", line2(blueberry, "blueberries")["altAmountNumerator"], 300)
# "about 1 lb or 450g" offers two; the metric one is taken.
check("R21 apples take the metric of two", line2(apple, "apples")["altAmountNumerator"], 450)
check("R21 apples alt unit", line2(apple, "apples")["altUnit"], "g")

# R22 -- a parenthetical with no number is commentary and belongs in prep.
# Left in the name, "baking powder (do not skip)" matches no catalogue entry,
# and "cream of tartar (optional, helps the whites hold)" was cut at the comma
# INSIDE the brackets, producing an ingredient called "cream of tartar (optional".
check("R22 baking powder name", line2(pancake, "baking powder") is not None, True)
check("R22 baking powder prep", line2(pancake, "baking powder")["preparation"], "do not skip")
check("R22 cream of tartar name", line2(pancake, "cream of tartar") is not None, True)
check("R22 cream of tartar prep",
      line2(pancake, "cream of tartar")["preparation"], "optional, helps the whites hold")

# R23 -- a clause after a COLON, not a comma
berries = line2(mixed, "mixed berries")
check("R23 name stops at the colon", berries is not None, True)
check("R23 the clause became prep",
      berries["preparation"].startswith("any mix of strawberries"), True)

# R24 -- a size word is not a unit: "3 medium apples" stays countable apples
apples = line2(apple, "apples")
check("R24 dimension", apples["dimension"], "count")
check("R24 no bogus unit", apples["unit"], None)
check("R24 size kept as prep", apples["preparation"].startswith("medium"), True)

# R25 -- an either/or with no comma: "1/4 cup water or apple cider"
water = line2(apple, "water")
check("R25 name is the first option", water is not None, True)
check("R25 alternative kept", water["preparation"], "or apple cider")

# R26 -- "1 pinch" is a counted pinch, distinct from recipe 01's bare "Pinch"
pinch = line2(blueberry, "kosher salt")
check("R26 has a number", pinch["hasQuantity"], True)
check("R26 unit is the pinch", pinch["unit"], "pinch")

# R27 -- notes are LABELLED paragraphs here, not bullets
check("R27 pancake note count", len(pancake["notes"]), 1)
check("R27 the fluff checklist survived",
      pancake["notes"][0].startswith("Fluff checklist:"), True)
check("R27 and it is whole",
      pancake["notes"][0].rstrip().endswith("after flipping."), True)
check("R27 each compote keeps its tip", len(blueberry["notes"]), 1)
check("R27 tip text", blueberry["notes"][0].startswith("Tip: mash a few berries"), True)
# The labelled paragraph must NOT be swallowed into the final step.
check("R27 the tip is not inside the last step",
      "Tip:" in blueberry["steps"][-1]["body"], False)

# R28 -- what the document genuinely does not say is REPORTED, not guessed
# The serving count the DOCUMENT gives is still nothing -- R29 covers the
# override that supplies one, and that it is marked as not coming from the page.
for compote in (blueberry, mixed, apple):
    t = compote["title"]
    if "no yield found (how much it makes)" not in compote["warnings"]:
        fail(f"R28 {t} has no yield and does not say so")
    if "no active or total time found" not in compote["warnings"]:
        fail(f"R28 {t} has no times and does not say so")
check("R28 the pancake has no unread-quantity warnings",
      [w for w in pancake["warnings"] if "could not read a quantity" in w], [])

if failures:
    print(f"FAIL  {len(failures)} assertion(s):\n")
    for f in failures:
        print(f"  ✗ {f}\n")
    sys.exit(1)

print(f"PASS  recipe 02: {len(doc2['recipes'])} recipes from one document, "
      f"{sum(len(c['lines']) for r in doc2['recipes'] for c in r['components'])} lines, "
      f"{sum(len(r['steps']) for r in doc2['recipes'])} steps, "
      f"{sum(len(r['warnings']) for r in doc2['recipes'])} honest warnings")


# =============================================================================
# Recipes 03 and 04 — the roast turkey and its gravy
#
# A third document shape. These invert the column order: the ingredient is in
# the FIRST column and the amount in the second, which is the opposite of
# recipes 01 and 02. Parsed by the old rules the turkey produced TWO recipes
# (the second called "Instructions", because a page break was treated as a
# recipe break), fourteen ingredient groups (because every prose paragraph
# became a heading), an "option" row for every single ingredient, and it LOST
# both of the all-caps lines the whole recipe depends on.
# =============================================================================

TURKEY_SRC = os.path.join(ROOT, "docs", "fixture-recipe-03-turkey.txt")
GRAVY_SRC = os.path.join(ROOT, "docs", "fixture-recipe-04-gravy.txt")


def load(path):
    r = subprocess.run(
        [sys.executable, "-I", os.path.join(HERE, "import_recipe.py"), path],
        capture_output=True, text=True, check=True,
    )
    return json.loads(r.stdout)


turkey_doc = load(TURKEY_SRC)
gravy_doc = load(GRAVY_SRC)

# R30 -- a page break is NOT a recipe break
check("R30 the turkey is ONE recipe", len(turkey_doc["recipes"]), 1)
turkey = turkey_doc["recipes"][0]
check("R30 title", turkey["title"], "Roast Turkey")
# Its method is on page 2. Splitting on the footer left the turkey with none.
check("R30 all ten steps survived the page break", len(turkey["steps"]), 10)
check("R30 and the compotes are still four",
      len(load(os.path.join(ROOT, "docs", "fixture-recipe-02.txt"))["recipes"]), 4)

# R31 -- the ingredient is in the FIRST column here, the amount in the second
shopping = turkey["components"][0]["lines"]
butter = next(l for l in shopping if l["name"] == "Butter")
check("R31 butter amount", (butter["amountNumerator"], butter["amountDenominator"]), (2, 1))
check("R31 butter unit", butter["unit"], "stick")
check("R31 and the rest of the cell became prep", butter["preparation"], "UNSALTED")
check("R31 nothing here is a choice row",
      any(l["isOption"] for c in turkey["components"] for l in c["lines"]), False)
# The pancake's alternatives group must STILL be read as alternatives, which is
# the case this orientation detection could most easily have broken.
pancake2 = load(os.path.join(ROOT, "docs", "fixture-recipe-02.txt"))["recipes"][0]
check("R31 the spice mix-ins are still choices",
      all(l["isOption"] for l in pancake2["components"][1]["lines"]), True)

# R32 -- a unit two words into the amount cell: "1 whole head, cut in half"
garlic = next(l for c in turkey["components"] for l in c["lines"] if l["name"] == "Garlic")
check("R32 garlic unit", garlic["unit"], "head")
check("R32 garlic prep", garlic["preparation"], "cut in half")
celery = next(l for c in turkey["components"] for l in c["lines"] if l["name"] == "Celery")
check("R32 celery unit", celery["unit"], "stalk")

# R33 -- prose is prose, not a heading
check("R33 four groups, not fourteen", len(turkey["components"]), 4)
check("R33 group names",
      [c["name"] for c in turkey["components"]],
      [None, "Bed of Vegetables", "Butter Mixture", "In the Cavity"])
bed = turkey["components"][1]
check("R33 the paragraph became the group's prose",
      bed.get("description", "").startswith("The bottom of the roasting pan"), True)
check("R33 and the group kept its rows", len(bed["lines"]), 5)
# Two groups are prose only and have no rows at all.
check("R33 Butter Mixture is prose with no rows", len(turkey["components"][2]["lines"]), 0)
check("R33 and it has prose",
      turkey["components"][2].get("description", "").startswith("1.5 to 2 sticks"), True)

# R34 -- THE ALL-CAPS LINES. These were lost entirely, not mangled.
# The turkey, its butter and its gravy are all deliberately unsalted so the
# cook salts once at the end; losing these loses the recipe's whole point.
check("R34 DO. NOT. SALT. survived", "DO. NOT. SALT." in turkey["notes"], True)
check("R34 and the butter warning", "DO NOT USE SALTED BUTTER." in turkey["notes"], True)

# R35 -- timing by weight, not by the clock
check("R35 minutes per pound", turkey["minutesPerPound"], 13)
check("R35 oven temperature", turkey["ovenTempF"], 350)
check("R35 no fixed total time", turkey["totalMinutes"], None)
# A rate IS the timing, so warning about a missing duration would be noise.
check("R35 and it does not warn about the missing duration",
      "no active or total time found" in turkey["warnings"], False)

# R36 -- a printed lookup table stays a table
check("R36 one table", len(turkey["tables"]), 1)
times = turkey["tables"][0]
check("R36 name", times["name"], "Cooking Times")
check("R36 headers", times["headers"],
      ["Turkey weight", "Total time", "Covered (first 2/3)", "Uncovered (last 1/3)"])
check("R36 eight weights", len(times["rows"]), 8)
check("R36 first row", times["rows"][0], ["10 lb", "2 hr 10 min", "1 hr 27 min", "43 min"])
check("R36 last row", times["rows"][-1], ["24 lb", "5 hr 12 min", "3 hr 28 min", "1 hr 44 min"])
# And it is no longer inside the final step's body.
check("R36 the table left the last step alone",
      "10 lb" in turkey["steps"][-1]["body"], False)

# R37 -- the gravy
check("R37 one recipe", len(gravy_doc["recipes"]), 1)
gravy = gravy_doc["recipes"][0]
check("R37 title", gravy["title"], "Turkey Gravy")
check("R37 nine steps", len(gravy["steps"]), 9)
# "Makes about 4 cups" -- a yield with no serving count at all.
check("R37 yield amount", gravy["yieldAmount"], 4)
check("R37 yield unit", gravy["yieldUnitLabel"], "cups")

glines = {l["name"]: l for c in gravy["components"] for l in c["lines"]}
check("R37 flour is a quarter cup",
      (glines["Flour"]["amountNumerator"], glines["Flour"]["amountDenominator"]), (1, 4))
check("R37 flour unit", glines["Flour"]["unit"], "cup")
check("R37 stock is four cups", glines["Stock"]["amountNumerator"], 4)
# An ingredient whose amount is a sentence, because that IS the amount.
check("R37 the pan base has no number", glines["Pan base"]["hasQuantity"], False)
check("R37 and its amount is kept as written",
      glines["Pan base"]["qualifier"].startswith("all the roasted vegetables"), True)
# A wrapped amount cell: "...topped up with / UNSALTED butter if short".
check("R37 the wrapped amount rejoined",
      "UNSALTED butter if short" in (glines["Fat"]["preparation"] or ""), True)
check("R37 and it did not become an ingredient", "UNSALTED butter if short" in glines, False)

# R38 -- a recognised wording is not warned about, an unknown one is
check("R38 'lots' is flagged for his eye",
      any("'Pepper'" in w and "lots" in w for w in turkey["warnings"]), True)
# "Pinch" in recipe 01 is understood and carried deliberately, so it is silent.
check("R38 but recipe 01's Pinch is not flagged",
      [w for w in d["warnings"] if "worded amount" in w], [])

if failures:
    print(f"FAIL  {len(failures)} assertion(s):\n")
    for f in failures:
        print(f"  ✗ {f}\n")
    sys.exit(1)

print(f"PASS  recipes 03-04: turkey is 1 recipe over 2 pages with "
      f"{len(turkey['components'])} groups, {len(turkey['steps'])} steps, "
      f"a {len(times['rows'])}-row table and {len(turkey['notes'])} notes; "
      f"gravy makes {gravy['yieldAmount']} {gravy['yieldUnitLabel']}")
