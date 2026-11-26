# Changelog

All notable changes to ImpotPointGouv. Newest first.
Every pull request adds its lines under **Unreleased**; a release pull request turns that section into the new version.

## [Unreleased]

### Added
- Settings: Master Chef rank (WoW Forever Legacy talent, 0 to 5). Cooking margins, Queue profitable and the Cooking leveling route count its extra results on average (+10 % per rank).
- Mail: rules, like TSM's mailing operations. A rule sends a kind of item (Leather, Herb, Food & Drink, Flask… the game's item types), the items you crafted, one of your lists or one item to one of your characters, keeping a number on the sender. In the Send tab, "By rules" selects everything that matches for the recipient with the most items; check and Send. "Rules…" opens the editor (first matching rule wins, a character never mails itself).
- Overview: the Sales card splits your AH sales by origin: farmed or looted, trading profit (resold minus what you paid) and crafted; hover for the detail. Rebuilt from the logs already kept (oldest units sold first, mail between your characters keeps the origin, a craft uses up its reagents); items owned before tracking count as farmed.
- Mail: "Collect expired" button next to Collect gold, to take back the items of expired and cancelled auctions (sales and other mail stay).
- Mail: send part of a stack. Click the quantity of a checked item to type it, or use Shift with − / +; the addon splits the stack into a free bag slot when you send.
- Lists: the Cooking list filters foods by buff (Strength, Agility, Stamina, Intellect, Spirit, AP, SP, HP, Misc), read from each food's tooltip so Forever's own foods are covered.

### Changed
- Repost advice moved out of the chat. When you post an item that keeps expiring, Auctionator's "Post anyway?" confirmation (the one it shows when a vendor pays more) now also says to wait ("Expired 2× in a row: wait 2 days before posting it again") or to vendor it. The item tooltip at the AH and at vendors shows the same advice in one line. The message fits in two lines, so it no longer runs under the dialog's buttons. A single expiry no longer shows any advice: an auction often expires once (undercut, quiet hours).
- Queue profitable: a craft for the AH needs real demand. It is skipped when the AH buys less than 1 a day (yours or the market's sales, setting) or when more than 7 days of sales are listed (setting); an item with no data gets one test craft, marked "test". Crafts are queued by expected profit per day, so a big margin on an item nobody buys no longer fills the queue.
- Queue profitable: a craft for the AH needs real demand. It is skipped when the AH buys less than 1 a day (yours or the market's sales, setting) or when more than 7 days of sales are listed (setting); an item with no data gets one test craft, marked "test". Crafts are queued by expected profit per day, so a big margin on an item nobody buys no longer fills the queue. The message also counts the recipes left out because they earn less than your minimum profit or margin (reagents count at their market price, so selling them raw pays as much).
- Market › Farm: what is worth farming now, for your characters. Raw materials anyone can loot (cloth, meat & fish, elemental) or your gathering professions collect (Skinning, Mining, Herbalism, Enchanting), plus the reagents of your recipes; rare drops are left out. Columns: price, sold per day, 7-day trend against the 30-day usual price, and your gold per hour where you farmed it (loot log and time per zone). Rising prices with falling stock are marked "farm now". Right-click a row for its Wowhead link.
- Market › Farm: what is worth farming now, for your characters. Raw materials anyone can loot (cloth, meat & fish, elemental) or your gathering professions collect (Skinning, Mining, Herbalism, Enchanting), plus the reagents of your recipes; rare drops are left out. Columns: price, sold per day, 7-day trend against the 30-day usual price, and your gold per hour where you farmed it (loot log and time per zone). Rising prices with falling stock are marked "farm now". Right-click a row for its Wowhead link. (The link popup adds itself to the game's popup list without replacing it, so Blizzard popups, the Esc menu and vendors are not tainted.)
- Market › Farm: what is worth farming now, for your characters. Raw materials anyone can loot (cloth, meat & fish, elemental) or your gathering professions collect (Skinning, Mining, Herbalism), plus the reagents of your recipes; rare drops, anything a recipe makes (Golden Rod, bolts…) and enchanting mats are left out. Columns: price, sold per day, 7-day trend against the 30-day usual price, and your gold per hour where you farmed it (loot log and time per zone). Rising prices with falling stock are marked "farm now". Right-click a row for its Wowhead link. (The link popup adds itself to the game's popup list without replacing it, so Blizzard popups, the Esc menu and vendors are not tainted.)
- Price history: new storage. Every item now keeps a daily summary for 30 days (lowest, usual and highest price, quantity listed, units within 10 % of the lowest, estimated units sold), then one per week for a year. Items in your lists keep every scan for 7 days and a daily summary for 6 months. Your existing history is converted once at the first login (a full game restart is needed after updating).
- Price history: every profession item is now kept in detail (every scan for 7 days, a daily summary for 6 months): what any recipe makes, its recipe item and its materials, for every profession, plus items in your lists.
- Sold/day now shows for items in no list after a day with two scans or more, so most leveling-route steps get one. A full scan that no longer sees an item counts its units as gone.
- Usual and market prices use the median of each day's lowest prices instead of the day's last reading, so one cheap listing moves them less.
- Price history window: hover shows the usual price, the highest of the day's lowest prices and the units within 10 % of the lowest; long ranges show weekly points.
- AH: a full scan no longer drops the listings whose item the game had not loaded yet (they came back without quantity or price, mostly right after login): it waits for them, like Auctionator. Each scan logs how many auctions it read; one far below the usual size is flagged partial in the AH bar and does not mark unseen items as sold out, nor count them as sales in the Market tab.
- AH: the Scan button always runs a full scan. It no longer falls back to a scan of your professions' items when the server does not answer; it waits up to 5 min, and an answer that comes later is still recorded.
- Queue profitable: only recipes earning at least 2s per craft by default (setting). A new craft starts with one stack at most, sized on what the AH sells per day; a batch that sells out within 2 h doubles the next one, one that mostly comes back is halved, and a single item never goes above 5 stacks.
- Lists: By recipe / Flat list moved next to the Auctionator button.
- Leveling route: clicking an alternative uses that recipe for the step's skill range. "Reset my choices" clears these picks.

### Removed
- AH: the Buy reagents, Post and Cancel undercut buttons next to Scan, and the "Selling at the AH" settings that went with them. Buying and posting stay with the AH or Auctionator; the addon keeps the shopping list and the prices. The AH bar shrinks to one compact row: the Scan button and its status line. The "click Scan" reminder is gone: the bar already says how long ago the last full scan was.

### Fixed
- Mail: an item right-clicked from the bags while the mailbox is open went into the game's hidden send form, where you could not see or remove it. It now shows checked in the Send tab like the others; right-click a row to remove it.
- AH purchases by buyout were sometimes logged under the wrong item (the last one searched, e.g. the item Auctionator looked up while you posted). The item now comes from the listing you bought.
- Overview: Top AH sales lists 5 items, so the last one no longer runs into the version number.
- Price history: the chart tooltip showed "Listed" twice.
- Craft queue: one refresh after a series of bag changes instead of one per change (selling 20 items at a vendor froze the game 50 ms each time).
- Setup guide: a profession just learned (skill under 5, e.g. Cooking 1 on a new alt) no longer asks to be opened; levelling it opens the window anyway.
- Mail, Send tab: clicking one of your characters under "To" now enables the Send button right away (it stayed greyed until something else changed).
- Lists: the 7-day bars are proportional to the price, so a 10 % drop no longer looks like a crash; days without a scan show as a faint dash.
- Lists, cooldown view: the Cooldown and Per day columns no longer overlap.
- Lists: an item with nothing to do shows "normal" in the Verdict column (with the reason in its tooltip) instead of a blank, and the green count next to a list says what it counts when you hover it (items under their usual price).
- Lists: BUY and SELL need prices from at least 5 days of the last week. With only 2 or 3 days of scans (or scans that missed listings, before the full scan fix), the "usual" price was too high and almost everything showed BUY; the tooltip now says it is cheap today but needs more scans.
- Lists: a crafted item is no longer marked FARM. When nobody sells it, it shows CRAFT if one of your characters knows the recipe (a chance to sell it), otherwise nothing; FARM stays for materials. The verdict reasons are translated.
- The addon no longer touches the game's own popup and Esc tables. Writing into them made the game treat its own code as coming from the addon, so it blocked protected actions: buying a bank tab, cancelling a logout, the Esc menu while casting, selling at a vendor. The addon's windows close on Esc by themselves, and its confirmations (new list, reset) use its own dialog.
- Market › Vendor flip: only real flips. A listing must be at least 10 % under the vendor price, and the flip worth 50 s or more; before, 1 copper under the vendor price counted, so the tab filled with gear dumped a few copper under it (7 c on a 26 s item).
- Market › Vendor flip: only real flips. A listing must be at least 10 % under the vendor price, and the flip worth 5 s or more; before, 1 copper under the vendor price counted, so the tab filled with gear dumped a few copper under it (7 c on a 26 s item).
- Profession window: when ForeverRecipes is loaded (it now shows its own profit in the recipe list), the addon's profit next to each recipe stays off so the two no longer overlap. `/ipg profit` turns it back on.
- Mail: AH sales collected together (the game sometimes adds up the gold of several mails before telling the addon) were recorded as plain mail money, so they were missing from Sales and Top AH sales. Each one is recorded as a sale with its item now. Sales already recorded as mail money stay as they are.
- Mail: sending part of a stack for two different items at once now splits them one after the other, so the game does not refuse the second split.
- Mail: the "Collect only" buttons no longer try to take items when your bags are full (they waited 4 s on each mail); they take the gold and stop.
- Overview: the Stock value card now matches the Stock tab. It updates when your bags change and when the game loads item prices it did not have yet.
- Leveling route showed recipes as Known after you looked at someone else's profession (a link, guild or NPC window). Those recipes are no longer saved, and the wrong ones are cleaned up at login or when you next open your own profession window.
- Item names that never appeared or blinked every few seconds in Lists, Market and Stock; prices next to recipes in the profession window no longer redraw constantly.

## [1.0.0] - 2026-11-23

First stable release: everything up to 0.25.0, now developed by two maintainers through reviewed pull requests.

### Added
- CI on every pull request: Lua 5.1 syntax check, toc check, smoke tests in English and French (`tests/run.lua`).
- `CONTRIBUTING.md`: branches, pull requests, changelog, versioning and release process.
- Release notes are taken from this changelog.

## [0.25.0] - 2026-11-23

### Added
- Leveling route: choose how crafts are sold (AH, Merchant, Disenchant, or the best of several); disenchant values from Auctionator's Classic table.
- Price history window: lowest and market price per scan, units gone and newly listed, ranges from 1 day to All; merged with the 0.24.0 price card. `/ipg item` and `/ipg price` open it.
- Lists: Cooking and Alchemy recipe lists, sortable columns, cooldown and profit-per-day columns for daily cooldowns.
- `/ipg perf` profiler.

### Changed
- Recipe data comes from ForeverMaster: Forever skill thresholds and yields for all 2,160 recipes.
- Crafts that make 2 count as 2, cooldown recipes leave the route, a recipe is paid for once.
- Merchant materials count in recipe costs.
- Realm lookup worked out once per session; data saved under an empty realm name is merged back.

### Fixed
- Market tab freezes (realm lookup, refresh loops, caches).

## [0.24.0] - 2026-11-20

### Added
- Price card: price curve, usual-price band, vendor price line, four key numbers, volatility. Opens on click in Lists, Market and Stock, and with `/ipg price`.

## [0.23.1] - 2026-11-20

### Fixed
- Prices and scans are kept when `GetRealmName()` returns an empty string (Forever 1.60.1).

## [0.23.0] - 2026-11-18

### Added
- Stock tab: everything you own on every character, valued at AH or vendor price, sortable.
- Market: Vendor crafts filter, recipes that sell to a vendor for more than their materials cost.

### Changed
- Leveling route shows the gold balance signed: − when a step costs, + when it earns.

## [0.22.3] - 2026-11-18

### Added
- Mail: choose how many stacks to send.

## [0.22.2] - 2026-11-18

### Fixed
- Mail tooltips show the real bag item, next to the window.

## [0.22.1] - 2026-11-18

### Changed
- Best route rows redesigned: skill gauge, source pills, folded alternatives.

### Fixed
- Mail collection waited up to 5 s per mail when several AH sales were identical.

## [0.22.0] - 2026-11-17

### Added
- Best leveling route per profession, with close alternatives and trainer cost capture.
