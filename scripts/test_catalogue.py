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
    for key in ("name", "aisle", "dimension", "unit", "staple", "aliases"):
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
