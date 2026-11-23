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

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
