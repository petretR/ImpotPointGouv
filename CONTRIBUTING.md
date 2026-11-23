# Contributing

Two people work on this addon. Everything in the repository is written in English: code comments, commit messages, pull requests, the changelog and docs. Player-facing strings are English in the code and translated in `Locale_frFR.lua`.

## Branches and pull requests

- `main` is always releasable. Nobody pushes to it directly: every change goes through a pull request, and the other person reviews it before it is merged.
- One branch per topic, kept small and short-lived: `feat/<topic>`, `fix/<topic>`, `chore/<topic>`, `docs/<topic>`. Start from an up-to-date `main`.
- Before opening the pull request, rebase on `main` (`git fetch origin && git rebase origin/main`) and run the tests (see below).
- Pull requests are merged with **Squash and merge**: one commit per pull request on `main`, titled like the pull request. In the merge dialog, keep the extended description short and delete any `Co-authored-by:` line added by tools: the commit must only credit the two maintainers.
- A pull request description says what changes, why, and how to test it in game. GitHub fills it from `.github/pull_request_template.md`.

## Every pull request

1. Adds its lines to `CHANGELOG.md` under **Unreleased** (`Added`, `Changed`, `Fixed` or `Removed`), written for players. Changes players cannot see (CI, docs, refactoring) may skip it.
2. Does **not** change the version (`## Version:` in the toc, `ns.version` in `Core.lua`). Only release pull requests do.
3. Passes CI: Lua 5.1 syntax check, every toc file exists, smoke tests in English and French.
4. Sends new player-facing strings through `Tr("...")` and adds their French line to `Locale_frFR.lua` (anywhere), then runs `python3 .github/scripts/locale.py` to move each line into the section of the file that uses it. CI fails if a `Tr()` string has no French line or the file is out of order. Strings that are not text (colour codes, paths, slash commands) stay out of `Tr()`.
5. Keeps saved data compatible, or migrates it on load. Mention any change to `ImpotPointGouvDB` in the description.

## Versions and releases

Versions follow `MAJOR.MINOR.PATCH`:

- **MAJOR**: saved data that older versions cannot read, or a redesign that changes how the addon is used.
- **MINOR**: new features.
- **PATCH**: fixes only.

A release is its own pull request, `release/x.y.z`, opened when we agree a set of changes has been tested in game (roughly once a week):

1. Set the version in `ImpotPointGouv.toc` and `Core.lua`.
2. Rename `## [Unreleased]` to `## [x.y.z] - YYYY-MM-DD` in `CHANGELOG.md` and add a new empty Unreleased section above it.
3. Merge. The release workflow publishes `ImpotPointGouv.zip` with the changelog section as release notes.

An urgent fix (the game changed an API, a crash) gets a `fix/` pull request followed right away by a patch release.

## Tests

```
lua5.1 tests/run.lua
IPG_LOCALE=frFR lua5.1 tests/run.lua
```

`tests/mock.lua` stubs the game API; `tests/run.lua` loads every toc file and checks the main features (route to 300 in every profession, every tab, the price window, mail collection). Add a check when you fix a bug that a test could have caught. Then test in game: CI cannot see the UI.

## Code layout

See the table in `README.md`. Files share the `ns` table (`local _, ns = ...`); load order is the toc.
