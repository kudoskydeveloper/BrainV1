#!/usr/bin/env python3
"""Builds Resources/foods.sqlite from USDA FoodData Central (SR Legacy + Foundation Foods, public domain).

    python3 -I Tools/build-foods.py Tools/data/FoodData_Central_sr_legacy_food_json_*.json Tools/data/FoodData_Central_foundation_food_json_*.json

Per food: nutrients per 100 g (kcal, protein, fat, saturated fat, carbs, sugars, fiber, salt) and household portions in grams
("1 cup, chopped" = 30 g). An FTS5 index over the description finds candidates for an ingredient; the app (Recepty) then lets
the model pick the right one.
"""
import json, os, sqlite3, sys

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "foods.sqlite")

def nutrients(food):
    by = {}
    for n in food.get("foodNutrients", []):
        num, amt = n.get("nutrient", {}).get("number"), n.get("amount")
        if num and amt is not None and num not in by:
            by[num] = float(amt)
    kcal = by.get("208")
    if kcal is None: kcal = by.get("958") or by.get("957")       # Foundation: Atwater specific / general
    if kcal is None and "268" in by: kcal = by["268"] / 4.184     # kJ
    if kcal is None:
        p, f, c = by.get("203"), by.get("204"), by.get("205")
        if p is not None and f is not None and c is not None: kcal = 4 * p + 9 * f + 4 * c
    if kcal is None: return None
    sodium = by.get("307")
    return dict(kcal=round(kcal, 1), protein=by.get("203", 0.0), fat=by.get("204", by.get("298", 0.0)), sat_fat=by.get("606"),
                carbs=by.get("205", by.get("205.2", 0.0)), sugars=by.get("269", by.get("269.3")), fiber=by.get("291"),
                salt=round(sodium * 2.5 / 1000, 3) if sodium is not None else None)

def portions(food):
    out = []
    for p in food.get("foodPortions", []):
        g = p.get("gramWeight")
        if not g: continue
        unit = (p.get("measureUnit") or {}).get("name") or ""
        if unit in ("undetermined", "RACC"): unit = ""
        amount = p.get("amount") or p.get("value") or 1
        label = " ".join(x for x in [f"{amount:g}", unit, p.get("modifier") or p.get("portionDescription") or ""] if x).strip()
        out.append((label, round(float(g), 2)))
    return out

def main(paths):
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    if os.path.exists(OUT): os.remove(OUT)
    db = sqlite3.connect(OUT)
    db.executescript("""
        CREATE TABLE foods(id INTEGER PRIMARY KEY, source TEXT NOT NULL, name TEXT NOT NULL, category TEXT,
            kcal REAL NOT NULL, protein REAL, fat REAL, sat_fat REAL, carbs REAL, sugars REAL, fiber REAL, salt REAL);
        CREATE TABLE portions(food_id INTEGER NOT NULL, label TEXT NOT NULL, grams REAL NOT NULL);
        CREATE INDEX portions_food ON portions(food_id);
        CREATE VIRTUAL TABLE foods_fts USING fts5(name, content='foods', content_rowid='id', tokenize='porter unicode61');
    """)
    n = 0
    for path in paths:
        data = json.load(open(path))
        key, src = ("FoundationFoods", "foundation") if "FoundationFoods" in data else ("SRLegacyFoods", "sr")
        for f in data[key]:
            nu = nutrients(f)
            if not nu: continue
            cat = (f.get("foodCategory") or {}).get("description")
            db.execute("INSERT OR REPLACE INTO foods VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                       (f["fdcId"], src, f["description"], cat, nu["kcal"], nu["protein"], nu["fat"], nu["sat_fat"], nu["carbs"], nu["sugars"], nu["fiber"], nu["salt"]))
            db.executemany("INSERT INTO portions VALUES(?,?,?)", [(f["fdcId"], l, g) for l, g in portions(f)])
            n += 1
    db.execute("INSERT INTO foods_fts(foods_fts) VALUES('rebuild')")
    db.commit()
    db.execute("VACUUM")
    db.close()
    print(f"{n} foods -> {os.path.normpath(OUT)} ({os.path.getsize(OUT) // 1024} kB)")

if __name__ == "__main__":
    main(sys.argv[1:])
