# Changelog

All notable changes to ImpotPointGouv. Newest first.
Every pull request adds its lines under **Unreleased**; a release pull request turns that section into the new version.

## [Unreleased]

### Added
- Mail: "Collect expired" button next to Collect gold, to take back the items of expired and cancelled auctions (sales and other mail stay).
- Mail: send part of a stack. Click the quantity of a checked item to type it, or use Shift with − / +; the addon splits the stack into a free bag slot when you send.
- Lists: the Cooking list filters foods by buff (Strength, Agility, Stamina, Intellect, Spirit, AP, SP, HP, Misc), read from each food's tooltip so Forever's own foods are covered.

### Changed
- Repost advice moved out of the chat. When you post an item that keeps expiring, Auctionator's "Post anyway?" confirmation (the one it shows when a vendor pays more) now also says to wait ("Expired 2× in a row: wait 2 days before posting it again") or to vendor it. The item tooltip at the AH and at vendors shows the same advice in one line. The message fits in two lines, so it no longer runs under the dialog's buttons. A single expiry no longer shows any advice: an auction often expires once (undercut, quiet hours).
- Queue profitable: a craft for the AH needs real demand. It is skipped when the AH buys less than 1 a day (yours or the market's sales, setting) or when more than 7 days of sales are listed (setting); an item with no data gets one test craft, marked "test". Crafts are queued by expected profit per day, so a big margin on an item nobody buys no longer fills the queue.
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
