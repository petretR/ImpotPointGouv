-- Smoke tests: load the addon outside the game and exercise its main features.
-- Run from the repository root:  lua5.1 tests/run.lua
-- Options: IPG_LOCALE=frFR to load the French strings, IPG_VERBOSE=1 to print chat output.

dofile("tests/mock.lua")

local passed, failed = 0, 0
local function Check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok    " .. name)
    else
        failed = failed + 1
        print("FAIL  " .. name .. "\n      " .. tostring(err))
    end
end
local function Assert(cond, msg) if not cond then error(msg or "assertion failed", 2) end end

-- Load every file of the toc, in order, the way the game does.
local ns = {}
local toc = assert(io.open("ImpotPointGouv.toc")):read("*a")
for line in toc:gmatch("[^\r\n]+") do
    local f = line:match("^%s*([^#%s][^%s]*%.lua)%s*$")
    if f and not f:find("LibDBIcon") then
        f = f:gsub("\\", "/")
        local chunk = assert(loadfile(f))
        chunk("ImpotPointGouv", ns)
    end
end
Fire("ADDON_LOADED", "ImpotPointGouv")
Fire("PLAYER_ENTERING_WORLD")
RunTimers(5)

Check("addon loads and has a version", function()
    Assert(ns.db, "saved data not created")
    Assert(type(ns.version) == "string" and ns.version ~= "", "no version")
end)

Check("toc version matches ns.version", function()
    local v = toc:match("## Version:%s*([%w%.%-]+)")
    Assert(v == ns.version, ("toc says %s, Core.lua says %s"):format(tostring(v), tostring(ns.version)))
end)

Check("realm key survives an empty realm name", function()
    local r = ns.Realm()
    Assert(type(r) == "string" and r ~= "", "empty realm key")
end)

-- Give every recipe material and pattern a price, as a full AH scan would.
-- (High cooking recipes only come from patterns, so a route needs patterns listed.)
local P = ns.Prices
local priced = 0
for _, t in pairs((ns.Data or {}).allRecipes or {}) do
    if t[7] and t[7] ~= 0 and not P.Entry(t[7]) then P.Record(t[7], 5000, 3, true) end
    for i = 9, #t, 2 do
        local id = t[i]
        if id and id > 0 and not (P.Entry and P.Entry(id)) then
            P.Record(id, 150, 40, true)
            priced = priced + 1
        end
    end
end

Check("leveling route reaches 300 in every profession", function()
    Assert(priced > 100, "too few materials priced: " .. priced)
    for _, prof in ipairs({ "alch", "bs", "ench", "eng", "lw", "tail", "cook", "fa" }) do
        local r = ns.Route.Compute(prof, {})
        Assert(r and r.reached, prof .. " does not reach 300")
        Assert(#r.segs > 0, prof .. " has no steps")
    end
end)

Check("every main tab opens", function()
    for _, tab in ipairs({ "bilan", "lists", "market", "stock", "tx", "chars", "settings" }) do
        ns.UI.Toggle(tab)
        Assert(ns.UI.Current() == tab, "tab " .. tab .. " did not open")
    end
end)

Check("best route view draws", function()
    ns.UI.Toggle("lists")
    ns.ListsUI.select = "lv_lw"
    ns.UI.Refresh()
end)

Check("clicking an alternative pins that recipe to the step", function()
    local r = ns.Route.Compute("lw", { from = 1 })
    local sg
    for _, x in ipairs(r.segs) do if #(x.alts or {}) > 0 then sg = x; break end end
    Assert(sg, "no step with alternatives")
    local alt = sg.alts[1].r.spell
    ns.Route.Pin("lw", alt, sg.from, sg.to)
    Assert(ns.Route.HasBans("lw"), "pin not remembered")
    local used = false
    for _, x in ipairs(ns.Route.Compute("lw", { from = 1 }).segs) do
        if x.r.spell == alt and x.from <= sg.from and x.to >= sg.to then used = true end
    end
    Assert(used, "the picked alternative is not used on its range")
    ns.Route.ResetBans("lw")
    Assert(not ns.Route.HasBans("lw"), "reset left choices behind")
end)

Check("recipes from someone else's profession window are not yours", function()
    IsTradeSkillLinked = function() return true end
    Assert(ns.Craft.ForeignWindow("Leatherworking"), "linked window treated as your own")
    IsTradeSkillLinked = nil
    local me = UnitGUID("player")
    local c = ns.db.chars[me]
    local saved = c.profs
    c.profs = { { name = "Leatherworking", rank = 225 } }
    Assert(ns.Craft.ForeignWindow("Blacksmithing"), "a profession you don't have is treated as yours")
    Assert(not ns.Craft.ForeignWindow("First Aid"), "First Aid is never foreign")
    ns.db.recipes.Blacksmithing = { ["Rough Sharpening Stone"] = { p = 2862, m = 1, r = {} } }
    ns.db.profChars = ns.db.profChars or {}
    ns.db.profChars.Blacksmithing = { [me] = true }
    ns.Craft.PruneForeign()
    Assert(ns.db.recipes.Blacksmithing == nil, "foreign profession kept after login cleanup")
    c.profs = saved
end)

Check("cooking filter reads the food's buff from its tooltip", function()
    local LS = ns.Lists
    LS.FoodTags(4242) -- creates the hidden tooltip
    local tip = _G.ImpotPointGouvScanTip
    Assert(tip, "scan tooltip not created")
    local lines = { "Spiced Chili Crab", "Use: Restores 874 health. Well fed: gain 12 Stamina and Spirit for 15 min." }
    tip.NumLines = function() return #lines end
    for i in ipairs(lines) do _G["ImpotPointGouvScanTipTextLeft" .. i] = { GetText = function() return lines[i] end } end
    Assert(LS.FoodMatch(4243, "sta") and LS.FoodMatch(4243, "spi"), "Stamina and Spirit not found")
    Assert(not LS.FoodMatch(4243, "agi") and not LS.FoodMatch(4243, "misc"), "wrong stats found")
    lines[2] = "Requires Level 5" -- "Use:" line not loaded yet: wait instead of filing it under Misc
    Assert(LS.FoodTags(4245) == nil, "food filed before its tooltip finished loading")
    lines[2] = "Use: Restores 61 health over 18 sec."
    Assert(LS.FoodMatch(4244, "misc"), "food without a buff is not Misc")
    ns.UI.Toggle("lists")
    ns.ListsUI.select = "all_cook"
    ns.db.settings.cookStat = "sta"
    ns.UI.Refresh()
    ns.db.settings.cookStat = nil
end)

Check("price window opens from the slash command", function()
    SlashCmdList.IMPOTPOINTGOUV("price 2589")
    SlashCmdList.IMPOTPOINTGOUV("item 2589")
end)

Check("mail collection takes 35 mails quickly, identical sales included", function()
    for i = 1, 30 do inbox[#inbox + 1] = { sender = "Auction House", subject = "Auction successful: Linen Cloth", money = 5000 } end
    for i = 1, 5 do inbox[#inbox + 1] = { sender = "Bob", subject = "hey", money = 100, items = 1, text = true } end
    ns.db.settings.mailOverlay = false
    Fire("MAIL_SHOW")
    RunTimers(1)
    local t0, gold0 = GetTime(), money
    ns.Mail.Collect("all")
    for _ = 1, 120 do
        RunTimers(1)
        if #inbox == 5 and mailTakes == 35 then break end
    end
    Assert(money - gold0 == 30 * 5000 + 5 * 100, "gold collected: " .. (money - gold0))
    Assert(#inbox == 5, "mails left: " .. #inbox .. " (only the 5 letters with text should stay)")
    Assert(mailTakes == 35, "takes: " .. mailTakes)
    Assert(GetTime() - t0 < 30, ("took %.1f s"):format(GetTime() - t0))
    Fire("MAIL_CLOSED")
end)

Check("Collect expired takes expired and cancelled auctions only", function()
    for i = #inbox, 1, -1 do inbox[i] = nil end
    for i = 1, 3 do inbox[#inbox + 1] = { sender = "Auction House", subject = "Auction expired: Linen Cloth", money = 0, items = 1 } end
    inbox[#inbox + 1] = { sender = "Auction House", subject = "Auction cancelled: Wool Cloth", money = 0, items = 1 }
    inbox[#inbox + 1] = { sender = "Auction House", subject = "Auction successful: Wool Cloth", money = 5000, items = 0 }
    inbox[#inbox + 1] = { sender = "Bob", subject = "hey", money = 100, items = 1 }
    ns.db.settings.mailOverlay = false
    Fire("MAIL_SHOW")
    RunTimers(1)
    ns.Mail.Collect("auctionExpired") -- what the Collect expired button starts
    for _ = 1, 60 do RunTimers(1); if #inbox == 2 then break end end
    Assert(#inbox == 2, "mails left: " .. #inbox .. " (the sale and Bob's mail should stay)")
    for _, m in ipairs(inbox) do
        Assert(not m.subject:find("expired") and not m.subject:find("cancelled"), "an expired or cancelled auction is still there")
    end
    -- Bags full: nothing is taken, the run stops instead of retrying.
    inbox[#inbox + 1] = { sender = "Auction House", subject = "Auction expired: Linen Cloth", money = 0, items = 1 }
    local free = C_Container.GetContainerNumFreeSlots
    C_Container.GetContainerNumFreeSlots = function() return 0, 0 end
    local takes = mailTakes
    ns.Mail.Collect("auctionExpired")
    RunTimers(3)
    C_Container.GetContainerNumFreeSlots = free
    Assert(mailTakes == takes, "took a mail with full bags")
    Fire("MAIL_CLOSED")
    for i = #inbox, 1, -1 do inbox[i] = nil end
end)

Check("overview stock value follows inventory changes and late item info", function()
    ns.UI.Toggle("bilan")
    RunTimers(3)
    local refreshes, orig = 0, ns.UI.Refresh
    ns.UI.Refresh = function(...) refreshes = refreshes + 1; return orig(...) end
    ns.Fire("INVENTORY_CHANGED")
    ns.Fire("INVENTORY_CHANGED")
    RunTimers(3)
    Assert(refreshes == 1, "refreshes after two inventory changes: " .. refreshes)
    -- An item with no price yet and no item info gets requested, and its info redraws the Overview.
    local key = ns.Ledger.CharKey()
    ns.db.inv = ns.db.inv or {}
    ns.db.inv[key] = ns.db.inv[key] or { bags = {}, bank = {}, owned = {}, mail = {} }
    ns.db.inv[key].bags[987654] = 3
    local getInfo = C_Item.GetItemInfo
    C_Item.GetItemInfo = function(id) if id == 987654 then return nil end return getInfo(id) end
    ns.Stock.Value()
    Assert(ns.ItemWanted(987654), "uncached stock item was not requested")
    C_Item.GetItemInfo = getInfo
    refreshes = 0
    Fire("GET_ITEM_INFO_RECEIVED", 987654, true)
    RunTimers(3)
    Assert(refreshes >= 1, "Overview not redrawn when the item info arrived")
    ns.db.inv[key].bags[987654] = nil
    ns.UI.Refresh = orig
end)

Check("mail sends part of a stack by splitting it into a free slot", function()
    bags[0] = { { itemID = 500, stackCount = 20 }, { itemID = 500, stackCount = 20 }, { itemID = 500, stackCount = 20 } }
    sentMails = {}
    Fire("MAIL_SHOW")
    RunTimers(1)
    local stacks, splits = ns.Routine.PlanStacks({ [500] = 50 })
    Assert(#stacks == 2 and #splits == 1 and splits[1].count == 10, "plan: 2 stacks + a split of 10")
    Assert(ns.Routine.SendTo("Alt", { [500] = 50 }), "send refused")
    RunTimers(5)
    local sent = 0
    for _, m in ipairs(sentMails) do for _, it in pairs(m.items) do if it.itemID == 500 then sent = sent + it.stackCount end end end
    Assert(sent == 50, "sent " .. sent .. " instead of 50")
    local left = 0
    for slot = 1, 16 do local it = bags[0][slot]; if it then left = left + it.stackCount end end
    Assert(left == 10, "left in bags: " .. left)
    -- No free slot: refused, nothing moves.
    bags[0] = {}
    for slot = 1, 16 do bags[0][slot] = { itemID = 500, stackCount = 20 } end
    sentMails = {}
    Assert(not ns.Routine.SendTo("Alt", { [500] = 5 }), "should refuse without a free slot")
    RunTimers(2)
    Assert(#sentMails == 0, "something was sent")
    Fire("MAIL_CLOSED")
    bags[0] = {}
end)

Check("mail Send tab: quantity by stacks, by one with Shift, or typed", function()
    bags[0] = { { itemID = 500, stackCount = 20 }, { itemID = 500, stackCount = 20 } }
    ns.db.settings.mailOverlay = true
    Fire("MAIL_SHOW")
    RunTimers(1)
    ns.Mail.ShowOverlay()
    ns.Mail.SetTab("send")
    ns.Mail.DrawSend()
    RunTimers(1)
    local p = rawget(_G.ImpotPointGouvMailFrame, "send")
    local r = p.rows[1]
    local function Click(b) b:GetScript("OnClick")(b); RunTimers(1) end
    Click(r)
    Assert(p.attachments == 2, "checked: 2 stacks, got " .. tostring(p.attachments))
    Click(r.minus)
    Assert(p.attachments == 1, "one stack less: got " .. tostring(p.attachments))
    local shift = IsShiftKeyDown
    IsShiftKeyDown = function() return true end
    Click(r.plus)
    IsShiftKeyDown = shift
    Assert(p.attachments == 2, "21 items = 1 stack + 1 split, got " .. tostring(p.attachments))
    ns.Mail.EditQuantity(r)
    p.qtyEdit.GetText = function() return "7" end
    p.qtyEdit:GetScript("OnEnterPressed")(p.qtyEdit)
    RunTimers(1)
    Assert(p.attachments == 1, "7 typed = 1 split, got " .. tostring(p.attachments))
    Fire("MAIL_CLOSED")
    ns.db.settings.mailOverlay = false
    bags[0] = {}
end)

Check("mail splits two partial items one after the other", function()
    bags[0] = { { itemID = 500, stackCount = 20 }, { itemID = 600, stackCount = 20 } }
    sentMails = {}
    -- Like the game: a second split is refused while the first split slot is still locked.
    local split, locked = C_Container.SplitContainerItem, false
    C_Container.SplitContainerItem = function(...)
        if locked then return end
        locked = true
        C_Timer.After(0.1, function() locked = false end)
        return split(...)
    end
    Fire("MAIL_SHOW")
    RunTimers(1)
    Assert(ns.Routine.SendTo("Alt", { [500] = 5, [600] = 7 }), "send refused")
    RunTimers(5)
    C_Container.SplitContainerItem = split
    local got = {}
    for _, m in ipairs(sentMails) do for _, it in pairs(m.items) do got[it.itemID] = (got[it.itemID] or 0) + it.stackCount end end
    Assert(got[500] == 5 and got[600] == 7, ("sent %s of 500 and %s of 600"):format(tostring(got[500]), tostring(got[600])))
    Fire("MAIL_CLOSED")
    bags[0] = {}
end)

Check("queue profitable: first batch sized on the market, then adapted to real sales", function()
    local Q, rules = ns.Queue, ns.Craft.Rules()
    Assert(rules.minProfit == 200, "default min profit should be 2s, got " .. tostring(rules.minProfit))
    local rate = ns.Market.Rate
    local rec = { pid = 777001, name = "Item 777001" } -- the mock names every item "Item <id>"
    ns.Market.Rate = function() return 450 end
    Assert(Q.FirstBatch(rec, {}, rules) == 20, "450/day: capped at one stack (20)")
    ns.Market.Rate = function() return 40 end
    Assert(Q.FirstBatch(rec, {}, rules) == math.max(rules.minQty, 2), "40/day: 5 % = 2")
    Assert(Q.FirstBatch(rec, { sold7 = 9 }, rules) == 9, "own sales of the last 7 days come first")
    ns.Market.Rate = rate
    -- Real sales: a batch of 20 posted and sold within an hour doubles the next one.
    ns.db.items[rec.pid] = rec.name
    ns.db.settings.adapt = ns.db.settings.adapt or {}
    ns.db.settings.adapt[rec.pid] = { t = 20, at = time() - 10 }
    local t0 = time()
    table.insert(ns.db.tx, { t = t0, k = "ah_deposit", i = rec.name, q = 20, a = -100 })
    Advance(1800)
    table.insert(ns.db.tx, { t = time(), k = "ah_sale", i = rec.name, q = 20, a = 1000 })
    Assert(Q.Target(rec, { channel = "ah" }, rules, true) == 40, "sold out in 30 min: 20 -> 40")
    -- Next batch: most of it comes back unsold, so it is halved.
    Advance(10)
    table.insert(ns.db.tx, { t = time(), k = "ah_deposit", i = rec.name, q = 40, a = -100 })
    Advance(10)
    table.insert(ns.db.tx, { t = time(), k = "ah_sale", i = rec.name, q = 10, a = 1000 })
    table.insert(ns.db.tx, { t = time(), k = "ah_expired", i = rec.name, q = 30, a = 0 })
    Assert(Q.Target(rec, { channel = "ah" }, rules, true) == 20, "10/40 sold: 40 -> 20")
    ns.db.settings.adapt[rec.pid] = nil
end)

-- ------------------------------------------------------------ price history (PriceStore.lua)
local Store = ns.Store
local DAY = 86400
-- Moves the clock to hh:mm of the next day (UTC days, as the store counts them).
local function NextDay(hour)
    local today = math.floor(time() / DAY)
    Advance((today + 1) * DAY + (hour or 8) * 3600 - time())
end

Check("price history: migration from the v1.0 prices / hist tables", function()
    local now = time()
    local today = math.floor(now / DAY)
    local db = { prices = { R = {
        [901] = { cur = 120, qty = 30, t = now - 100, d = { { today - 3, 100, 40 }, { today - 2, 110, 35 }, { today - 1, 105, 33 }, { today, 120, 30 } } },
        [902] = { cur = 50, qty = 9, t = now - 100,
            d = { { today - 1, 40, 10 } },
            h = { { now - DAY - 7200, 40, 12 }, { now - DAY - 3600, 45, 10 }, { now - 100, 50, 9 } } },
    } }, hist = { R = {
        [902] = { s = { (now - DAY - 7200) .. ",40,42,12,,", (now - DAY - 3600) .. ",45,46,10,2,0", (now - 100) .. ",50,52,9,1,0" },
            d = { (today - 1) .. ",40,88,2,10,2,0,2" }, lad = "50:9", lhi = -1, lt = now - 100 },
    } } }
    Assert(Store.Migrate(db, now) == 2, "two items converted")
    Assert(db.hist == nil and db.priceFormat == 2, "hist dropped, format marked")
    Assert(Store.Migrate(db, now) == 0, "runs only once")
    local a, b = db.prices.R[901], db.prices.R[902]
    Assert(type(a.d) == "string" and a.cur == 120 and a.qty == 30, "untracked: daily records and current price kept")
    local days = Store.Days(a)
    Assert(#days == 4 and days[1][1] == today - 3 and days[4].open, "3 closed days + today open, got " .. #days)
    Assert(days[2][Store.D.low] == 110, "daily low kept")
    Assert(a.s == nil, "untracked: no per-scan points")
    Assert(b.s and #Store.Points(b) == 3, "tracked: per-scan points kept")
    Assert(Store.Points(b)[2][3] == 46, "market price of a point kept")
    local bd = Store.Days(b)
    local y = bd[1]
    Assert(y[1] == today - 1 and y[Store.D.mkt] == 44, "yesterday's market price kept (88 / 2)")
    Assert(y[Store.D.sold] == 2 and y[Store.D.scans] == 2, "yesterday's sold recomputed from its scans")
    Assert(b.o and b.o[1] == today and #Store.Samples(b.o) == 1, "today's scan is the open day's sample")
    Assert(b.lq == 10, "last quantity before today kept for sales across midnight")
    Assert(b.lad == "50:9" and b.lat == now - 100, "ladder kept")
end)

Check("price history: a day closes into one daily record", function()
    local id = 903
    NextDay(1)
    local ladder = function(low, n) return { [low] = n, [math.floor(low * 1.05)] = 10, [low * 2] = 50 } end
    P.Record(id, 100, 70, true, ladder(100, 10))
    Advance(4 * 3600); P.Record(id, 90, 60, true, ladder(90, 0)) -- 10 gone
    Advance(30); P.Record(id, 90, 60, true, ladder(90, 0))       -- same scan, merged
    Advance(4 * 3600); P.Record(id, 95, 75, true, ladder(95, 15))  -- relisted
    Advance(4 * 3600); P.Record(id, 1, 5, false)                  -- seen by a search: low only
    Advance(3600); P.Record(id, 120, 50, true, ladder(120, 0))    -- 25 gone
    local e = P.Entry(id)
    Assert(#Store.Samples(e.o) == 4, "4 scans today, got " .. #Store.Samples(e.o))
    NextDay(2)
    P.Record(id, 110, 45, true, ladder(110, 0))                   -- 5 gone overnight
    local d = Store.Days(e)
    Assert(#d == 2, "yesterday closed + today open")
    local y = d[1]
    local D = Store.D
    Assert(y[D.low] == 1 and y[D.high] == 120, "low (search included) and high")
    Assert(y[D.usual] == 97.5 or y[D.usual] == 98, "usual = median of 100, 90, 95, 120: " .. tostring(y[D.usual]))
    Assert(y[D.qty] == 65 or y[D.qty] == 64, "median quantity: " .. tostring(y[D.qty]))
    Assert(y[D.sold] == 35 and y[D.scans] == 4, "sold 10 + 25, 4 scans: " .. tostring(y[D.sold]))
    Assert(y[D.depth] and y[D.depth] >= 10, "depth: units within 10 % of the lowest")
    Assert(Store.DayRecord(e)[D.sold] == nil, "today: one scan, sold unknown (not 0)")
    Assert(e.lq == 50, "yesterday's last quantity carried")
end)

Check("price history: Sold/day for an item in no list, from daily records", function()
    local id = 904
    Assert(not P.IsTracked(id), "not tracked")
    for day = 1, 3 do
        NextDay(6)
        P.Record(id, 200, 40, true)
        Advance(6 * 3600); P.Record(id, 210, 30, true)
        Advance(6 * 3600); P.Record(id, 205, 25, true)
        Advance(6 * 3600); P.Record(id, 200, 40, true)
    end
    NextDay(6); P.Record(id, 200, 40, true)
    local st = P.Stats(id)
    Assert(st.sales and st.sales >= 15 and st.sales <= 15.5, "about 15 sold per day, got " .. tostring(st.sales))
    Assert(st.med == 200 or st.med == 202.5 or st.med == 205, "usual price from daily records: " .. tostring(st.med))
    Assert(P.Market(id) and P.Market(id) >= 200 and P.Market(id) <= 205, "market value")
    local pts = ns.History.Series(id, 7 * DAY)
    Assert(#pts >= 4, "history window has daily points")
    ns.History.Show(id)
end)

Check("price history: sizes stay bounded (scans, days, weeks)", function()
    local id = 905
    ns.Lists.IsWatched = (function(f) return function(x) return x == id or f(x) end end)(ns.Lists.IsWatched)
    Assert(P.IsTracked(id), "tracked through its list")
    local untracked = 906
    for _ = 1, 420 do
        NextDay(0)
        for k = 1, 3 do
            Advance(3 * 3600)
            P.Record(id, 100 + k, 50 - k, true, { [100 + k] = 50 - k })
            P.Record(untracked, 100 + k, 50 - k, true)
        end
    end
    local e, u = P.Entry(id), P.Entry(untracked)
    local pts = Store.Points(e)
    Assert(#pts <= 7 * 3 + 1 and #pts >= 20, "per-scan points: 7 days, got " .. #pts)
    Assert(#Store.Records(e.d, nil, Store.DAYS) <= Store.KEEP_DAYS_TRACKED + 7, "tracked: about 6 months of days, got " .. #Store.Records(e.d, nil, Store.DAYS))
    Assert(#Store.Records(u.d, nil, Store.DAYS) <= Store.KEEP_DAYS + 7, "untracked: about 30 days, got " .. #Store.Records(u.d, nil, Store.DAYS))
    Assert(not u.s, "untracked: no per-scan points")
    local old = Store.Records(e.d, nil, Store.DAYS)[1]
    Assert(old[Store.D.usual] and old[Store.D.qty] and old[Store.D.sold], "an old tracked day keeps usual, qty and sold")
    Assert(not old[Store.D.high] and not old[Store.D.scans] and not old[Store.D.mkt], "and drops the rest")
    local wk = Store.Records(u.w, nil, Store.WEEKS)
    -- one year back from today: about 48 weeks before the 30 daily days
    Assert(#wk >= 46 and #wk <= Store.KEEP_WEEKS, "weekly records: up to one year, got " .. #wk)
    local w = wk[#wk]
    Assert(w[Store.W.sold] and w[Store.W.soldDays] == 7, "a week sums the sold of its 7 days")
    Assert(w[Store.W.usual] == 102, "weekly usual = median of daily usual")
    print(("      sizes: tracked d %d B, s %d B; untracked d %d B, w %d B"):format(#e.d, #(e.s or ""), #u.d, #(u.w or "")))
    Assert(#e.d < 190 * 30 and #u.d < 40 * 30 and #(u.w or "") < 53 * 40, "packed text stays small")
    local pts1y = ns.History.Series(untracked, 365 * DAY)
    Assert(#pts1y >= 70, "one year view: weekly then daily points, got " .. #pts1y)
    for i = 2, #pts1y do Assert(pts1y[i].t > pts1y[i - 1].t, "points in time order") end
end)

Check("price history: a full scan that misses an item records it as sold out", function()
    local acc = {}
    for i = 1, 300 do acc[950000 + i] = { low = 10, qty = 5 } end
    for id, a in pairs(acc) do P.Record(id, a.low, a.qty, true) end
    local gone = 950001
    acc[gone] = nil
    Advance(1800)
    P._RecordUnseen(acc)
    local e = P.Entry(gone)
    Assert(e.cur == nil and e.qty == 0, "no listing any more")
    local list = Store.Samples(e.o)
    Assert(list[#list][3] == 0, "a qty 0 sample")
    local tiny = { [950002] = acc[950002] }
    Advance(1800)
    Assert(P._RecordUnseen(tiny) == 0, "an incomplete scan marks nothing")
end)

Check("price history: every profession item is tracked, other items are not", function()
    local any
    for _, t in pairs(ns.Data.allRecipes) do
        if t[7] and t[7] > 0 and #t >= 9 then any = t; break end
    end
    Assert(any, "a recipe with a recipe item and materials")
    Assert(P.IsTracked(any[1]) and P.TrackReason(any[1]) == "profession", "crafted product")
    Assert(P.IsTracked(any[7]), "recipe item")
    Assert(P.IsTracked(any[9]), "material")
    Assert(not P.IsTracked(990001) and P.TrackReason(990001) == nil, "an unrelated item")
    local mat = any[9]
    P.Record(mat, 300, 12, true, { [300] = 12 })
    Advance(1800); P.Record(mat, 310, 8, true, { [310] = 8 })
    Assert(#Store.Points(P.Entry(mat), time() - 3600) == 2, "per-scan points for a material")
    local n = 0
    for _ in pairs(ns.Data.allRecipes) do n = n + 1 end
    Assert(n > 1000, "recipe data loaded")
end)

Check("price history: data saved under an empty realm merges", function()
    local now = time()
    local today = math.floor(now / DAY)
    local a = { cur = 10, qty = 1, t = now - 50, d = Store.Pack({ { today - 2, 10 }, { today - 1, 11, nil, nil, nil, nil, 3 } }, Store.DAYS) }
    local b = { cur = 12, qty = 2, t = now, d = Store.Pack({ { today - 3, 9 }, { today - 1, 13, nil, nil, nil, nil, 5 } }, Store.DAYS),
        o = { today, Store.PackOne({ 60, 12, 2 }, nil, Store.SAMPLES) } }
    Store.MergeEntry(a, b, false, today)
    local d = Store.Days(a)
    Assert(#d == 4 and d[1][1] == today - 3, "days from both, in order")
    Assert(d[3][Store.D.low] == 13, "same day: the record with more scans wins")
    Assert(a.cur == 12 and a.o, "newest current price and open day")
end)

Check("Scan always asks for a full scan, and takes a late answer", function()
    local P = ns.Prices
    local saved = C_AuctionHouse
    local calls = { replicate = 0, browse = 0 }
    C_AuctionHouse = {
        SendBrowseQuery = function() calls.browse = calls.browse + 1 end,
        ReplicateItems = function() calls.replicate = calls.replicate + 1 end,
        GetNumReplicateItems = function() return 1 end,
        GetReplicateItemInfo = function()
            return "Item 778001", nil, 5, nil, nil, nil, nil, nil, nil, 5000, nil, nil, nil, nil, nil, nil, 778001
        end,
    }
    local st = ns.db.scan[ns.Realm()] or {}
    ns.db.scan[ns.Realm()] = st
    st.lastFull = nil
    P.Scan()
    Assert(calls.replicate == 1 and calls.browse == 0, "Scan sent a full scan request, nothing else")
    RunTimers(301) -- the server never answers: the addon stops waiting after 5 min
    Assert(not P.Scanning(), "stopped waiting after 5 min")
    Assert(calls.browse == 0, "no profession scan as a fallback")
    Fire("REPLICATE_ITEM_LIST_UPDATE") -- the answer comes late
    RunTimers(3)
    local e = P.Entry(778001)
    Assert(e and e.cur == 1000, "late answer recorded (1000 per unit)")
    Assert(st.lastFull, "late answer counts as a full scan")
    C_AuctionHouse = saved
end)

Check("full scan waits for item data, logs its size and flags a partial answer", function()
    local P = ns.Prices
    local saved, savedItem = C_AuctionHouse, C_Item.DoesItemExistByID
    local st = ns.db.scan[ns.Realm()] or {}
    ns.db.scan[ns.Realm()] = st
    -- 3 listings: one ready, one whose item the client loads 1 s later, one ghost (item gone).
    local loaded = false
    local rows = {
        [0] = { "Item 779001", 20, 400, 779001, true },
        [1] = { "Item 779002", 5, 1000, 779002, false },
        [2] = { nil, 1, 100, 779999, true },
    }
    C_Item.DoesItemExistByID = function(id) return id ~= 779999 end
    C_AuctionHouse = {
        SendBrowseQuery = function() end,
        ReplicateItems = function() end,
        GetNumReplicateItems = function() return 3 end,
        GetReplicateItemInfo = function(k)
            local r = rows[k]
            local ready = r[5] or loaded
            return r[1], nil, ready and r[2] or nil, nil, nil, nil, nil, nil, nil, ready and r[3] or nil,
                nil, nil, nil, nil, nil, nil, r[4], ready
        end,
    }
    st.lastFull, st.log = nil, nil
    P.Scan()
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    C_Timer.After(3, function() loaded = true end)
    RunTimers(10)
    Assert(not P.Scanning(), "scan finished")
    local e = P.Entry(779002)
    Assert(e and e.cur == 200 and e.qty == 5, "listing read once its item loaded (5 at 200)")
    local log = st.log[#st.log]
    Assert(log.auctions == 3 and log.read == 2 and log.ghosts == 1 and log.missing == 0, "scan size logged")
    Assert(not log.partial, "first scans are not judged")
    -- Usual size ~100 auctions: an answer of 3 is flagged partial and does not mark the rest as sold out.
    st.log = { { auctions = 100, read = 100 }, { auctions = 110, read = 110 }, { auctions = 90, read = 90 } }
    local onFull, marketCalls = ns.Market.OnFullScan, 0
    ns.Market.OnFullScan = function() marketCalls = marketCalls + 1 end
    Advance(16 * 60)
    P.Scan()
    Fire("REPLICATE_ITEM_LIST_UPDATE")
    RunTimers(10)
    ns.Market.OnFullScan = onFull
    Assert(st.log[#st.log].partial, "partial answer flagged")
    Assert(marketCalls == 0, "a partial scan does not feed the Market tab's sales")
    C_AuctionHouse, C_Item.DoesItemExistByID = saved, savedItem
end)

Check("queue profitable: demand decides, not the margin alone", function()
    local Q, P = ns.Queue, ns.Prices
    local rules = ns.Craft.Rules()
    local stats = P.Stats
    local function With(sales, n) P.Stats = function() return { sales = sales, n = n or 7 } end end
    local rec = { pid = 780001, name = "Item 780001", made = 1 }
    -- Big margin, nobody buys it: skipped.
    With(0, 7)
    Assert(Q.DemandVerdict(rec, { channel = "ah", profit = 50000, listed = 10 }, rules) == "nodemand", "0 sold/day: no")
    -- No data at all and never posted: one test craft.
    P.Stats = function() return nil end
    Assert(Q.DemandVerdict(rec, { channel = "ah", profit = 50000, listed = 10 }, rules) == "test", "unknown demand: test")
    -- 2 sold/day but 100 days of stock listed: flooded.
    With(2)
    Assert(Q.DemandVerdict(rec, { channel = "ah", profit = 5000, listed = 200 }, rules) == "flooded", "100 days of stock")
    -- Small margin that sells a lot beats a big margin that sells little.
    With(200)
    local _, a = Q.DemandVerdict(rec, { channel = "ah", profit = 2000, listed = 300 }, rules)
    With(1.5)
    local _, b = Q.DemandVerdict(rec, { channel = "ah", profit = 10000, listed = 3 }, rules)
    Assert(a > b, ("20s x 200/day (%d) ranks above 1g x 1.5/day (%d)"):format(a, b))
    -- Your own sales come first.
    P.Stats = function() return nil end
    Assert(Q.DemandVerdict(rec, { channel = "ah", profit = 2000, listed = 5, sold7 = 14 }, rules) == "queue", "own sales: queue")
    -- Vendor crafts are not gated by AH demand.
    Assert(Q.DemandVerdict(rec, { channel = "vendor", profit = 300 }, rules) == "queue", "vendor craft")
    P.Stats = stats
end)

Check("repost advice: one line in the tooltip, and in Auctionator's post confirmation", function()
    local TR = ns.Track
    local line = TR.AdviceText({ streak = 1, lost = 300, vendor = 2500, edge = 200 })
    Assert(type(line) == "string" and not line:find("\n"), "one line: " .. tostring(line))
    Assert(TR.AdviceText({ streak = 1, lost = 0 }) == nil, "a single expiry says nothing")
    Assert(TR.StuckInBags == nil, "no more chat line when the AH opens")
    -- Auctionator's sale frame: its confirmation now carries the advice for an item that must wait.
    local orig = TR.PostAdvice
    TR.PostAdvice = function() return { streak = 2, lost = 0, pauseUntil = time() + 2 * 86400 } end
    local sale = { itemInfo = { itemLink = "|cffffffff|Hitem:2318::|h[Light Leather]|h|r", itemID = 2318 } }
    sale.GetConfirmationMessage = function() return nil end
    _G.AuctionHouseFrame = { AuctionatorSellingFrame = { SaleItemFrame = sale } }
    TR._HookAuctionator()
    local msg = sale:GetConfirmationMessage()
    Assert(msg and msg:find("2", 1, true), "confirmation explains the wait: " .. tostring(msg))
    Assert(select(2, msg:gsub("\n", "")) <= 1, "two lines at most (Auctionator's dialog does not grow)")
    TR.PostAdvice = function() return nil end
    Assert(sale:GetConfirmationMessage() == nil, "no advice: no confirmation")
    TR.PostAdvice = orig
    _G.AuctionHouseFrame = nil
end)

Check("Master Chef rank adds cooking results on average", function()
    local cook
    for _, t in pairs(ns.Data.allRecipes) do if t[2] == 6 and t[1] and t[1] ~= 0 then cook = t[1]; break end end
    Assert(cook, "a cooking product in the data")
    local base = ns.Lists.YieldOf(cook)
    ns.db.settings.masterChef = 5
    Assert(math.abs(ns.Lists.YieldOf(cook) - base * 1.5) < 1e-6, "rank 5: x1.5")
    Assert(ns.YieldBonus(2840) == 1, "not a cooking product: unchanged")
    ns.db.settings.masterChef = nil
    Assert(ns.Lists.YieldOf(cook) == base, "rank 0: unchanged")
end)

Check("mail: items attached to the game's send form move into the basket", function()
    local M = ns.Mail
    bags[0] = { [1] = { itemID = 781001, stackCount = 7 } }
    C_Container.PickupContainerItem(0, 1)
    ClickSendMailItemButton(1)
    Assert(attachments[1], "attached through the game's form")
    for k in pairs(M._basket) do M._basket[k] = nil end
    Assert(M.AdoptAttachments() == 1, "one attachment adopted")
    Assert(M._basket[781001] == 7, "in the basket with its count")
    Assert(next(attachments) == nil and bags[0][1] and bags[0][1].itemID == 781001, "form cleared, item back in the bag")
    M._basket[781001] = nil
    bags[0] = {}
end)

Check("mail rules: what goes where, keep, first match, never to yourself", function()
    local MR = ns.MailRules
    local inst = C_Item.GetItemInfoInstant
    -- 782001 leather, 782002 food, 782003 leather too.
    local types = { [782001] = { 7, 6 }, [782002] = { 0, 5 }, [782003] = { 7, 6 } }
    C_Item.GetItemInfoInstant = function(id) local t = types[id] or { 15, 0 }; return id, "", "", "", "icon", t[1], t[2] end
    ns.db.mailRules = {}
    MR.Add({ kind = "item", id = 782003 }, "Player-bank", 10)          -- this leather: keep 10
    MR.Add({ kind = "type", class = 7, sub = 6 }, "Player-bank", 0)    -- all leather to the bank
    MR.Add({ kind = "type", class = 0, sub = 5 }, "Player-cook", 0)    -- food to the cook
    local plan, why = MR.Plan({ [782001] = 40, [782002] = 12, [782003] = 25, [782009] = 5 }, "Player-alt")
    Assert(plan["Player-bank"][782001] == 40, "all leather to the bank")
    Assert(plan["Player-bank"][782003] == 15 and why[782003] == 1, "first rule wins: keeps 10")
    Assert(plan["Player-cook"][782002] == 12, "food to the cook")
    Assert(not (plan["Player-bank"][782009] or plan["Player-cook"][782009]), "unmatched item stays")
    local mine = MR.Plan({ [782001] = 40 }, "Player-bank")
    Assert(next(mine) == nil, "the bank never mails itself")
    ns.db.mailRules[2].off = true
    Assert(not (MR.Plan({ [782001] = 40 }, "Player-alt")["Player-bank"]), "a rule turned off does nothing")
    MR.Move(3, -1)
    Assert(ns.db.mailRules[2].what.kind == "type" and ns.db.mailRules[2].what.class == 0, "rules reorder")
    MR.Remove(1)
    Assert(#ns.db.mailRules == 2, "rule removed")
    -- The Send tab: "By rules" fills the basket for the bank, and the editor opens.
    bags[0] = { [1] = { itemID = 782001, stackCount = 20 } }
    ns.db.mailRules = {}
    MR.Add({ kind = "type", class = 7, sub = 6 }, "Player-bank", 0)
    ns.db.chars["Player-bank"] = ns.db.chars["Player-bank"] or { name = "Bankchar" }
    Fire("MAIL_SHOW"); ns.Mail.ShowOverlay(); ns.Mail.SetTab("send")
    ns.Mail.FillByRules()
    Assert(ns.Mail._basket[782001] == 20, "basket filled by the rules")
    ns.Mail.ShowRules()
    ns.Mail._DrawRules()
    for k in pairs(ns.Mail._basket) do ns.Mail._basket[k] = nil end
    ns.db.chars["Player-bank"] = nil
    bags[0] = {}
    Fire("MAIL_CLOSED")
    ns.db.mailRules = nil
    C_Item.GetItemInfoInstant = inst
end)

Check("item origins: sales split into farmed, trading and crafted", function()
    local O = ns.Origins
    local loot, tx = ns.db.loot, ns.db.tx
    local t = time() - 1000
    ns.db.loot = {
        { t = t, i = "Rugged Leather", id = 8170, n = 10, s = "l" },          -- farmed 10
        { t = t + 5, i = "Item 783002", id = 783002, n = 2, s = "c" },         -- crafted 2
        { t = t + 6, i = "Rugged Leather", id = 8170, n = 4, s = "p" },       -- mail pickup: ignored
    }
    ns.db.tx = {
        { t = t + 1, k = "ah_buy", i = "Rugged Leather", q = 5, a = -500 },   -- bought 5 at 100
        { t = t + 10, k = "ah_sale", i = "Rugged Leather", q = 12, a = 2400 }, -- 10 farmed + 2 bought, 200 each
        { t = t + 11, k = "ah_sale", i = "Item 783002", q = 1, a = 900 },
        { t = t + 12, k = "ah_sale", i = "Old Thing", q = 3, a = 300 },         -- owned before tracking
    }
    local s = O.SplitRaw(0)
    Assert(math.abs(s.farmed - (2000 + 300)) < 1e-6, "10 farmed units + old stock: " .. s.farmed)
    Assert(math.abs(s.bought - 400) < 1e-6 and s.boughtCost == 200, "2 bought units sold 400, paid 200")
    Assert(math.abs(s.trading - 200) < 1e-6, "trading profit 200")
    Assert(math.abs(s.crafted - 900) < 1e-6, "crafted 900")
    Assert(s.n == 3, "three sales")
    local held = O.Held()
    Assert(held["Rugged Leather"].bought == 3 and held["Rugged Leather"].paid == 300, "3 bought units still held")
    ns.db.loot, ns.db.tx = loot, tx
end)


print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
