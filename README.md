# ImpotPointGouv

WoW Forever addon for routine gold making: gold tracking, mailbox, craft advisor, AH scanning and posting.
Inspired by TSM and Auctionator, with a clean, minimal interface.

## Installation

1. Download `ImpotPointGouv.zip` from the [latest release](../../releases/latest).
2. Unzip it into `World of Warcraft/_forever_/Interface/AddOns/`.
3. Fully restart the game (`/reload` does not load new files).

`/ipg` opens the main window. A setup guide shows up on first launch.

## Commands

| Command | What it does |
|---|---|
| `/ipg` | Main window (overview, history, characters, market, settings) |
| `/ipg list` | Routine (shopping list, mail sends) |
| `/ipg de` | Disenchant window |
| `/ipg sold` | Vendor sales over the last 7 days, and what was worth more at the AH |
| `/ipg report` | 30-day report |
| `/ipg hints` | Toggle the warnings shown at vendors |
| `/ipg mail` | Switch between the addon's mailbox and Blizzard's |

## Code layout

Load order: see `ImpotPointGouv.toc`. All files share the `ns` table (`local _, ns = ...`).

| File | Purpose |
|---|---|
| `Core.lua` | Saved data (`ImpotPointGouvDB`), money formatting, small event bus (`ns.On` / `ns.Fire`) |
| `Ledger.lua` | Gold ledger: every money change is categorized (AH, vendor, quest, loot, mail…) |
| `Track.lua` | Vendor sale details, loot log, time per zone/level, items that don't sell |
| `Theme.lua` | Colors, buttons, tooltips, UI widgets |
| `UI.lua`, `Chart.lua` | Main window, tabs, chart |
| `Mail.lua` | Mailbox (Inbox / Send tabs) |
| `Prices.lua` | AH scans and price history |
| `Craft.lua`, `Queue.lua`, `Keep.lua` | Craft advisor, craft queue, quantities to keep |
| `Routine.lua`, `Next.lua`, `Preview.lua` | Routine (shopping, sending, vendor selling), preview before batch actions |
| `Sell.lua` | AH posting and cancelling |
| `Market.lua` | Market tab (what sells, flips) |
| `Destroy.lua` | Disenchanting |
| `Inventory.lua`, `Trainer.lua`, `Report.lua`, `Setup.lua` | Multi-character inventory, trainer, report, setup guide |

## Contributing

1. Fork the repo, then create one branch per topic (`fix/mail-send`, `feat/weekly-report`…).
2. Test in game (WoW Forever, modern client, Lua 5.1).
3. Open a Pull Request describing what changes and how to test it.

## License

Libraries bundled in `libs/`: Ace3 license (see `libs/LICENSE-Ace3.txt`). Inter font: SIL OFL (see `media/fonts/OFL-inter.txt`).
