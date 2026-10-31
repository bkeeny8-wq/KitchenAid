#!/usr/bin/env python3
"""Build the ingredient catalogue the app ships with.

    python3 -I scripts/build_catalogue.py

Writes KitchenAid/Resources/ingredients.json, which the app loads on first
launch so that adding something to the pantry or the shopping list is PICKING
rather than TYPING. Nobody populates a few hundred ingredients by hand, and an
app that asks you to is an app you stop opening.

Each entry carries what the rest of the app actually needs:

  name       the canonical name. Aggregation and pantry matching key on this,
             never on a recipe's display string ("grated Parmesan").
  aisle      the store section, so a shopping list is ordered the way you walk.
  dimension  mass | volume | count. Decides what can be ADDED to what, and is
             the reason "16 oz steak" never becomes a volume.
  unit       the unit to default to when you add this by hand.
  staple     true for things tracked as present/absent with no quantity.
             Counting teaspoons of salt is work no one does, and a list that
             keeps asking for salt is a list you stop reading.
  aliases    other names the same purchase goes by, so "green onion" and
             "scallion" are one row and one pantry item.

Item syntax below: "name|dimension|unit|alias,alias". Dimension and unit fall
back to the aisle default; the aliases field is optional.
"""

import json
import os

# (dimension, unit) assumed for an aisle when an item does not say otherwise.
AISLE_DEFAULTS = {
    "Produce":     ("count", "each"),
    "Butcher":     ("mass", "lb"),
    "Seafood":     ("mass", "lb"),
    "Dairy":       ("mass", "oz"),
    "Bakery":      ("count", "each"),
    "Dry goods":   ("mass", "oz"),
    "Canned":      ("count", "can"),
    "Condiments":  ("volume", "tbsp"),
    "Spices":      ("volume", "tsp"),
    "Baking":      ("mass", "oz"),
    "Nuts":        ("mass", "oz"),
    "Frozen":      ("mass", "oz"),
    "Beverages":   ("volume", "ml"),
}

# Tracked as present/absent, no quantity. Everything in Spices is a staple;
# these are the ones outside that aisle.
EXTRA_STAPLES = {
    "olive oil", "extra virgin olive oil", "vegetable oil", "canola oil",
    "all-purpose flour", "granulated sugar", "brown sugar", "baking powder",
    "baking soda", "cornstarch", "vanilla extract", "honey", "soy sauce",
    "dijon mustard", "mayonnaise", "ketchup", "balsamic vinegar",
    "red wine vinegar", "white wine vinegar", "apple cider vinegar",
    "distilled white vinegar", "rice vinegar", "worcestershire sauce",
}

CATALOGUE = {
    "Produce": [
        "onion", "yellow onion", "red onion", "white onion", "sweet onion",
        "shallot", "scallion|count|each|green onion,spring onion",
        "garlic|count|clove|garlic cloves", "ginger|mass|oz|fresh ginger",
        "carrot", "celery|count|stalk", "celery root|count|each|celeriac",
        "potato", "russet potato", "yukon gold potato", "red potato",
        "sweet potato", "tomato", "cherry tomato|mass|oz",
        "roma tomato|count|each|plum tomato", "beefsteak tomato",
        "cucumber", "english cucumber", "bell pepper", "red bell pepper",
        "green bell pepper", "yellow bell pepper",
        "jalapeno|count|each|jalapeño", "serrano pepper", "poblano pepper",
        "habanero", "lettuce|count|head", "romaine|count|head",
        "iceberg lettuce|count|head", "butter lettuce|count|head",
        "baby spinach|mass|oz|spinach", "arugula|mass|oz|rocket",
        "kale|count|bunch", "swiss chard|count|bunch", "collard greens|count|bunch",
        "cabbage|count|head", "red cabbage|count|head", "napa cabbage|count|head",
        "broccoli|count|head", "broccolini|count|bunch", "cauliflower|count|head",
        "brussels sprouts|mass|oz", "green beans|mass|oz|haricot vert",
        "asparagus|count|bunch", "zucchini|count|each|courgette",
        "yellow squash", "butternut squash", "acorn squash", "spaghetti squash",
        "eggplant|count|each|aubergine", "mushroom|mass|oz|mushrooms",
        "cremini mushroom|mass|oz|baby bella", "shiitake mushroom|mass|oz",
        "portobello mushroom|count|each", "oyster mushroom|mass|oz",
        "corn|count|ear|corn on the cob", "peas|mass|oz",
        "snap peas|mass|oz|sugar snap peas", "snow peas|mass|oz",
        "leek", "fennel|count|bulb", "radish|count|bunch", "beet", "turnip",
        "parsnip", "rutabaga", "avocado",
        "lemon", "lime", "orange", "grapefruit", "clementine",
        "apple", "granny smith apple", "pear", "banana",
        "strawberry|mass|oz|strawberries", "blueberry|mass|oz|blueberries",
        "raspberry|mass|oz|raspberries", "blackberry|mass|oz|blackberries",
        "grape|mass|oz|grapes", "pineapple", "mango", "peach", "nectarine",
        "plum", "cherry|mass|oz|cherries", "watermelon", "cantaloupe",
        "honeydew", "pomegranate", "fig|count|each|figs",
        # herbs
        "parsley|count|bunch|flat-leaf parsley,italian parsley",
        # "coriander" is deliberately NOT an alias here. In British usage it is
        # this herb; in American usage it is the dried seed, which is its own
        # entry under Spices. One word, two different purchases -- so only the
        # unambiguous "fresh coriander" maps to the herb.
        "cilantro|count|bunch|fresh coriander",
        "basil|count|bunch|fresh basil", "thyme|count|bunch|fresh thyme",
        "rosemary|count|bunch|fresh rosemary", "sage|count|bunch|fresh sage",
        "oregano|count|bunch|fresh oregano", "mint|count|bunch|fresh mint",
        "dill|count|bunch|fresh dill", "chives|volume|tbsp|fresh chives",
        "tarragon|count|bunch|fresh tarragon", "marjoram|count|bunch",
    ],
    "Butcher": [
        "ny strip steak|mass|oz|new york strip,strip steak",
        "ribeye|mass|oz|ribeye steak", "filet mignon|mass|oz|beef tenderloin",
        "sirloin|mass|oz|top sirloin", "flank steak|mass|oz",
        "skirt steak|mass|oz", "hanger steak|mass|oz", "flat iron steak|mass|oz",
        "chuck roast|mass|lb", "brisket|mass|lb", "short ribs|mass|lb",
        "beef stew meat|mass|lb", "ground beef|mass|lb|hamburger",
        "beef shank|mass|lb", "oxtail|mass|lb",
        "pork chop|count|each", "pork tenderloin|mass|lb",
        "pork shoulder|mass|lb|pork butt", "pork belly|mass|lb",
        "ground pork|mass|lb", "bacon|mass|oz", "pancetta|mass|oz",
        "prosciutto|mass|oz", "ham|mass|lb", "sausage|mass|lb",
        "italian sausage|mass|lb", "chorizo|mass|oz", "kielbasa|mass|oz",
        "chicken breast|count|each|boneless skinless chicken breast",
        "chicken thigh|count|each|chicken thighs",
        "chicken drumstick|count|each", "chicken wings|mass|lb",
        "whole chicken|count|each", "ground chicken|mass|lb",
        "turkey breast|mass|lb", "ground turkey|mass|lb",
        "lamb chop|count|each", "leg of lamb|mass|lb", "lamb shoulder|mass|lb",
        "ground lamb|mass|lb", "duck breast|count|each", "veal|mass|lb",
    ],
    "Seafood": [
        "salmon|mass|oz|salmon fillet", "tuna|mass|oz|tuna steak",
        "cod|mass|oz", "halibut|mass|oz", "sea bass|mass|oz",
        "snapper|mass|oz", "trout|mass|oz", "mahi mahi|mass|oz",
        "swordfish|mass|oz", "sole|mass|oz", "branzino|count|each",
        "shrimp|mass|oz|prawns", "scallops|mass|oz", "mussels|mass|lb",
        "clams|mass|lb", "oysters|count|each", "crab|mass|lb",
        "lobster|count|each", "lobster tail|count|each", "calamari|mass|oz|squid",
        "anchovy|count|each|anchovies", "smoked salmon|mass|oz|lox",
    ],
    "Dairy": [
        "butter|volume|tbsp|unsalted butter,salted butter",
        "milk|volume|ml|whole milk", "heavy cream|volume|ml|heavy whipping cream",
        "half and half|volume|ml", "buttermilk|volume|ml",
        "sour cream|volume|tbsp", "creme fraiche|volume|tbsp|crème fraîche",
        "yogurt|volume|ml", "greek yogurt|volume|ml",
        "cream cheese|mass|oz", "mascarpone|mass|oz", "ricotta|mass|oz",
        "cottage cheese|mass|oz",
        "parmesan|volume|tbsp|parmigiano reggiano,grated parmesan",
        "pecorino|volume|tbsp|pecorino romano", "gruyere|mass|oz|gruyère",
        "cheddar|mass|oz|sharp cheddar", "mozzarella|mass|oz",
        "fresh mozzarella|mass|oz", "burrata|mass|oz", "feta|mass|oz",
        "goat cheese|mass|oz|chevre", "blue cheese|mass|oz",
        "gorgonzola|mass|oz", "brie|mass|oz", "swiss cheese|mass|oz",
        "provolone|mass|oz", "monterey jack|mass|oz", "manchego|mass|oz",
        "eggs|count|each|egg", "egg whites|count|each", "egg yolks|count|each",
    ],
    "Bakery": [
        "baguette|count|each|french bread", "sourdough|count|loaf",
        "ciabatta|count|loaf", "country loaf|count|loaf",
        "sandwich bread|count|loaf|white bread", "whole wheat bread|count|loaf",
        "rye bread|count|loaf", "brioche|count|loaf",
        "english muffin|count|each", "bagel|count|each", "pita|count|each",
        "naan|count|each", "flour tortilla|count|each|tortilla",
        "corn tortilla|count|each", "hamburger bun|count|each",
        "hot dog bun|count|each", "croissant|count|each",
        "breadcrumbs|volume|cup", "panko|volume|cup|panko breadcrumbs",
        "puff pastry|count|sheet", "pizza dough|mass|oz",
    ],
    "Dry goods": [
        "all-purpose flour|volume|cup|plain flour,flour",
        "bread flour|volume|cup", "cake flour|volume|cup",
        "whole wheat flour|volume|cup", "semolina|volume|cup",
        "cornmeal|volume|cup", "polenta|volume|cup",
        "rice|volume|cup|white rice", "jasmine rice|volume|cup",
        "basmati rice|volume|cup", "brown rice|volume|cup",
        "arborio rice|volume|cup", "wild rice|volume|cup",
        "quinoa|volume|cup", "couscous|volume|cup", "farro|volume|cup",
        "barley|volume|cup|pearl barley", "bulgur|volume|cup",
        "lentils|volume|cup", "red lentils|volume|cup",
        "black beans|volume|cup", "chickpeas|volume|cup|garbanzo beans",
        "cannellini beans|volume|cup", "kidney beans|volume|cup",
        "pinto beans|volume|cup", "split peas|volume|cup",
        "pasta|mass|oz", "spaghetti|mass|oz", "penne|mass|oz",
        "rigatoni|mass|oz", "fusilli|mass|oz", "orzo|volume|cup",
        "linguine|mass|oz", "fettuccine|mass|oz", "bucatini|mass|oz",
        "lasagna noodles|mass|oz", "egg noodles|mass|oz",
        "ramen noodles|count|package", "rice noodles|mass|oz",
        "soba noodles|mass|oz", "udon|mass|oz",
        "oats|volume|cup|rolled oats", "steel-cut oats|volume|cup",
        "gelatin|count|packet", "cornflakes|volume|cup",
    ],
    "Canned": [
        "canned tomatoes|count|can|tinned tomatoes",
        "crushed tomatoes|count|can", "diced tomatoes|count|can",
        "whole peeled tomatoes|count|can", "san marzano tomatoes|count|can",
        "tomato paste|volume|tbsp", "tomato sauce|count|can",
        "coconut milk|count|can", "coconut cream|count|can",
        "chicken stock|volume|ml|chicken broth",
        "beef stock|volume|ml|beef broth",
        "vegetable stock|volume|ml|vegetable broth",
        "tuna in oil|count|can|canned tuna", "sardines|count|can",
        "canned corn|count|can", "canned chickpeas|count|can",
        "canned black beans|count|can", "pumpkin puree|count|can",
        "evaporated milk|count|can", "condensed milk|count|can",
        "roasted red peppers|count|jar", "artichoke hearts|count|jar",
        "olives|volume|cup", "kalamata olives|volume|cup",
        "green olives|volume|cup", "capers|volume|tbsp",
        "sun-dried tomatoes|volume|cup", "anchovy paste|volume|tsp",
    ],
    "Condiments": [
        "olive oil|volume|tbsp", "extra virgin olive oil|volume|tbsp",
        "vegetable oil|volume|tbsp", "canola oil|volume|tbsp",
        "grapeseed oil|volume|tbsp", "sesame oil|volume|tsp",
        "peanut oil|volume|tbsp", "coconut oil|volume|tbsp",
        "avocado oil|volume|tbsp", "chili oil|volume|tsp",
        "balsamic vinegar|volume|tbsp", "red wine vinegar|volume|tbsp",
        "white wine vinegar|volume|tbsp", "apple cider vinegar|volume|tbsp",
        "rice vinegar|volume|tbsp", "sherry vinegar|volume|tbsp",
        "distilled white vinegar|volume|tbsp", "malt vinegar|volume|tbsp",
        "soy sauce|volume|tbsp", "tamari|volume|tbsp",
        "fish sauce|volume|tbsp", "worcestershire sauce|volume|tsp",
        "hot sauce|volume|tsp", "sriracha|volume|tbsp", "tabasco|volume|tsp",
        "gochujang|volume|tbsp", "harissa|volume|tbsp",
        "ketchup|volume|tbsp", "mustard|volume|tbsp",
        "dijon mustard|volume|tbsp|dijon",
        "whole grain mustard|volume|tbsp", "yellow mustard|volume|tbsp",
        "mayonnaise|volume|tbsp|mayo",
        "prepared horseradish|volume|tbsp|horseradish",
        "bbq sauce|volume|tbsp|barbecue sauce", "hoisin sauce|volume|tbsp",
        "oyster sauce|volume|tbsp", "miso paste|volume|tbsp|miso",
        "tahini|volume|tbsp", "peanut butter|volume|tbsp",
        "almond butter|volume|tbsp", "honey|volume|tbsp",
        "maple syrup|volume|tbsp", "molasses|volume|tbsp",
        "jam|volume|tbsp|preserves", "pesto|volume|tbsp",
        "salsa|volume|cup", "relish|volume|tbsp", "pickles|count|each",
    ],
    "Spices": [
        "kosher salt|volume|tsp", "flaky salt|volume|tsp|maldon,flaky sea salt",
        "sea salt|volume|tsp", "table salt|volume|tsp|salt",
        "black pepper|volume|tsp|freshly ground black pepper,pepper",
        "white pepper|volume|tsp",
        "red pepper flakes|volume|tsp|crushed red pepper",
        "cayenne|volume|tsp|cayenne pepper", "paprika|volume|tsp",
        "smoked paprika|volume|tsp", "cumin|volume|tsp|ground cumin",
        "coriander|volume|tsp|ground coriander", "turmeric|volume|tsp",
        "curry powder|volume|tsp", "garam masala|volume|tsp",
        "chili powder|volume|tsp", "ancho chili powder|volume|tsp",
        "chipotle powder|volume|tsp", "cinnamon|volume|tsp|ground cinnamon",
        "nutmeg|volume|tsp|ground nutmeg", "cloves|volume|tsp|ground cloves",
        "allspice|volume|tsp", "cardamom|volume|tsp",
        "ginger powder|volume|tsp|ground ginger",
        "garlic powder|volume|tsp", "onion powder|volume|tsp",
        "mustard powder|volume|tsp|dry mustard",
        "dried oregano|volume|tsp", "dried thyme|volume|tsp",
        "dried basil|volume|tsp", "dried rosemary|volume|tsp",
        "dried dill|volume|tsp", "italian seasoning|volume|tsp",
        "bay leaves|count|each|bay leaf", "fennel seeds|volume|tsp",
        "caraway seeds|volume|tsp", "celery seed|volume|tsp",
        "sesame seeds|volume|tbsp", "poppy seeds|volume|tsp",
        "vanilla extract|volume|tsp", "almond extract|volume|tsp",
        "saffron|volume|tsp", "za'atar|volume|tsp",
        "everything bagel seasoning|volume|tsp", "old bay|volume|tsp",
        "herbes de provence|volume|tsp", "five spice powder|volume|tsp",
    ],
    "Baking": [
        "granulated sugar|volume|cup|sugar,white sugar",
        "brown sugar|volume|cup|light brown sugar",
        "dark brown sugar|volume|cup",
        "powdered sugar|volume|cup|confectioners sugar,icing sugar",
        "turbinado sugar|volume|tbsp|raw sugar",
        "baking powder|volume|tsp", "baking soda|volume|tsp",
        "active dry yeast|count|packet", "instant yeast|volume|tsp",
        "cornstarch|volume|tbsp|corn flour",
        "cocoa powder|volume|cup|unsweetened cocoa powder",
        "dutch process cocoa|volume|cup", "dark chocolate|mass|oz",
        "semisweet chocolate chips|volume|cup|chocolate chips",
        "bittersweet chocolate|mass|oz", "white chocolate|mass|oz",
        "milk chocolate|mass|oz", "almond flour|volume|cup",
        "cream of tartar|volume|tsp", "shortening|volume|cup",
        "sweetened shredded coconut|volume|cup", "marshmallows|volume|cup",
        "sprinkles|volume|tbsp", "food coloring|volume|tsp",
    ],
    "Nuts": [
        "almonds|volume|cup", "sliced almonds|volume|cup",
        "walnuts|volume|cup", "pecans|volume|cup", "cashews|volume|cup",
        "pistachios|volume|cup", "peanuts|volume|cup",
        "pine nuts|volume|tbsp|pignoli", "hazelnuts|volume|cup",
        "macadamia nuts|volume|cup", "sunflower seeds|volume|tbsp",
        "pumpkin seeds|volume|tbsp|pepitas", "chia seeds|volume|tbsp",
        "flax seeds|volume|tbsp|flaxseed", "raisins|volume|cup",
        "dried cranberries|volume|cup", "dates|count|each",
        "dried apricots|volume|cup", "shredded coconut|volume|cup",
    ],
    "Frozen": [
        "frozen peas|mass|oz", "frozen corn|mass|oz",
        "frozen spinach|mass|oz", "frozen berries|mass|oz",
        "frozen broccoli|mass|oz", "frozen edamame|mass|oz",
        "frozen shrimp|mass|oz", "frozen french fries|mass|oz",
        "phyllo dough|count|package", "pie crust|count|each",
        "ice cream|volume|ml", "frozen pizza|count|each",
    ],
    "Beverages": [
        "white wine|volume|ml|dry white wine", "red wine|volume|ml|dry red wine",
        "dry vermouth|volume|ml", "sherry|volume|ml", "marsala|volume|ml",
        "port|volume|ml", "brandy|volume|ml|cognac", "bourbon|volume|ml",
        "whiskey|volume|ml", "rum|volume|ml", "vodka|volume|ml",
        "gin|volume|ml", "tequila|volume|ml", "beer|volume|ml",
        "coffee|volume|cup", "espresso|volume|ml", "tea|count|bag",
        "orange juice|volume|ml", "lemon juice|volume|tbsp",
        "lime juice|volume|tbsp", "apple juice|volume|ml",
        "cranberry juice|volume|ml", "sparkling water|volume|ml",
        "club soda|volume|ml", "tonic water|volume|ml", "cola|volume|ml",
    ],
}


def parse(raw, aisle):
    parts = raw.split("|")
    name = parts[0].strip()
    dim, unit = AISLE_DEFAULTS[aisle]
    if len(parts) > 1 and parts[1].strip():
        dim = parts[1].strip()
    if len(parts) > 2 and parts[2].strip():
        unit = parts[2].strip()
    aliases = []
    if len(parts) > 3 and parts[3].strip():
        aliases = [a.strip() for a in parts[3].split(",") if a.strip()]
    return {
        "name": name,
        "aisle": aisle,
        "dimension": dim,
        "unit": unit,
        "staple": aisle == "Spices" or name in EXTRA_STAPLES,
        "aliases": aliases,
    }


def build():
    items, seen_names, collisions = [], {}, []
    for aisle, raws in CATALOGUE.items():
        for raw in raws:
            item = parse(raw, aisle)
            key = item["name"].lower()
            if key in seen_names:
                collisions.append(f'{item["name"]} in both {seen_names[key]} and {aisle}')
                continue
            seen_names[key] = aisle
            items.append(item)

    # An alias must not collide with a canonical name or another alias, or a
    # lookup becomes ambiguous and silently picks whichever came first.
    alias_owner = {}
    for item in items:
        for a in item["aliases"]:
            k = a.lower()
            if k in seen_names:
                collisions.append(f'alias "{a}" ({item["name"]}) collides with the item of that name')
            elif k in alias_owner:
                collisions.append(f'alias "{a}" claimed by both {alias_owner[k]} and {item["name"]}')
            else:
                alias_owner[k] = item["name"]

    items.sort(key=lambda i: (i["aisle"], i["name"]))
    return items, collisions


def main():
    items, collisions = build()
    if collisions:
        print(f"{len(collisions)} collision(s):")
        for c in collisions:
            print("  !", c)

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "KitchenAid", "Resources", "ingredients.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump({"version": 1, "items": items}, fh, indent=1, ensure_ascii=False)
        fh.write("\n")

    staples = sum(1 for i in items if i["staple"])
    aisles = {}
    for i in items:
        aisles[i["aisle"]] = aisles.get(i["aisle"], 0) + 1
    print(f"\n{len(items)} ingredients, {staples} staples, "
          f"{sum(len(i['aliases']) for i in items)} aliases -> {out}")
    for a in sorted(aisles):
        print(f"  {a:12} {aisles[a]:4}")


if __name__ == "__main__":
    main()
