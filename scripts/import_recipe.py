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
import os
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
    "stick": ("stick", "count"), "sticks": ("stick", "count"),
    "packet": ("packet", "count"), "packets": ("packet", "count"),
    "pinch": ("pinch", "count"), "pinches": ("pinch", "count"),
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

    # Trailing clause after a comma OR a colon. The mixed-berry line uses a
    # colon — "mixed berries: any mix of strawberries, blueberries..." — and
    # splitting only on commas left the whole clause inside the name, so it
    # could never match the catalogue.
    cut = min([i for i in (text.find(","), text.find(":")) if i >= 0], default=-1)
    if cut >= 0:
        text, prep_parts = text[:cut].strip(), [text[cut + 1:].strip()]
    else:
        # An either/or with no comma: "water or apple cider". The first is the
        # one the recipe assumes, so it becomes the name and the alternative
        # becomes preparation. Left whole, "water or apple cider" matches
        # nothing in the catalogue and reaches the shopping list unresolved.
        alt = re.search(r"\s+or\s+", text)
        if alt:
            prep_parts = ["or " + text[alt.end():].strip()]
            text = text[:alt.start()].strip()

    # A leading SIZE word describes the specimen, not the product: "large eggs"
    # is bought as eggs, and leaving the word on the name keeps it from matching
    # the catalogue's "eggs".
    words = text.split()
    while words and words[0].lower() in SIZE_WORDS:
        prep_parts.insert(0, words.pop(0).lower())

    # leading preparation adjectives, but not ones that change the product
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

            # A range, as three of the compotes write maple syrup. The shopping
            # list buys the MAX because arriving short is worse than a spoonful
            # over; the display keeps both so the cook still has the latitude
            # the recipe gave them.
            hi = line.pop("quantityMax", None)
            line["isRange"] = hi is not None
            line["amountMaxNumerator"] = hi.numerator if hi is not None else 0
            line["amountMaxDenominator"] = hi.denominator if hi is not None else 1
            if hi is not None and f is not None:
                line["display"] = f"{format_fraction(f)} to {format_fraction(hi)}"

            # The recipe's own second measurement: "all-purpose flour (190g)".
            # This is the volume-and-weight pair Brandon asked for, handed over
            # by the document, so it is kept rather than discarded with the
            # parentheses.
            alt = line.pop("altAmount", None)
            line["hasAltAmount"] = alt is not None
            line["altAmountNumerator"] = alt.numerator if alt is not None else 0
            line["altAmountDenominator"] = alt.denominator if alt is not None else 1
            line.setdefault("altUnit", None)
            line.setdefault("isOption", False)
            line.setdefault("optionText", None)


# Words that sit in the unit column but size the ingredient rather than measure
# it: "3 medium apples". Treating them as units gives a `count:medium` bucket
# that never merges with plain apples.
SIZE_WORDS = {"small", "medium", "large", "extra-large", "x-large", "jumbo"}

# The repeated page footer a multi-recipe document carries: the document's own
# title, a wide gutter, then "Page N".
PAGE_FOOTER = re.compile(r"^\s*(?P<doc>\S.*?)\s{2,}Page\s+\d+\s*$", re.M)

SECTION_HEADS = (r"Ingredients|Shopping List|Instructions|Method|Directions"
                 r"|Notes|Tips|Cooking Times")


def split_pages(text):
    """Split a document into one chunk per recipe, plus the document's title.

    Recipe 02 is four recipes in one PDF -- a pancake batter and three compotes,
    one per page. Parsed as a single recipe it produced one component, sixteen
    merged steps and a total time of three minutes lifted out of "about 3
    minutes" in a whipping instruction. And it reported no warnings at all,
    which was the worst part of it.

    The page footer is the split: every page ends with the document title, a
    wide gutter and "Page N". A single-recipe document has no footer, so it
    comes back as one chunk and nothing changes for recipe 01.
    """
    doc_title = None
    pages, last = [], 0
    for m in PAGE_FOOTER.finditer(text):
        doc_title = doc_title or m.group("doc").strip()
        page = text[last:m.start()]
        if page.strip():
            pages.append(page)
        last = m.end()
    tail = text[last:]
    if tail.strip():
        pages.append(tail)
    if not pages:
        return [text], doc_title

    # A PAGE BREAK IS NOT A RECIPE BREAK. The compotes happen to be one recipe
    # per page; the roast turkey is one recipe over two, and splitting on the
    # footer turned its second page into a separate recipe called
    # "Instructions" -- leaving the turkey itself with no method at all.
    #
    # A page CONTINUES the previous recipe when it opens with a section header
    # ("Instructions", "Cooking Times"). It starts a new one when it opens with
    # anything else, which is a title.
    chunks = [pages[0]]
    for page in pages[1:]:
        first = next((l.strip() for l in page.splitlines() if l.strip()), "")
        continues = bool(re.fullmatch(rf"(?:{SECTION_HEADS})", first, re.I))
        if continues:
            chunks[-1] = chunks[-1] + "\n" + page
        else:
            chunks.append(page)
    return chunks, doc_title


def split_range(cell):
    """'2 to 3 tbsp' -> (Fraction(2), Fraction(3), 'tbsp'). Otherwise (None, None, None).

    Three of the four recipes in document 02 write maple syrup as "2 to 3 tbsp,
    adjusted to the sweetness of the berries". Read as a single number it became
    quantity 2 with the unit "to 3 tbsp".
    """
    m = re.fullmatch(rf"({NUM})\s+(?:to|-|–)\s+({NUM})\s*(.*)", cell.strip())
    if not m:
        return None, None, None
    lo = parse_number(m.group(1))
    hi = parse_number(m.group(2))
    if lo is None or hi is None:
        return None, None, None
    return lo, hi, (m.group(3).strip() or None)


def extract_alt_measure(text):
    """Pull a parenthetical equivalent out of an ingredient name.

    Document 02 gives both measures throughout: "all-purpose flour (190g),
    spooned and leveled", "blueberries (300g)", "apples (about 1 lb or 450g)".
    That is exactly the dual measurement Brandon asked for -- volume for
    cooking, grams for baking -- handed over by the recipe itself, so throwing
    it away would be perverse.

    Returns (text without the parenthetical, amount, unit). Where a
    parenthetical offers two ("about 1 lb or 450g") the LAST is taken, because
    these documents put the metric second and grams are the useful one.
    """
    best = None
    for m in re.finditer(r"\(([^)]*)\)", text):
        inner = m.group(1)
        found = None
        for q in re.finditer(rf"({NUM})\s*([A-Za-z]+)", inner):
            unit = q.group(2).lower()
            if unit in UNITS:
                found = (m.span(), parse_number(q.group(1)), UNITS[unit][0])
        if found:
            best = found
    if best is None:
        return text, None, None
    (lo, hi), amount, unit = best
    cleaned = (text[:lo] + text[hi:]).replace("  ", " ")
    # Removing "(300g)" from "mixed berries (300g): any mix of..." leaves a space
    # before the colon, and the orphaned punctuation ends up inside the name.
    cleaned = re.sub(r"\s+([,:;])", r"\1", cleaned).strip().strip(",").strip()
    return cleaned, amount, unit


def strip_parentheticals(text):
    """Move any remaining bracketed aside out of the name and into preparation.

    After the measured parentheticals are taken out, what is left is commentary:
    "baking powder (do not skip)", "cream of tartar (optional, helps the whites
    hold)". Left in the name, the first never matches the catalogue's "baking
    powder" — and the second was worse, because `split_name_and_prep` cut it at
    the comma INSIDE the brackets and produced an ingredient literally called
    "cream of tartar (optional".
    """
    notes = []

    def take(m):
        notes.append(m.group(1).strip())
        return " "

    cleaned = re.sub(r"\(([^)]*)\)", take, text)
    cleaned = re.sub(r"\s+([,:;])", r"\1", cleaned)
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip().strip(",").strip()
    return cleaned, [n for n in notes if n]


def looks_like_option_label(cell):
    """True for a first column that names a CHOICE rather than an amount.

    The pancake's "Spice Mix-Ins" group is three alternatives, not three
    ingredients: `Cinnamon | 1/2 tsp, good with the apple compote`,
    `Nutmeg | 1/4 tsp`, `Both | 1/4 tsp cinnamon plus 1/8 tsp nutmeg`. The
    amount is in the SECOND column and the first holds the option's name, so
    every quantity parser reads the row backwards.
    """
    c = cell.strip().lower().rstrip(".")
    if not c or c in QUALIFIERS:
        return False
    return not re.search(r"\d", c)


# Amount words that stand in for a number. The turkey asks for "lots" of
# pepper and "all the roasted vegetables and drippings"; neither is a quantity
# and both are the real answer.
AMOUNT_WORDS = (
    "lots", "a lot", "plenty", "to taste", "as needed", "as much as",
    "all the", "all of", "a few", "a handful", "handful", "some", "several",
    "freshly ground", "for garnish", "for serving", "optional",
)

# A group whose name says its rows are ALTERNATIVES rather than a list of
# ingredients. Without this signal the pancake's "Spice Mix-Ins" is
# indistinguishable from the turkey's name-first shopping list: both have a
# word in the first column and an amount in the second.
ALTERNATIVES_GROUP = re.compile(
    r"mix-?ins?|variations?|options?|choices?|instead of|alternativ|either", re.I)


def is_emphasis(text):
    """An all-caps line is a shouted instruction, not an ingredient.

    The turkey opens with "DO. NOT. SALT." and "DO NOT USE SALTED BUTTER." on
    their own centred lines, and the whole recipe depends on them -- the gravy
    is unsalted too, deliberately, so that the cook salts once at the end.
    Parsed as ingredient rows they became two ingredients named DO. NOT. SALT.
    """
    stripped = re.sub(r"[^A-Za-z]", "", text)
    return len(stripped) > 3 and stripped.isupper()


def is_subhead(text):
    """A short, un-terminated line that names a group.

    The turkey's prose paragraphs ("The bottom of the roasting pan is a bed
    of...") were each becoming a group heading, which is how one recipe
    produced fourteen groups. A heading is short and does not end a sentence.
    """
    t = text.strip()
    if not t or len(t) > 60:
        return False
    if t.endswith((".", ":", ";", ",")):
        return False
    return not is_emphasis(t)


def detect_orientation(rows):
    """Which column holds the amount.

    Recipes 01 and 02 put the amount first: `3 tbsp | olive oil`. The turkey
    and the gravy put the ingredient first: `Butter | 2 sticks, UNSALTED`.
    Assuming either way round silently mangles the other, and name-first
    produced an "option" row for every single ingredient in both documents.
    """
    amount_first = 0
    name_first = 0
    for cells in rows:
        head = cells[0].strip()
        tail = " ".join(cells[1:]).strip()
        head_l = head.lower().rstrip(".")
        if re.match(rf"{NUM}", head) or head_l in QUALIFIERS:
            amount_first += 1
        elif re.match(rf"{NUM}", tail) or tail.lower().startswith(AMOUNT_WORDS):
            name_first += 1
    return "name" if name_first > amount_first else "amount"


def parse_amount_cell(cell, name):
    """Read an amount cell that may also carry the rest of the sentence.

    Name-first documents write the whole remainder of the line in the second
    column: "2 sticks, UNSALTED", "1 whole head, cut in half", "1/4 cup
    (4 tbsp) skimmed turkey fat from the drippings, topped up with UNSALTED
    butter if short". So the quantity is a PREFIX and everything after it is
    preparation.
    """
    cell = cell.strip()
    cell, alt_amount, alt_unit = extract_alt_measure(cell)
    cell = cell.strip()

    lo, hi, range_rest = split_range(cell)
    if lo is not None:
        unit, rest = _leading_unit(range_rest or "")
        q = {"qualifier": None, "quantity": lo, "quantityMax": hi,
             "unit": unit, "dimension": _dimension_for(unit, name)}
        return q, rest, alt_amount, alt_unit

    m = re.match(rf"({NUM})\s*(.*)", cell)
    if m:
        amount = parse_number(m.group(1))
        unit, rest = _leading_unit(m.group(2))
        q = {"qualifier": None, "quantity": amount, "unit": unit,
             "dimension": _dimension_for(unit, name)}
        return q, rest, alt_amount, alt_unit

    # No number at all. The first clause is the amount, the rest is detail:
    # "lots, best if freshly ground" -> "lots" + "best if freshly ground".
    head, _, tail = cell.partition(",")
    return ({"qualifier": head.strip() or None, "quantity": None,
             "unit": None, "dimension": None},
            tail.strip(), alt_amount, alt_unit)


def _leading_unit(text):
    """Take a unit off the front of the remainder, if one is there.

    Scans two words, not one, so "1 whole head, cut in half" finds `head`
    rather than stopping at `whole` and leaving the count noun in the prose.
    """
    text = text.strip().lstrip(",").strip()
    words = text.split()
    for span in (2, 1):
        if len(words) < span:
            continue
        candidate = words[span - 1].lower().strip(",.")
        if candidate in UNITS:
            rest = " ".join(words[span:]).strip().lstrip(",").strip()
            return UNITS[candidate][0], rest
    return None, text


def _dimension_for(unit, name):
    if unit is None:
        return "count"
    dim = UNITS.get(unit, (unit, "count"))[1]
    if unit == "oz":
        dim, _ = resolve_oz(name)
    return dim


CATALOGUE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "KitchenAid", "Resources", "ingredients.json")


def catalogue_index():
    """name or alias (lowercased) -> canonical name, or {} if not built yet."""
    if not os.path.exists(CATALOGUE_PATH):
        return {}
    with open(CATALOGUE_PATH, encoding="utf-8") as fh:
        data = json.load(fh)
    index = {}
    for item in data.get("items", []):
        for key in [item["name"]] + item.get("aliases", []):
            index[key.lower()] = item["name"]
    return index


def warn_unresolved(recipe, index):
    """Flag ingredient names the shipped catalogue does not know.

    An unresolved name is a shopping-list miss and an inventory miss: nothing
    aggregates it, nothing subtracts the pantry from it. The turkey and the
    gravy produced four, and all four are the same kind of thing -- a COLUMN
    LABEL rather than an ingredient. "Fat", "Stock", "Pan base" and "Vegetable
    bed" are how that author heads his rows, with the real ingredient in the
    prose beside it ("UNSALTED turkey or chicken stock, warmed").
    """
    if not index:
        return
    for component in recipe["components"]:
        for line in component["lines"]:
            if line.get("isOption") or not line.get("name"):
                continue
            if line["name"].lower() not in index:
                recipe["warnings"].append(
                    f"{line['name']!r} matches nothing in the ingredient "
                    "catalogue, so it will not aggregate or match the pantry")


OVERRIDES_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "docs", "recipe-overrides.json")

# Which warning an override answers, so a fact Brandon supplied stops the
# importer complaining about it on every run.
WARNING_SATISFIED_BY = {
    "servings": "no serving count found; meal-plan scaling needs one",
    "yieldAmount": "no yield found (how much it makes)",
    "totalMinutes": "no active or total time found",
    "activeMinutes": "no active or total time found",
}


def load_overrides():
    """Facts the source document does not state, supplied by Brandon.

    The bundled files are generated, so editing one by hand is lost the next
    time its document is re-imported -- the same trap as hand-editing
    ingredients.json. The three compotes are the first case: the document gives
    no serving count for any of them, and the meal planner divides by servings,
    so until he said "they serve approx 4" they could not be scaled at all.
    """
    if not os.path.exists(OVERRIDES_PATH):
        return {}
    with open(OVERRIDES_PATH, encoding="utf-8") as fh:
        raw = json.load(fh)
    return {k: v for k, v in raw.items() if not k.startswith("_")}


def apply_overrides(recipe, overrides):
    entry = overrides.get(recipe["id"])
    if not entry:
        return
    applied = {}
    for key, value in entry.items():
        if key in ("why", "_comment"):
            continue
        recipe[key] = value
        applied[key] = value
        # The warning was true of the document and is no longer true of the
        # recipe, so it goes -- but the provenance below records that the value
        # did not come from the page.
        gone = WARNING_SATISFIED_BY.get(key)
        if gone and gone in recipe["warnings"]:
            recipe["warnings"].remove(gone)
    if applied:
        recipe["overrides"] = {"fields": sorted(applied), "why": entry.get("why", "")}


def parse(text):
    """Parse a document of one or more recipes into the bundled envelope."""
    chunks, doc_title = split_pages(text)
    recipes = [parse_one(c) for c in chunks]
    recipes = [r for r in recipes if r["components"] or r["steps"]]
    overrides = load_overrides()
    index = catalogue_index()
    for recipe in recipes:
        apply_overrides(recipe, overrides)
        warn_unresolved(recipe, index)
    return {
        "schemaVersion": 1,
        "documentTitle": doc_title,
        "recipes": recipes,
    }


def parse_one(text):
    lines = text.splitlines()
    out = {
        "schemaVersion": 1, "id": None,
        "title": None, "summary": None,
        "yieldText": None, "yieldAmount": None, "yieldUnitLabel": None, "servings": None,
        # True when the serving count is a stated approximation rather than a
        # count the recipe commits to. "Serves approx 4" should not render as
        # the same confident "4" that "12 crostini (serves 4)" earns.
        "servingsApproximate": False,
        "activeMinutes": None, "totalMinutes": None,
        # A rate rather than a fixed time: "13 minutes per pound at 350 F".
        # The turkey has no total time at all -- it depends on the bird.
        "minutesPerPound": None, "ovenTempF": None,
        # Lookup tables the document prints, like the turkey's weight-to-time
        # chart. Kept whole because the useful answer is a row, and because
        # mashed into the last step's body it was unusable.
        "tables": [],
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

    # The first six non-empty lines: title, description, and the Makes/Active/
    # Total table when there is one. Times are read ONLY from here, because
    # searching the whole body picked "about 3 minutes" out of the pancake's
    # egg-white step and reported it as the recipe's total time.
    nonempty = [i for i, l in enumerate(lines) if l.strip()]
    header_region = "\n".join(lines[i] for i in nonempty[:6])

    # An all-caps line above the first section header is a shouted
    # instruction, and in this recipe it is the single most important thing on
    # the page: the turkey, its butter and its gravy are all deliberately
    # unsalted so the cook salts once at the end. Both lines were being dropped
    # entirely -- not mangled, LOST -- which is the worst outcome available.
    for line in header_region.splitlines():
        t = line.strip()
        if t and is_emphasis(t) and t not in out["notes"]:
            out["notes"].append(t)

    # A per-pound rate, from the description or the Cooking Times section.
    m = re.search(r"(\d+(?:\.\d+)?)\s*minutes?\s*per\s*(?:pound|lb)", body, re.I)
    if m:
        out["minutesPerPound"] = float(m.group(1)) if "." in m.group(1) else int(m.group(1))
    m = re.search(r"(\d{3})\s*F\b", body)
    if m:
        out["ovenTempF"] = int(m.group(1))

    # --- yields ---
    # Recipe 01 tabulates it ("12 crostini (serves 4)"); recipe 02 writes it
    # into the description ("Makes about 8 pancakes, serves 4.").
    m = re.search(r"^\s*(\d+)\s+(\S+)\s*\(serves\s+(\d+)\)", body, re.M)
    if m:
        out["yieldAmount"] = int(m.group(1))
        out["yieldUnitLabel"] = m.group(2)
        out["servings"] = int(m.group(3))
        out["yieldText"] = m.group(0).strip()
    else:
        m = re.search(r"Makes\s+(?:about\s+)?(\d+)\s+([A-Za-z]+)[^.]*?serves\s+(\d+)",
                      body, re.I)
        if m:
            out["yieldAmount"] = int(m.group(1))
            out["yieldUnitLabel"] = m.group(2)
            out["servings"] = int(m.group(3))
            out["yieldText"] = m.group(0).strip()
        else:
            m = re.search(r"Makes\s+(?:about\s+)?(\d+)\s+([A-Za-z]+)", body, re.I)
            if m:
                out["yieldAmount"] = int(m.group(1))
                out["yieldUnitLabel"] = m.group(2)
                out["yieldText"] = m.group(0).strip()
            m = re.search(r"serves\s+(\d+)", body, re.I)
            if m:
                out["servings"] = int(m.group(1))
            else:
                out["warnings"].append(
                    "no serving count found; meal-plan scaling needs one")
    if out["yieldAmount"] is None:
        out["warnings"].append("no yield found (how much it makes)")

    # Active and Total both render as "About <n> minutes" / "About 1 hour 10
    # minutes" in one -layout table row, in that order.
    raw_times = re.findall(
        r"About\s+((?:\d+\s*hour[s]?)?\s*(?:\d+\s*minutes?)?)", header_region, re.I)

    def to_min(s):
        h = re.search(r"(\d+)\s*hour", s, re.I)
        mi = re.search(r"(\d+)\s*minute", s, re.I)
        total = (int(h.group(1)) * 60 if h else 0) + (int(mi.group(1)) if mi else 0)
        return total or None

    # "Makes about 8 pancakes" matches the pattern with an EMPTY group, so an
    # unfiltered list made a timeless recipe look timed.
    times = [t for t in raw_times if to_min(t)]
    if len(times) >= 2:
        out["activeMinutes"] = to_min(times[0])
        out["totalMinutes"] = to_min(times[1])
    elif len(times) == 1:
        out["totalMinutes"] = to_min(times[0])
    elif out["minutesPerPound"] is None:
        out["warnings"].append("no active or total time found")

    # --- sections ---
    def section(name, nxt):
        # (?:...) around name is load-bearing: "Instructions|Method|Directions"
        # unwrapped makes the alternation span the ENTIRE pattern, so a match on
        # a later branch has no group(1) at all and this returned None.
        m = re.search(rf"^\s*(?:{name})\s*$(.*?)(?=^\s*(?:{nxt})\s*$|\Z)", body, re.M | re.S)
        return m.group(1) if m else ""

    ing_block = section("Ingredients|Shopping List", "Instructions|Method|Directions")
    if not ing_block.strip():
        # The pancake has NO "Ingredients" header: its groups ("Pancake Batter",
        # "Spice Mix-Ins (add to the dry ingredients)") sit straight under the
        # description. Requiring the header found the blueberry compote's
        # section four pages later and attributed it to the pancake.
        method_idx = next(
            (i for i, l in enumerate(lines)
             if re.fullmatch(r"\s*(?:Instructions|Method|Directions)\s*", l)), None)
        start = nonempty[2] if len(nonempty) > 2 else 0
        ing_block = "\n".join(lines[start:method_idx] if method_idx else lines[start:])

    step_block = section("Instructions|Method|Directions", "Notes|Tips|Cooking Times")
    note_block = section("Notes|Tips", "$")

    # Recipe 02 has no "Notes" header. It closes each recipe with a LABELLED
    # PARAGRAPH instead -- "Tip: mash a few berries against the side of the
    # pan", "Fluff checklist: use fresh baking powder, weigh or spoon the
    # flour...". Those are notes by any other name, and because they sit after
    # the numbered method with no header between, the step parser was
    # swallowing each one into the body of the final step.
    NOTE_LABEL = re.compile(r"^\s*(?:Tips?|Notes?|[A-Z][a-z]+ checklist)\s*:", re.M)
    if not note_block.strip() and step_block:
        cut = NOTE_LABEL.search(step_block)
        if cut:
            note_block = step_block[cut.start():]
            step_block = step_block[:cut.start()]

    # --- ingredients: groups of rows, in whichever column order they use ---
    def is_header_row(line):
        if re.fullmatch(r"\s*(?:Ingredients|Shopping List)\s*", line):
            return True
        if re.search(r"\bMakes\b|\bActive time\b|\bTotal time\b", line):
            return True
        if "(serves" in line or re.search(r"About\s+\d+\s*(?:hour|minute)", line, re.I):
            return True
        return False

    groups = []
    cur = {"name": None, "description": [], "rows": []}
    pending_note = None

    for raw in ing_block.splitlines():
        if not raw.strip():
            pending_note = None
            continue
        if is_header_row(raw):
            continue
        indent = len(raw) - len(raw.lstrip())
        cells = re.split(r"\s{2,}", raw.strip())

        if len(cells) >= 2:
            cur["rows"].append(cells)
            pending_note = None
            continue

        text = cells[0].strip()

        # A line indented as far as the AMOUNT column continues the row above.
        # The gravy wraps two of its amounts, and judging continuation by a
        # lowercase start missed "UNSALTED butter if short".
        if indent >= 20 and cur["rows"]:
            cur["rows"][-1][-1] = cur["rows"][-1][-1] + " " + text
            continue

        if pending_note is not None:
            out["notes"][pending_note] += " " + text
            continue
        if NOTE_LABEL.match(raw):
            out["notes"].append(text)
            pending_note = len(out["notes"]) - 1
            continue
        if is_emphasis(text):
            out["notes"].append(text)
            continue
        if is_subhead(text):
            if cur["rows"] or cur["name"] or cur["description"]:
                groups.append(cur)
            cur = {"name": text, "description": [], "rows": []}
            continue
        cur["description"].append(text)

    if cur["rows"] or cur["name"] or cur["description"]:
        groups.append(cur)

    for group in groups:
        component = {"name": group["name"], "lines": []}
        if group["description"]:
            component["description"] = " ".join(group["description"])
        alternatives = bool(group["name"] and ALTERNATIVES_GROUP.search(group["name"]))
        orientation = detect_orientation(group["rows"])

        for cells in group["rows"]:
            raw_text = "  ".join(cells)
            head = cells[0].strip()
            tail = " ".join(cells[1:]).strip()

            if alternatives:
                component["lines"].append({
                    "name": head, "preparation": None, "raw": raw_text,
                    "isOption": True, "optionText": tail,
                    "qualifier": None, "quantity": None, "unit": None,
                    "dimension": None,
                })
                continue

            if orientation == "name":
                name, prep_from_name = split_name_and_prep(head)
                q, rest, alt_amount, alt_unit = parse_amount_cell(tail, name)
                prep = ", ".join([p for p in (prep_from_name, rest) if p])
            else:
                name_cell, alt_amount, alt_unit = extract_alt_measure(tail)
                name_cell, paren_notes = strip_parentheticals(name_cell)
                name, prep = split_name_and_prep(name_cell)
                if paren_notes:
                    prep = ", ".join([p for p in ([prep] + paren_notes) if p])
                lo, hi, range_unit = split_range(head)
                if lo is not None:
                    q = split_quantity_cell(f"{lo} {range_unit or ''}".strip(), name)
                    q["quantity"] = lo
                    q["quantityMax"] = hi
                else:
                    q = split_quantity_cell(head, name)

            if q.get("unit") in SIZE_WORDS:
                prep = ", ".join([p for p in (q["unit"], prep) if p])
                q["unit"] = None
                q["dimension"] = "count"
                q.pop("unitUnrecognized", None)

            if q.get("unit") is None and q.get("quantity") is not None:
                name, inferred = extract_count_noun(name)
                if inferred:
                    q["unit"] = inferred

            line = {"name": name, "preparation": prep or None, "raw": raw_text}
            line.update(q)
            if alt_amount is not None:
                line["altAmount"] = alt_amount
                line["altUnit"] = alt_unit
            if q.get("quantity") is None and not q.get("qualifier"):
                out["warnings"].append(
                    f"could not read a quantity for {name!r}")
            elif (q.get("quantity") is None
                  and str(q.get("qualifier")).strip().lower().rstrip(".") not in QUALIFIERS):
                # A RECOGNISED wording needs no warning: "Pinch", "to taste"
                # and "as needed" are understood and carried deliberately. The
                # warning is for wordings nobody has taught it -- "lots",
                # "all the roasted vegetables and drippings" -- which cannot be
                # scaled and are worth his eye once.
                out["warnings"].append(
                    f"{name!r} has a worded amount, not a number: "
                    f"{str(q.get('qualifier'))[:40]!r}")
            component["lines"].append(line)

        out["components"].append(component)

    # Only an unnamed group that follows a NAMED one is suspicious. The first
    # group is routinely unnamed -- it is the section itself ("Ingredients",
    # "Shopping List") -- and warning about that fired on every well-formed
    # document, which is how a warning stops being read.
    seen_named = False
    for component in out["components"]:
        if component["name"]:
            seen_named = True
        elif seen_named and component["lines"]:
            out["warnings"].append("an ingredient group has no heading")
            break

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

    # --- printed lookup tables ---
    table_block = section("Cooking Times", "Notes|Tips")
    if table_block.strip():
        table_rows = []
        for raw in table_block.splitlines():
            cells = re.split(r"\s{2,}", raw.strip())
            if len(cells) >= 3:
                table_rows.append(cells)
        if len(table_rows) >= 2:
            out["tables"].append({
                "name": "Cooking Times",
                "headers": table_rows[0],
                "rows": table_rows[1:],
            })

    # --- notes: a bullet or a label starts one; anything else continues it ---
    # Recipe 01 bullets them; recipe 02 labels them. Requiring a bullet lost
    # every note in recipe 02 silently, including the pancake's whole fluff
    # checklist, which is the most useful paragraph in the document.
    cur = None
    for raw in note_block.splitlines():
        s = raw.strip()
        if not s:
            continue
        if s.startswith(("•", "-", "*")):
            if cur:
                out["notes"].append(cur)
            cur = s.lstrip("•-* ").strip()
        elif NOTE_LABEL.match(raw):
            if cur:
                out["notes"].append(cur)
            cur = s
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
    args = [a for a in sys.argv[1:]]
    out_dir = None
    if "--out-dir" in args:
        i = args.index("--out-dir")
        out_dir = args[i + 1]
        del args[i:i + 2]
    src = args[0] if args else "-"
    text = sys.stdin.read() if src == "-" else open(src, encoding="utf-8").read()
    doc = parse(text)

    if out_dir is None:
        print(json.dumps(doc, indent=2))
        return

    # One file per recipe, named by its id -- which is what the app loads. A
    # document holding four recipes becomes four bundled files, because the app
    # has no concept of "page 3 of a PDF".
    os.makedirs(out_dir, exist_ok=True)
    for recipe in doc["recipes"]:
        path = os.path.join(out_dir, f"{recipe['id']}.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(recipe, fh, indent=1, ensure_ascii=False)
            fh.write("\n")
        warn = f"  ({len(recipe['warnings'])} warning(s))" if recipe["warnings"] else ""
        print(f"wrote {path}{warn}")
    for recipe in doc["recipes"]:
        for w in recipe["warnings"]:
            print(f"  ! {recipe['id']}: {w}")


if __name__ == "__main__":
    main()
