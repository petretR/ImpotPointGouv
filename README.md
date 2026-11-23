# ImpotPointGouv

WoW Forever addon for routine gold making: track every gold change, watch the right items at the auction house, buy only below your limit, craft what pays, post and mail in a few clicks.
Inspired by TSM and Auctionator, with a clean, minimal interface.

## Installation

1. Download `ImpotPointGouv.zip` from the [latest release](../../releases/latest).
2. Unzip it into `World of Warcraft/_forever_/Interface/AddOns/`.
3. Fully restart the game (`/reload` does not load new files).

Open the main window with the minimap button or `/ipg`. A setup guide shows up on first launch: pick your bank character and your crafter(s), open your professions once, scan the AH once.

## Features

### Overview & history
- Every gold change is recorded and sorted: AH sales and purchases, deposits, vendor, quests, loot, mail, repairs, training, travel.
- Total gold across characters, trading result, stock value, gold-over-time chart.
- Vendor sales keep the item sold (quality, item level, bound or not, AH value at the time), loot is logged with zone and source, and play time is counted per zone and per level. `/ipg sold` shows what you vendored this week and what was worth more at the AH.

### Lists
Ready-made watchlists, each with its finished items and their materials:
- **Consumes & enchants**: flasks, elixirs, potions, food, weapon oils and stones, armor kits, enchants used by each spec.
- **Daily cooldowns**: transmutes, Mooncloth, Refined Deeprock Salt, with the gain of each one and which character has it ready.
- **Pre-BiS crafts**: cloth, leather, mail, plate, weapons, cloaks/trinkets/relics, from the pre-raid BiS lists of every spec.
- **Profession leveling**: two views. **Shopping list**: what to buy to reach 300, with quantities and the total cost now vs usual. **Best route**: the cheapest, fast path from your current skill to 300, step by step, using every recipe of the profession (trainer, vendor patterns, BoE patterns at the AH, recipes you already know). For each step: crafts needed, the gold balance (negative when it costs, positive when it earns: resale of what you craft − materials − learning cost), and close alternatives with their own cost. Click an alternative to use it instead; "No AH patterns" builds a route without buying patterns.
  - **AH / Merchant / Disenchant** toggles choose how what you craft is resold; with several on, each recipe uses the best. AH is the price minus the 5 % cut (only when 10 or more are listed); disenchanting uses the Classic disenchant table (item levels 5–65).
  - A craft that pays for itself counts as free when choosing the route, plus 2 s of your time per craft, so the route stays fast instead of grinding for profit; among equal routes it takes the one that earns more.
  - Skill-up chance follows orange / yellow / green / grey with WoW Forever's skill levels (from ForeverMaster, see `.github/scripts/update_recipes.py`); trainer costs are read when you open a trainer (estimated until then). Cooldown recipes are left out, and a recipe is paid for once.
- **My lists**: your own, right-click any item to add it.

Two views: **By recipe** (each recipe, then its materials, with the net gain per craft) and **Flat list** (each item once, deals first).
For every item: price now, usual price (7-day median), 7-day curve, estimated sales per day, quantity listed, your stock, and a verdict: **BUY** (well under its usual price), **SELL** (above it and you have some), **FARM** (rare or absent at the AH). Hover a material to see which recipes use it.

**Scan list** checks the live price of every item in the list and builds the price history. **Buy** only appears on deals: it reads live listings, buys only the units under your limit, caps the spend, and asks you to confirm. **→ Auctionator** creates the same list in Auctionator, to browse prices there.

Recipe materials come from the game itself, so they stay correct for WoW Forever's new recipes. Materials sold by merchants (bag icon) count in recipe costs at their merchant price but stay out of the shopping lists. Craft yields count (Cured Rugged Hide makes 2). Columns sort by clicking their header.

### Auction house
- **Scan**: full AH scan when the game allows it (every 15 min), otherwise a scan of your professions' reagents and crafts.
- **Buy**: your craft queue's reagents, never above the vendor price, your break-even or the usual price.
- **Post**: 1c under the cheapest other seller, never under your cost or the vendor price. After an expiry it posts one at a time; two in a row pause the item for 1, 2, 4… days; three send it to the vendor list. Tooltips at the AH warn about items that keep expiring, even when you post with another addon.
- **Cancel**: only when the price gap is worth more than the lost deposit.

### Market tab
What sells across the whole AH (estimated from full scans), what is worth farming, AH flips, vendor flips (listings below what a vendor pays), and **vendor crafts**: every recipe of every profession whose result sells to a vendor for more than its materials cost at the AH, with the profit per craft, how many crafts the current listings allow, the skill needed and where to learn it.

### Price history
Click any item in Lists, Market or Stock (or type `/ipg item <item>` or `/ipg price <item>`) to open its price history: the lowest listing (bait listings skipped) and the market price (average of the cheapest 15–30 %), from 1 day to All, with the units gone and newly listed at each scan. The usual price range shows as a band and the vendor price as a dotted line. Four key numbers: vs vendor or usual price, last 4 days, since the first scan, AH supply. Below the curve: usual price, usual range, volatility, estimated sales per day, vendor price and the verdict. Items in your lists get one point per scan for 7 days and a daily summary for 2 years; every other item one point per day. Shift-click links the item in chat.

### Stock tab
Everything you own, on every character: bags, bank, warband bank, mail, AH listings and items in the mail to your characters. Each item is valued at its AH price after the 5 % cut or its vendor price, whichever is higher (soulbound items: vendor price only). Sort by name, quantity, unit value or total; filter AH-valued, vendor-valued or unpriced items. The Overview "Stock value" card uses the same numbers; click it to open the tab.

### Crafting
Craft advisor next to the profession window, a craft queue per crafter with adaptive stock targets and a budget cap, shopping list across all your characters, one key to craft the next recipe then disenchant.

### Mail & routine
- Mailbox overlay: collect all (or only sales, purchases, expired…), Send tab with recipient autocomplete and attachment counter.
- Routine window: send crafts to the bank, reagents to the crafter, buy vendor reagents, sell to vendor. Every batch action shows a checklist first.

### Disenchanting
On enchanters only: lists the greens and blues in your bags (equipment sets excluded), one key press per item.

## Languages

English and French, picked automatically from the game client language. Translations live in `Locale_frFR.lua` (English text is the key).

## Commands

| Command | What it does |
|---|---|
| `/ipg` | Main window |
| `/ipg lists` | Lists tab, plus a check of the recipe data the game provides |
| `/ipg list` | Routine window |
| `/ipg de` | Disenchant window |
| `/ipg item <item>` | Price history of an item (link, id or name); `/ipg price` does the same |
| `/ipg sold` | Vendor sales of the last 7 days, and what was worth more at the AH |
| `/ipg report` | 30-day test report per item |
| `/ipg hints` | Toggle the "worth more at the AH" warnings at vendors |
| `/ipg mail` | Switch between the addon's mailbox and Blizzard's |
| `/ipg minimap` | Show / hide the minimap button |

## Code layout

Load order: see `ImpotPointGouv.toc`. All files share the `ns` table (`local _, ns = ...`). UI strings go through `Tr("English text")`.

| File | Purpose |
|---|---|
| `Locale.lua`, `Locale_frFR.lua` | Translation system and French strings |
| `Core.lua` | Saved data (`ImpotPointGouvDB`), money formatting, small event bus (`ns.On` / `ns.Fire`) |
| `Ledger.lua` | Gold ledger: every money change is categorized |
| `Track.lua` | Vendor sale details, loot log, time per zone/level, items that don't sell |
| `Theme.lua` | Colors, buttons, tooltips, UI widgets |
| `UI.lua`, `Chart.lua` | Main window, tabs, chart, settings |
| `DataRecipes.lua` | Every profession recipe (skill colors, materials, pattern), for the leveling route |
| `Route.lua` | Cheapest leveling route, alternatives, trainer cost capture |
| `Data.lua` | Built-in list data: pre-BiS crafts and consumables per spec, enchants, leveling shopping lists, cooldowns, fallback recipes |
| `Lists.lua`, `ListsUI.lua` | Lists tab: lists, recipe trees, verdicts, deal buying, cooldown tracking |
| `Prices.lua` | AH scans, price history and stats (usual price, low/high, volatility, sales/day) |
| `Market.lua` | Market tab (what sells, flips, vendor crafts) |
| `Stock.lua` | Stock tab: everything you own and its value |
| `History.lua` | Price history window: one point per scan, daily summaries, key numbers |
| `Sell.lua` | AH posting and cancelling |
| `Craft.lua`, `Queue.lua`, `Keep.lua` | Craft advisor, craft queue, quantities to keep |
| `Routine.lua`, `Next.lua`, `Preview.lua` | Routine window, next-action key, checklist before batch actions |
| `Mail.lua` | Mailbox (Inbox / Send tabs) |
| `Destroy.lua` | Disenchanting |
| `Inventory.lua`, `Trainer.lua`, `Report.lua`, `Setup.lua` | Multi-character inventory, trainer pattern value, report, setup guide |

## Contributing

1. Fork the repo, then create one branch per topic (`fix/mail-send`, `feat/weekly-report`…).
2. Test in game (WoW Forever, modern client, Lua 5.1).
3. Open a Pull Request describing what changes and how to test it.

A new version is released automatically when the `## Version:` line of `ImpotPointGouv.toc` changes on `main`.

## License

Libraries bundled in `libs/`: Ace3 license (see `libs/LICENSE-Ace3.txt`). Inter font: SIL OFL (see `media/fonts/OFL-inter.txt`).
