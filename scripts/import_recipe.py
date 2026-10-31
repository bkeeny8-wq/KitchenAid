#!/usr/bin/env python3
"""Parse a recipe laid out like Brandon's ReportLab PDFs into neutral JSON.

Run it on the text that `pdftotext -layout` produces, not on the PDF:

    pdftotext -layout recipe.pdf - | python3 -I scripts/import_recipe.py -

Why text and not the PDF: -layout preserves the column gutters, and the gutters
are the only reliable signal separating the quantity column from the ingredient
column. "2  garlic cloves, smashed" has no unit at all, so splitting on
whitespace-runs beats any regex that assumes qty/unit/name are all present.

Quantities come out as exact rationals. A recipe scaled x3 must turn 1/3 cup
back into exactly 1 cup, and floats cannot promise that -- 0.3333333 * 3 is
0.9999999, which formats as "1 cup" only by luck and rounds wrong at other
multiples.
"""

import json
import re
import sys
from fractions import Fraction

# --- units -------------------------------------------------------------------
# dimension matters because it decides what can be ADDED. tbsp + cup is legal
# (both volume); cup + gram is not, without a per-ingredient density this app
# does not have.
UNITS = {
    "tsp": ("tsp", "volume"), "teaspoon": ("tsp", "volume"), "teaspoons": ("tsp", "volume"),
    "tbsp": ("tbsp", "volume"), "tablespoon": ("tbsp", "volume"), "tablespoons": ("tbsp", "volume"),
    "cup": ("cup", "volume"), "cups": ("cup", "volume"),
    "ml": ("ml", "volume"), "l": ("l", "volume"), "liter": ("l", "volume"), "liters": ("l", "volume"),
    "qt": ("qt", "volume"), "quart": ("qt", "volume"), "pt": ("pt", "volume"), "pint": ("pt", "volume"),
    "floz": ("floz", "volume"),
    "g": ("g", "mass"), "gram": ("g", "mass"), "grams": ("g", "mass"),
    "kg": ("kg", "mass"), "lb": ("lb", "mass"), "lbs": ("lb", "mass"), "pound": ("lb", "mass"),
    "pounds": ("lb", "mass"),
    "oz": ("oz", "mass"),  # see resolve_oz below -- recipes mean weight far more often
    "ounce": ("oz", "mass"), "ounces": ("oz", "mass"),
    "slice": ("slice", "count"), "slices": ("slice", "count"),
    "clove": ("clove", "count"), "cloves": ("clove", "count"),
    "sprig": ("sprig", "count"), "sprigs": ("sprig", "count"),
    "bunch": ("bunch", "count"), "bunches": ("bunch", "count"),
    "head": ("head", "count"), "heads": ("head", "count"),
    "stalk": ("stalk", "count"), "stalks": ("stalk", "count"),
    "can": ("can", "count"), "cans": ("can", "count"),
    "each": ("each", "count"),
}

# Quantity words with no number. These must round-trip as a qualifier and reach
# the shopping list as a presence item -- never as 0, and never silently dropped.
QUALIFIERS = {
    "pinch", "dash", "splash", "handful", "to taste", "as needed",
    "for garnish", "for serving", "for frying", "optional",
}

# Leading adjectives that describe preparation rather than identity. Stripping
# these yields the name the shopping list and the pantry should match on:
# "grated Parmesan" and "Parmesan" are the same purchase.
PREP_PREFIXES = {
    "grated", "chopped", "minced", "ground", "melted", "softened", "shredded",
    "sliced", "diced", "crushed", "smashed", "toasted", "cooked", "frozen",
    "canned", "drained", "rinsed", "peeled", "trimmed", "finely", "roughly",
    "thinly", "freshly",
}

# Deliberately NOT in PREP_PREFIXES, because they change what you buy:
#   "prepared horseradish" is a different product from horseradish root
#   "fresh chives" vs dried is a different shelf
IDENTITY_PREFIXES = {"prepared", "fresh", "dried", "smoked", "unsalted", "salted", "whole", "heavy"}

# Solid foods, for resolving a bare "oz". See resolve_oz.
MASS_HINTS = {
    "steak", "beef", "pork", "chicken", "lamb", "fish", "salmon", "shrimp",
    "spinach", "cheese", "butter", "chocolate", "flour", "sugar", "pasta",
    "mushroom", "mushrooms", "greens", "kale", "arugula", "meat", "bacon",
}

# Count nouns that recipes park in the NAME instead of the unit column:
# "2  garlic cloves" has an empty unit cell. Left alone, the ingredient is
# called "garlic cloves", which never matches the "garlic" in the pantry and
# never aggregates with "1 tbsp garlic" from another recipe.
COUNT_NOUNS = {
    "cloves": "clove", "clove": "clove",
    "sprigs": "sprig", "sprig": "sprig",
    "stalks": "stalk", "stalk": "stalk",
    "heads": "head", "head": "head",
    "slices": "slice", "slice": "slice",
    "ribs": "rib", "rib": "rib",
    "ears": "ear", "ear": "ear",
    "bunches": "bunch", "bunch": "bunch",
    "cans": "can", "can": "can",
    "leaves": "leaf", "leaf": "leaf",
}

NUM = r"(?:\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)"


def parse_number(text):
    """'1 1/4' -> Fraction(5,4). Returns None if not numeric."""
    text = text.strip()
    if not text:
        return None
    m = re.fullmatch(r"(\d+)\s+(\d+)/(\d+)", text)      # mixed: 1 1/4
    if m:
        whole, num, den = (int(g) for g in m.groups())
        return Fraction(whole) + Fraction(num, den)
    m = re.fullmatch(r"(\d+)/(\d+)", text)              # vulgar: 1/2
    if m:
        return Fraction(int(m.group(1)), int(m.group(2)))
    m = re.fullmatch(r"\d+(?:\.\d+)?", text)            # 12 or 1.25
    if m:
        return Fraction(text)
    return None


def resolve_oz(name):
    """Bare 'oz' is ambiguous: weight ounces or fluid ounces.

    This document uses it three times -- 16 oz steak, 10 oz spinach, 4 oz cream
    cheese -- and all three are weight. Guessing volume would turn a steak into
    a liquid. Resolve by ingredient and RECORD the result, so nothing downstream
    has to guess again.
    """
    low = name.lower()
    if any(h in low for h in MASS_HINTS):
        return "mass", True
    if any(w in low for w in ("water", "stock", "broth", "milk", "cream", "wine", "juice", "oil")):
        return "volume", True
    return "mass", False  # default, flagged unconfirmed for the user to check


def split_quantity_cell(cell, name_for_oz):
    """'3 tbsp' -> (3, tbsp, volume). '2' -> (2, None, count). 'Pinch' -> qualifier."""
    cell = cell.strip()
    low = cell.lower().rstrip(".")

    if low in QUALIFIERS:
        return {"qualifier": cell, "quantity": None, "unit": None, "dimension": None}

    m = re.fullmatch(rf"({NUM})\s*(.*)", cell)
    if not m:
        return {"qualifier": cell or None, "quantity": None, "unit": None, "dimension": None}

    qty = parse_number(m.group(1))
    unit_raw = m.group(2).strip().lower().rstrip(".")
    unit_raw = unit_raw.replace("fl oz", "floz").replace("fl. oz", "floz")

    if not unit_raw:
        # "2  garlic cloves" -- the unit is embedded in the name.
        return {"qualifier": None, "quantity": qty, "unit": None, "dimension": "count"}

    if unit_raw in UNITS:
        unit, dim = UNITS[unit_raw]
        confirmed = True
        if unit == "oz":
            dim, confirmed = resolve_oz(name_for_oz)
        out = {"qualifier": None, "quantity": qty, "unit": unit, "dimension": dim}
        if unit == "oz":
            out["dimensionConfirmed"] = confirmed
        return out

    # An unknown word in the unit column is usually a count noun ("12 rounds").
    return {"qualifier": None, "quantity": qty, "unit": unit_raw, "dimension": "count",
            "unitUnrecognized": True}


def split_name_and_prep(text):
    """'shallot, minced' -> ('shallot', 'minced'). 'grated Parmesan' -> ('Parmesan', 'grated').

    Two different shapes in one document, which is why this cannot just split on
    the first comma.
    """
    text = text.strip().rstrip(".")
    prep_parts = []

    # trailing clause after a comma
    if "," in text:
        head, tail = text.split(",", 1)
        text, prep_parts = head.strip(), [tail.strip()]

    # leading preparation adjectives, but not ones that change the product
    words = text.split()
    while words and words[0].lower() in PREP_PREFIXES and words[0].lower() not in IDENTITY_PREFIXES:
        prep_parts.insert(0, words.pop(0).lower())

    name = " ".join(words)
    # "garlic cloves" -> the count unit lives in the name; keep it, but surface it
    return name, ", ".join(p for p in prep_parts if p) or None


def extract_count_noun(name):
    """'garlic cloves' -> ('garlic', 'clove'). Only for lines whose unit column
    was empty; a trailing count noun there IS the unit.

    Guarded to a known list on purpose. Inferring from any trailing plural would
    turn "chicken thighs" into "chicken" + "thigh" and, worse, "mushrooms" into
    "mushroom" + "" -- changing what gets bought.
    """
    words = name.split()
    if len(words) >= 2 and words[-1].lower() in COUNT_NOUNS:
        return " ".join(words[:-1]), COUNT_NOUNS[words[-1].lower()]
    return name, None


def slug(raw):
    """'NY Strip Crostini' -> 'ny-strip-crostini'. Used for the recipe id and
    as the stem of every line and step id."""
    out = []
    for ch in raw.lower().strip():
        if ch.isalnum():
            out.append(ch)
        elif out and out[-1] != "-":
            out.append("-")
    return "".join(out).strip("-")


def assign_ids(out):
    """Give every ingredient line and step a stable id.

    The app keeps Brandon's tweaks -- "1 tbsp not 2", a corrected step -- in
    SwiftData as an overlay keyed by these ids, while the recipe itself is
    immutable bundled content. So the id has to survive the recipe file being
    revised and re-committed.

    It is NAME-based with an occurrence number, deliberately not positional.
    A positional id silently re-points his override onto a different
    ingredient when a line is inserted above it; a name-based one lapses
    visibly when the ingredient it named is gone, which is exactly when it
    should. This recipe is why the occurrence number exists: butter appears in
    two components, so it is butter-1 and butter-2.
    """
    seen = {}
    for comp in out["components"]:
        for line in comp["lines"]:
            stem = slug(line["name"]) or "line"
            seen[stem] = seen.get(stem, 0) + 1
            line["lineID"] = f"{stem}-{seen[stem]}"

    seen_steps = {}
    for step in out["steps"]:
        stem = slug(step["title"] or "") or f"step-{step['order']}"
        seen_steps[stem] = seen_steps.get(stem, 0) + 1
        step["stepID"] = f"{stem}-{seen_steps[stem]}"


def flatten_quantities(out):
    """Turn each line's Fraction into the five flat fields the app persists.

    The app stores a quantity as hasQuantity + numerator + denominator + unit +
    dimension rather than as one Codable blob, so the unit table can change
    without a migration that decodes every stored row. Emitting that shape here
    means the importer and the store agree without a translation layer.
    """
    for comp in out["components"]:
        for line in comp["lines"]:
            f = line.pop("quantity", None)
            line["hasQuantity"] = f is not None
            line["amountNumerator"] = f.numerator if f is not None else 0
            line["amountDenominator"] = f.denominator if f is not None else 1
            line["display"] = format_fraction(f) if f is not None else (line.get("qualifier") or "")


def parse(text):
    lines = text.splitlines()
    out = {
        "schemaVersion": 1, "id": None,
        "title": None, "summary": None,
        "yieldText": None, "yieldAmount": None, "yieldUnitLabel": None, "servings": None,
        "activeMinutes": None, "totalMinutes": None,
        "components": [], "steps": [], "notes": [], "warnings": [],
    }

    # --- title + description: the first two non-empty lines ---
    head = [l.strip() for l in lines if l.strip()]
    if head:
        out["title"] = head[0]
        out["id"] = slug(head[0])
    if len(head) > 1 and not head[1].lower().startswith(("makes", "ingredients")):
        out["summary"] = head[1]

    body = "\n".join(lines)

    # --- yields and times ---
    m = re.search(r"^\s*(\d+)\s+(\S+)\s*\(serves\s+(\d+)\)", body, re.M)
    if m:
        out["yieldAmount"] = int(m.group(1))
        out["yieldUnitLabel"] = m.group(2)
        out["servings"] = int(m.group(3))
        out["yieldText"] = m.group(0).strip()
    else:
        m = re.search(r"serves\s+(\d+)", body, re.I)
        if m:
            out["servings"] = int(m.group(1))
        else:
            out["warnings"].append("no serving count found; meal-plan scaling needs one")

    # Active and Total both render as "About <n> minutes" / "About 1 hour 10
    # minutes" in one -layout table row, in that order.
    times = re.findall(r"About\s+((?:\d+\s*hour[s]?)?\s*(?:\d+\s*minutes?)?)", body, re.I)

    def to_min(s):
        h = re.search(r"(\d+)\s*hour", s, re.I)
        mi = re.search(r"(\d+)\s*minute", s, re.I)
        total = (int(h.group(1)) * 60 if h else 0) + (int(mi.group(1)) if mi else 0)
        return total or None

    if len(times) >= 2:
        out["activeMinutes"] = to_min(times[0])
        out["totalMinutes"] = to_min(times[1])
    elif len(times) == 1:
        out["totalMinutes"] = to_min(times[0])

    # --- sections ---
    def section(name, nxt):
        # (?:...) around name is load-bearing: "Instructions|Method|Directions"
        # unwrapped makes the alternation span the ENTIRE pattern, so a match on
        # a later branch has no group(1) at all and this returned None.
        m = re.search(rf"^\s*(?:{name})\s*$(.*?)(?=^\s*(?:{nxt})\s*$|\Z)", body, re.M | re.S)
        return m.group(1) if m else ""

    ing_block = section("Ingredients", "Instructions|Method|Directions")
    step_block = section("Instructions|Method|Directions", "Notes|Tips")
    note_block = section("Notes|Tips", "$")

    # --- ingredients, grouped ---
    current = {"name": None, "lines": []}
    for raw in ing_block.splitlines():
        if not raw.strip():
            continue
        cells = re.split(r"\s{2,}", raw.strip())
        indented = len(raw) - len(raw.lstrip()) >= 4

        # A group subhead is a lone un-indented phrase with no quantity column.
        if len(cells) == 1 and not indented:
            if current["lines"] or current["name"]:
                out["components"].append(current)
            current = {"name": cells[0], "lines": []}
            continue
        if len(cells) == 1:
            # indented single cell: an ingredient with no quantity at all
            name, prep = split_name_and_prep(cells[0])
            current["lines"].append({"name": name, "preparation": prep, "raw": raw.strip(),
                                     "qualifier": None, "quantity": None, "unit": None,
                                     "dimension": None})
            continue

        qty_cell, name_cell = cells[0], " ".join(cells[1:])
        name, prep = split_name_and_prep(name_cell)
        q = split_quantity_cell(qty_cell, name)
        if q.get("unit") is None and q.get("quantity") is not None:
            name, inferred = extract_count_noun(name)
            if inferred:
                q["unit"] = inferred
        line = {"name": name, "preparation": prep, "raw": raw.strip()}
        line.update(q)
        current["lines"].append(line)
    if current["lines"] or current["name"]:
        out["components"].append(current)

    # --- steps: "N. Title (7 to 8 min). Body" ---
    chunks = re.split(r"^\s*(\d+)\.\s+", step_block, flags=re.M)[1:]
    for i in range(0, len(chunks) - 1, 2):
        n, txt = chunks[i], " ".join(chunks[i + 1].split())
        step = {"order": int(n), "title": None, "body": txt,
                "minMinutes": None, "maxMinutes": None}
        m = re.match(r"(.*?)\s*\((\d+)(?:\s*to\s*(\d+))?\s*min[a-z]*\)\.\s*(.*)", txt)
        if m:
            step["title"] = m.group(1).strip()
            step["minMinutes"] = int(m.group(2))
            step["maxMinutes"] = int(m.group(3) or m.group(2))
            step["body"] = m.group(4).strip()
        else:
            m = re.match(r"([A-Z][^.]{0,60})\.\s+(.*)", txt)
            if m:
                step["title"], step["body"] = m.group(1).strip(), m.group(2).strip()
        out["steps"].append(step)

    # --- notes: bulleted, with wrapped continuations ---
    cur = None
    for raw in note_block.splitlines():
        s = raw.strip()
        if not s:
            continue
        if s.startswith(("•", "-", "*")):
            if cur:
                out["notes"].append(cur)
            cur = s.lstrip("•-* ").strip()
        elif cur:
            cur += " " + s
    if cur:
        out["notes"].append(cur)

    # --- the self-aggregation check this very recipe demands ---
    tally = {}
    for comp in out["components"]:
        for l in comp["lines"]:
            if l.get("quantity") and l.get("unit"):
                tally.setdefault(l["name"].lower(), set()).add(l["dimension"])
    dupes = [k for k, v in tally.items()
             if sum(1 for c in out["components"] for l in c["lines"]
                    if l["name"].lower() == k) > 1]
    if dupes:
        out["aggregatesWithinRecipe"] = sorted(dupes)

    # Order matters: ids are assigned from names, and the tally above still
    # needs `quantity` as a Fraction, so flattening comes last.
    assign_ids(out)
    flatten_quantities(out)

    return out


def format_fraction(f):
    """Fraction(5,4) -> '1 1/4'. Recipes are written in vulgar fractions, so
    displaying 1.25 tsp would look wrong even though it is the same number."""
    if f.denominator == 1:
        return str(f.numerator)
    whole, rem = divmod(f.numerator, f.denominator)
    if whole:
        return f"{whole} {rem}/{f.denominator}"
    return f"{f.numerator}/{f.denominator}"


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "-"
    text = sys.stdin.read() if src == "-" else open(src, encoding="utf-8").read()
    print(json.dumps(parse(text), indent=2))


if __name__ == "__main__":
    main()
