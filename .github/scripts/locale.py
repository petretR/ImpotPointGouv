#!/usr/bin/env python3
"""Keep Locale_frFR.lua tidy and complete.

  python3 .github/scripts/locale.py           rewrite Locale_frFR.lua: one section per source file, keys sorted
  python3 .github/scripts/locale.py --check   fail if the file is not in that order, or if a Tr("...") string
                                              in the code has no French line

Each English key goes in the section of the first file (toc order) that uses it, so two pull requests
touching different files add their lines in different places. Keys no file uses go under "Unused".
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCALE = ROOT / "Locale_frFR.lua"
HEADER = '-- ImpotPointGouv: French strings. The English text is the key; one section per file that uses it.\n' \
         '-- Keep the order with: python3 .github/scripts/locale.py\nlocal _, ns = ...\nns.AddLocale("frFR", {\n'
FOOTER = "})\n"

LUA_STR = r'"(?:[^"\\\n]|\\.)*"'
ENTRY = re.compile(r'^\s*\[(' + LUA_STR + r')\]\s*=\s*(' + LUA_STR + r'),?\s*$')
TR_CALL = re.compile(r'\bTr\(\s*(' + LUA_STR + r')\s*\)')
LITERAL = re.compile(LUA_STR)


def toc_files():
    files = []
    for line in (ROOT / "ImpotPointGouv.toc").read_text(encoding="utf-8").splitlines():
        line = line.strip().replace("\\", "/")
        if line.endswith(".lua") and not line.startswith("#") and not line.startswith("libs/") \
                and not line.startswith("Locale"):
            files.append(line)
    return files


def read_entries():
    entries, problems = {}, []
    for n, line in enumerate(LOCALE.read_text(encoding="utf-8").splitlines(), 1):
        m = ENTRY.match(line)
        if m:
            key, value = m.group(1), m.group(2)
            if key in entries and entries[key] != value:
                problems.append(f"line {n}: {key} translated twice, differently")
            entries.setdefault(key, value)
        elif line.strip().startswith('["'):
            problems.append(f"line {n}: not understood: {line.strip()}")
    return entries, problems


def build(entries):
    files = toc_files()
    sources = {f: (ROOT / f).read_text(encoding="utf-8") for f in files if (ROOT / f).exists()}
    literals = {f: set(LITERAL.findall(src)) for f, src in sources.items()}
    sections = {f: [] for f in files}
    unused = []
    for key in entries:
        home = next((f for f in files if key in literals.get(f, ())), None)
        (sections[home] if home else unused).append(key)
    out = [HEADER]
    first = True
    for name, keys in [(f, sections[f]) for f in files] + [("Unused", unused)]:
        if not keys:
            continue
        if not first:
            out.append("\n")
        first = False
        out.append(f"    -- {name}\n")
        for key in sorted(keys, key=lambda k: (k.lower(), k)):
            out.append(f"    [{key}] = {entries[key]},\n")
    out.append(FOOTER)
    return "".join(out), sources


def missing(entries, sources):
    gaps = []
    for f, src in sources.items():
        for key in sorted(set(TR_CALL.findall(src))):
            if key not in entries:
                gaps.append(f"{f}: {key}")
    return gaps


def main():
    entries, problems = read_entries()
    text, sources = build(entries)
    if "--check" not in sys.argv:
        LOCALE.write_text(text, encoding="utf-8")
        print(f"Locale_frFR.lua rewritten: {len(entries)} strings.")
        for p in problems:
            print("warning:", p)
        return 0
    ok = True
    for p in problems:
        print("error:", p)
        ok = False
    if LOCALE.read_text(encoding="utf-8") != text:
        print("error: Locale_frFR.lua is not in order. Run: python3 .github/scripts/locale.py")
        ok = False
    gaps = missing(entries, sources)
    if gaps:
        print(f"error: {len(gaps)} Tr() strings have no French line in Locale_frFR.lua:")
        for g in gaps:
            print("  " + g)
        ok = False
    if ok:
        print(f"Locale_frFR.lua: {len(entries)} strings, in order, nothing missing.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
