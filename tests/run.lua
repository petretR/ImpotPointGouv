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

Check("repost advice explains itself (tooltip, not chat)", function()
    local TR = ns.Track
    local why, what, reason = TR.AdviceText({ streak = 1, lost = 300, vendor = 2500, edge = 200 })
    Assert(why and what and reason, "three texts")
    Assert(what:find("2500", 1, true) or what:find("25", 1, true), "advice shows the vendor price: " .. what)
    Assert(reason:find("200", 1, true) or reason:find("2", 1, true), "reason shows the AH edge: " .. reason)
    local _, w2, r2 = TR.AdviceText({ streak = 1, lost = 0 })
    Assert(w2 and r2, "first expiry: advice and reason")
    Assert(TR.StuckInBags == nil, "no more chat line when the AH opens")
end)


print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
