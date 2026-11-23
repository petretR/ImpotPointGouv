<!-- One topic per pull request. Title: what it does, in English (it becomes the commit title on main). -->

## What changes
<!-- What the player sees, then how it works if it matters for review. -->

## Saved data
<!-- New or changed fields in ImpotPointGouvDB, and how old data is migrated. "None" if nothing. -->

## How to test
<!-- In game: the steps to check it. Plus: CI passes, `lua5.1 tests/run.lua`. -->

## Checklist
- [ ] Line(s) in `CHANGELOG.md` under Unreleased (player-facing changes)
- [ ] No version change (only release pull requests change it)
- [ ] New strings go through `Tr()`, have a French line, and `python3 .github/scripts/locale.py` was run
- [ ] Comments, commits and this description in English
