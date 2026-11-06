#!/usr/bin/env python3
"""Render an authored recipe to a PDF in the layout the importer expects.

    python3 -I scripts/make_recipe_pdf.py docs/authored/<name>.json [-o out.pdf]

This is the other half of Brandon's pipeline. He described it as "I have claude
create the pdf and drop to you to add", so the PDF is the handover format: he
reads it, says what to change, and only once he is happy does it get imported
into KitchenAid/Resources/Recipes.

The layout is not decorative. `pdftotext -layout` reconstructs columns from the
x positions used here, and `scripts/import_recipe.py` reads those columns, so
the gutters below are load-bearing: the quantity column and the ingredient
column must stay far enough apart that the extracted text separates them by two
or more spaces. Changing the x positions can silently change how a recipe
parses, which is why every PDF this script writes is round-tripped through the
importer in the same breath.

The source JSON is the thing to edit, never the PDF and never the imported
file. Shape:

    {
      "title": "...", "description": "...",
      "yieldText": "6 cups (serves 4)",
      "activeTime": "About 35 minutes", "totalTime": "About 1 hour 25 minutes",
      "components": [{"name": "...", "lines": [["1 1/2 cups", "flour, sifted"]]}],
      "steps": [{"title": "Boil the potatoes", "minutes": "20", "body": "..."}],
      "notes": ["..."]
    }
"""

import json
import os
import sys
import textwrap

from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas

PAGE_W, PAGE_H = letter
LEFT = 54.0
RIGHT = PAGE_W - 54.0

# The two ingredient columns. The gap has to survive text extraction as two or
# more spaces, or the importer reads the quantity and the name as one cell.
QTY_X = 72.0
NAME_X = 198.0

# The Makes / Active / Total row.
META_X = (LEFT + 4, 250.0, 410.0)

STEP_NUM_X = LEFT + 4
STEP_TEXT_X = LEFT + 26


def wrap(text, width):
    return textwrap.wrap(" ".join(text.split()), width=width) or [""]


class RecipeCanvas:
    def __init__(self, path, title):
        self.c = canvas.Canvas(path, pagesize=letter)
        self.doc_title = title
        self.page = 1
        self.y = PAGE_H - 72.0

    # --- page plumbing ---------------------------------------------------
    def room(self, needed):
        """Break the page when `needed` points would run into the footer."""
        if self.y - needed < 92.0:
            self.footer()
            self.c.showPage()
            self.page += 1
            self.y = PAGE_H - 72.0

    def footer(self):
        self.c.setFont("Helvetica", 8)
        self.c.setFillGray(0.35)
        self.c.drawString(LEFT, 56.0, self.doc_title)
        # The importer splits pages on this footer, so the wide gutter before
        # "Page N" matters as much as the words do.
        self.c.drawRightString(RIGHT, 56.0, f"Page {self.page}")
        self.c.setFillGray(0.0)

    def finish(self):
        self.footer()
        self.c.save()

    # --- blocks ----------------------------------------------------------
    def title(self, text, subtitle):
        self.c.setFont("Helvetica-Bold", 19)
        for i, line in enumerate(wrap(text, 46)):
            self.c.drawString(LEFT, self.y, line)
            self.y -= 23 if i == 0 else 21
        if subtitle:
            self.c.setFont("Helvetica", 10)
            self.c.setFillGray(0.25)
            for line in wrap(subtitle, 96):
                self.y -= 2
                self.c.drawString(LEFT, self.y, line)
                self.y -= 13
            self.c.setFillGray(0.0)
        self.y -= 16

    def meta(self, yield_text, active, total):
        """Makes / Active time / Total time, as one two-row table."""
        self.c.setFont("Helvetica-Bold", 8.5)
        self.c.setFillGray(0.3)
        for x, label in zip(META_X, ("Makes", "Active time", "Total time")):
            self.c.drawString(x, self.y, label)
        self.c.setFillGray(0.0)
        self.y -= 14
        self.c.setFont("Helvetica", 10)
        for x, value in zip(META_X, (yield_text, active, total)):
            if value:
                self.c.drawString(x, self.y, value)
        self.y -= 26

    def heading(self, text):
        self.room(40)
        self.c.setFont("Helvetica-Bold", 13)
        self.c.drawString(LEFT, self.y, text)
        self.y -= 18

    def group(self, text):
        self.room(32)
        self.c.setFont("Helvetica-Bold", 10.5)
        self.c.drawString(LEFT, self.y, text)
        self.y -= 15

    def ingredient(self, qty, name):
        self.room(22)
        self.c.setFont("Helvetica", 10)
        self.c.drawString(QTY_X, self.y, qty)
        lines = wrap(name, 62)
        self.c.drawString(NAME_X, self.y, lines[0])
        self.y -= 14
        for cont in lines[1:]:
            self.room(18)
            self.c.drawString(NAME_X, self.y, cont)
            self.y -= 14
        self.y -= 3

    def step(self, number, title, minutes, body):
        self.room(40)
        self.c.setFont("Helvetica", 10)
        self.c.drawString(STEP_NUM_X, self.y, f"{number}.")
        # "Title (20 min). Body" is the shape the importer reads a step title
        # and its duration out of.
        head = title or ""
        if minutes:
            head = f"{head} ({minutes} min)" if head else f"({minutes} min)"
        text = f"{head}. {body}" if head else body
        for i, line in enumerate(wrap(text, 92)):
            if i:
                self.room(18)
            self.c.drawString(STEP_TEXT_X, self.y, line)
            self.y -= 13
        self.y -= 5

    def note(self, text):
        self.room(30)
        self.c.setFont("Helvetica", 9.5)
        self.c.drawString(STEP_NUM_X, self.y, "•")
        for i, line in enumerate(wrap(text, 98)):
            if i:
                self.room(16)
            self.c.drawString(STEP_TEXT_X - 8, self.y, line)
            self.y -= 12.5
        self.y -= 4


def render(recipe, out_path):
    page = RecipeCanvas(out_path, recipe["title"])
    page.title(recipe["title"], recipe.get("description", ""))
    page.meta(recipe.get("yieldText", ""),
              recipe.get("activeTime", ""),
              recipe.get("totalTime", ""))

    page.heading("Ingredients")
    for component in recipe.get("components", []):
        if component.get("name"):
            page.group(component["name"])
        for qty, name in component.get("lines", []):
            page.ingredient(qty, name)
    page.y -= 8

    page.heading("Instructions")
    for i, step in enumerate(recipe.get("steps", []), 1):
        page.step(i, step.get("title", ""), step.get("minutes", ""), step["body"])

    notes = recipe.get("notes", [])
    if notes:
        page.y -= 6
        page.heading("Notes")
        for note in notes:
            page.note(note)

    page.finish()
    return out_path


def main():
    args = list(sys.argv[1:])
    out = None
    if "-o" in args:
        i = args.index("-o")
        out = args[i + 1]
        del args[i:i + 2]
    if not args:
        print(__doc__)
        sys.exit(2)
    src = args[0]
    with open(src, encoding="utf-8") as fh:
        recipe = json.load(fh)
    if out is None:
        stem = os.path.splitext(os.path.basename(src))[0]
        out = os.path.join(os.path.dirname(src) or ".", stem + ".pdf")
    render(recipe, out)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
