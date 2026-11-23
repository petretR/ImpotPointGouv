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

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
