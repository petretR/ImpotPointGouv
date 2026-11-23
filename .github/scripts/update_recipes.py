#!/usr/bin/env python3
"""Update DataRecipes.lua from ForeverMaster's recipe data (foreverchanges.pro).

ForeverMaster is the reference: only its recipes are kept. For each one, this
sets the learn (orange), yellow and grey skill levels and the number of items
made, clears the "estimated" flag, and fills in the product or pattern when
DataRecipes.lua has none. Materials are left alone (the addon reads them from
the game first). Recipes missing from DataRecipes.lua are added at the end of
the table; recipes ForeverMaster doesn't have (moved, removed or never in
Forever) are deleted.

Usage:
    python3 .github/scripts/update_recipes.py [ForeverMaster.zip | Recipes.lua]

With no argument, the latest ForeverMaster.zip is downloaded.
Lives under .github so it is not shipped in the release zip.
"""
import io
import re
import sys
import urllib.request
import zipfile
from pathlib import Path

URL = "https://downloads.foreverchanges.pro/addon/latest/ForeverMaster.zip"
MEMBER = "ForeverMaster/Data/Recipes.lua"
DATA = Path(__file__).resolve().parents[2] / "DataRecipes.lua"
PROF = {"First Aid": 1, "Blacksmithing": 2, "Leatherworking": 3, "Alchemy": 4, "Cooking": 6,
        "Tailoring": 8, "Engineering": 9, "Enchanting": 10}
ENTRY = re.compile(r"^    \[(\d+)\] = \{ (.*) \},$")


def read_source(arg):
    if arg and arg.endswith(".lua"):
        return Path(arg).read_text(encoding="utf-8")
    raw = Path(arg).read_bytes() if arg else urllib.request.urlopen(
        urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"}), timeout=60).read()
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        return z.read(MEMBER).decode("utf-8")


def parse_source(text):
    """{spell: (profCode, learn, yellow, grey, item, count, pattern, mats)}"""
    out = {}
    parts = re.split(r'\n \["([^"]+)"\] = \{', text)
    for i in range(1, len(parts), 2):
        code = PROF.get(parts[i])
        if not code:
            continue
        for m in re.finditer(r'\[(\d+)\]="([^"]*)"', parts[i + 1]):
            f = m.group(2).split("|")
            if len(f) < 9 or not (f[0] and f[1] and f[3]):
                continue
            mats = []
            for r in filter(None, f[8].split(",")):
                rid, _, n = r.partition(":")
                mats += [int(rid), int(n or 1)]
            out[int(m.group(1))] = (code, int(f[0]), int(f[1]), int(f[3]), int(f[4] or 0),
                                    int(f[5] or 1), int(f[6] or 0), mats)
    return out


def main():
    src = parse_source(read_source(sys.argv[1] if len(sys.argv) > 1 else None))
    if len(src) < 1000:
        sys.exit(f"only {len(src)} recipes read from ForeverMaster: format changed?")
    lines = DATA.read_text(encoding="utf-8").split("\n")
    seen, changed, end, dropped = set(), 0, None, []
    for i, line in enumerate(lines):
        m = ENTRY.match(line)
        if not m:
            if end is None and (seen or dropped) and line == "}":
                end = i
            continue
        spell = int(m.group(1))
        s = src.get(spell)
        t = [int(x) for x in m.group(2).split(",") if x.strip()]
        if not s or s[0] != t[1]:
            dropped.append(i)  # absente de ForeverMaster, ou d'un autre métier : remplacée plus bas
            continue
        seen.add(spell)
        code, learn, yellow, grey, item, count, pattern, _ = s
        new = t[:]
        new[2:6] = [learn, yellow, grey, count]
        new[7] = 0
        if not new[0] and item:
            new[0] = item
        if not new[6] and pattern:
            new[6] = pattern
        if new != t:
            lines[i] = f"    [{spell}] = {{ {','.join(map(str, new))} }},"
            changed += 1
    added = [s for s in sorted(src) if s not in seen]
    for i in reversed(dropped):
        del lines[i]
        if i < end:
            end -= 1
    if added:
        new_lines = ["    -- Recettes de ForeverMaster absentes des données d'origine."]
        for spell in added:
            code, learn, yellow, grey, item, count, pattern, mats = src[spell]
            vals = [item, code, learn, yellow, grey, count, pattern, 0] + mats
            new_lines.append(f"    [{spell}] = {{ {','.join(map(str, vals))} }},")
        lines[end:end] = new_lines
    text = "\n".join(lines)
    text = text.replace(
        "-- Généré à partir d'AtlasLoot (édition Forever) : seuils orange / jaune / gris, composants, patron.",
        "-- Généré à partir d'AtlasLoot (édition Forever) : composants, patron.\n"
        "-- Seuils et nombre produit : ForeverMaster (foreverchanges.pro), via .github/scripts/update_recipes.py.")
    DATA.write_text(text, encoding="utf-8")
    print(f"{len(src)} ForeverMaster recipes: {changed} updated, {len(added)} added, "
          f"{len(dropped)} removed (not in ForeverMaster, or another profession there: re-added as that one)")


if __name__ == "__main__":
    main()
