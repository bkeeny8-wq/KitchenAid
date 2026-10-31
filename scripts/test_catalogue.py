#!/usr/bin/env python3
"""Checks on the shipped ingredient catalogue.

    python3 -I scripts/test_catalogue.py

The load-bearing test is the last one: every ingredient in the first real
recipe must resolve to a catalogue entry. The catalogue exists so that adding
things is picking rather than typing, and a catalogue that misses ingredients
from the very first recipe would not deliver that.
"""

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CATALOGUE = os.path.join(ROOT, "KitchenAid", "Resources", "ingredients.json")

# Rebuild first so the test can never pass against a stale file.
subprocess.run([sys.executable, "-I", os.path.join(HERE, "build_catalogue.py")],
               capture_output=True, text=True, check=True)

data = json.load(open(CATALOGUE, encoding="utf-8"))
items = data["items"]

failures = []


def check(label, got, want):
    if got != want:
        failures.append(f"{label}\n      got:  {got!r}\n      want: {want!r}")


def fail(label):
    failures.append(label)


# --- shape ---
check("version", data["version"], 1)
if len(items) < 300:
    fail(f"catalogue is too thin to spare Brandon the typing: {len(items)} items")

VALID_DIMS = {"mass", "volume", "count"}
VALID_AISLES = {
    "Produce", "Butcher", "Seafood", "Dairy", "Bakery", "Dry goods", "Canned",
    "Condiments", "Spices", "Baking", "Nuts", "Frozen", "Beverages",
}

for i in items:
    for key in ("name", "aisle", "dimension", "unit", "bakingUnit",
                "gramsPerCup", "staple", "aliases"):
        if key not in i:
            fail(f'{i.get("name", "?")} is missing "{key}"')
    if i["dimension"] not in VALID_DIMS:
        fail(f'{i["name"]}: dimension {i["dimension"]!r} is not one of {sorted(VALID_DIMS)}')
    if i["aisle"] not in VALID_AISLES:
        fail(f'{i["name"]}: aisle {i["aisle"]!r} is not a known store section')
    if i["name"] != i["name"].strip() or not i["name"]:
        fail(f'bad name {i["name"]!r}')

# --- no ambiguous lookups ---
# A name or alias that resolves to two different purchases makes the pantry
# match whichever happens to come first, silently.
index = {}
for i in items:
    for key in [i["name"]] + i["aliases"]:
        k = key.lower()
        if k in index and index[k] != i["name"]:
            fail(f'"{key}" resolves to both {index[k]!r} and {i["name"]!r}')
        index[k] = i["name"]

# "coriander" must be the SEED, not an alias of cilantro -- British and
# American usage disagree, so the ambiguous word maps to exactly one thing.
check("coriander resolves to the spice", index.get("coriander"), "coriander")
check("fresh coriander resolves to the herb", index.get("fresh coriander"), "cilantro")
by_name = {i["name"]: i for i in items}
check("coriander is in Spices", by_name["coriander"]["aisle"], "Spices")
check("cilantro is in Produce", by_name["cilantro"]["aisle"], "Produce")

# --- staples are presence-only, and the right things are staples ---
for name in ("kosher salt", "black pepper", "olive oil", "flaky salt"):
    if not by_name[name]["staple"]:
        fail(f"{name} should be a staple -- a list that keeps asking for it stops being read")
for name in ("ny strip steak", "baby spinach", "cream cheese", "baguette"):
    if by_name[name]["staple"]:
        fail(f"{name} must NOT be a staple; you genuinely run out of it")

# --- dimensions that the shopping list depends on ---
check("steak is weighed", by_name["ny strip steak"]["dimension"], "mass")
check("butter defaults to volume, as recipes write it", by_name["butter"]["dimension"], "volume")
check("butter's default unit", by_name["butter"]["unit"], "tbsp")
check("garlic is counted in cloves", by_name["garlic"]["unit"], "clove")
check("baguette is counted, not sliced", by_name["baguette"]["dimension"], "count")

# --- scallion / green onion is one purchase ---
check("green onion is the same row as scallion", index.get("green onion"), "scallion")
check("spring onion too", index.get("spring onion"), "scallion")

# --- cooking units vs baking units ---
# "its not uniform across application between cooking and baking" -- a quarter
# cup of milk is how you cook; 300 g of bread flour is how you bake.
check("milk is cups when cooking", by_name["milk"]["unit"], "cup")
check("milk is ml when baking", by_name["milk"]["bakingUnit"], "ml")
check("bread flour is cups when cooking", by_name["bread flour"]["unit"], "cup")
check("bread flour is grams when baking", by_name["bread flour"]["bakingUnit"], "g")
check("butter is grams when baking", by_name["butter"]["bakingUnit"], "g")
check("sugar is grams when baking", by_name["granulated sugar"]["bakingUnit"], "g")
# Things that have no business having a baking unit
for name in ("ny strip steak", "baby spinach", "shallot", "prepared horseradish"):
    if by_name[name]["bakingUnit"] is not None:
        fail(f'{name} has a bakingUnit, which makes no sense for it')
# Leaveners stay in spoons even when baking: 5 g of baking powder is not how
# anyone writes a recipe.
for name in ("baking powder", "baking soda", "vanilla extract"):
    if by_name[name]["bakingUnit"] is not None:
        fail(f"{name} should stay in spoons when baking")

# --- densities, and the invariant that makes them usable ---
check("all-purpose flour density", by_name["all-purpose flour"]["gramsPerCup"], 120)
check("butter density (1 cup = 2 sticks)", by_name["butter"]["gramsPerCup"], 227)
check("granulated sugar density", by_name["granulated sugar"]["gramsPerCup"], 200)
check("honey is heavier than water", by_name["honey"]["gramsPerCup"] > 237, True)

# Kosher salt is deliberately absent: Diamond Crystal is ~142 g/cup and Morton
# ~288, a factor of two from the same words on the box.
check("kosher salt has NO density", by_name["kosher salt"]["gramsPerCup"], None)

# If an ingredient bakes in grams, it MUST have a density, or the app cannot
# turn a cup measurement into that unit and the baking unit is useless.
for i in items:
    if i["bakingUnit"] == "g" and i["gramsPerCup"] is None:
        fail(f'{i["name"]} bakes in grams but has no density, so it cannot convert')

# --- water must never reach a shopping list ---
check("water is in the catalogue", "water" in by_name, True)
check("water is a staple, so it is never shopped for", by_name["water"]["staple"], True)

# --- spices that are purchases, not cupboard staples ---
for name in ("saffron", "ancho chile", "star anise"):
    if by_name[name]["staple"]:
        fail(f"{name} is bought deliberately for a dish; it should not be a staple")
for name in ("cumin", "paprika", "garlic powder", "dried oregano"):
    if not by_name[name]["staple"]:
        fail(f"{name} lives in the cupboard and should be a staple")

# --- THE ONE THAT MATTERS: the first real recipe must be fully covered ---
FIXTURE_INGREDIENTS = [
    "baguette", "olive oil", "NY strip steak", "kosher salt", "black pepper",
    "butter", "garlic", "baby spinach", "shallot", "cream cheese",
    "heavy cream", "prepared horseradish", "Parmesan", "lemon juice",
    "fresh chives", "flaky salt",
]
missing = [n for n in FIXTURE_INGREDIENTS if n.lower() not in index]
if missing:
    fail("the first real recipe has ingredients the catalogue does not know: "
         + ", ".join(missing))

# and each must land in a sensible aisle, since that is what orders the list
EXPECTED_AISLE = {
    "NY strip steak": "Butcher", "baguette": "Bakery", "baby spinach": "Produce",
    "shallot": "Produce", "garlic": "Produce", "fresh chives": "Produce",
    "butter": "Dairy", "cream cheese": "Dairy", "heavy cream": "Dairy",
    "Parmesan": "Dairy", "olive oil": "Condiments",
    "prepared horseradish": "Condiments", "kosher salt": "Spices",
    "flaky salt": "Spices", "black pepper": "Spices", "lemon juice": "Beverages",
}
for name, aisle in EXPECTED_AISLE.items():
    canonical = index.get(name.lower())
    if canonical and by_name[canonical]["aisle"] != aisle:
        fail(f'{name} -> {canonical} is in {by_name[canonical]["aisle"]}, expected {aisle}')

if failures:
    print(f"FAIL  {len(failures)} problem(s):\n")
    for f in failures:
        print(f"  ✗ {f}\n")
    sys.exit(1)

staples = sum(1 for i in items if i["staple"])
print(f"PASS  {len(items)} ingredients, {staples} staples, "
      f"{len(index) - len(items)} aliases, "
      f"{len(VALID_AISLES)} aisles; all {len(FIXTURE_INGREDIENTS)} "
      f"ingredients of recipe 01 resolve")
