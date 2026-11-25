-- ImpotPointGouv: detailed collection to analyse leveling income.
-- * Each vendor sale keeps the item (name, id, quality, level, bound or not, AH value at the time).
-- * Each looted item is noted (item, quantity, zone, source).
-- * Each operation keeps the character's zone and level; play time is counted per zone and per level.
-- * At a vendor: warns when an item is clearly worth more at the AH.
local _, ns = ...
local Tr = ns.L
local TR = {}
ns.Track = TR

local MAX_LOOT = 30000
local AH_CUT = 0.95
local merchantOpen, closedAt = false, 0
local cache = {}           -- ["bag:slot"] = item read (known state of the bags)
local unknown = {}         -- recent vendor sales without an identified item
local visit                -- summary of the vendor visit

-- ------------------------------------------------------------ helpers
local function Key() return ns.Ledger and ns.Ledger.CharKey() end

function TR.Zone()
    local id = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if id and ns.db then
        ns.db.zones = ns.db.zones or {}
        if not ns.db.zones[id] then
            local info = C_Map.GetMapInfo and C_Map.GetMapInfo(id)
            ns.db.zones[id] = (info and info.name) or (GetRealZoneText and GetRealZoneText()) or "?"
        end
    end
    return id
end

-- AH unit value: our scans, otherwise Auctionator (by exact link for "of the Bear" greens).
function TR.AHValue(id, link)
    local v = ns.Prices and ns.Prices.AHValue and ns.Prices.AHValue(id)
    if v and v > 0 then return v end
    local A = Auctionator and Auctionator.API and Auctionator.API.v1
    if A then
        if link and A.GetAuctionPriceByItemLink then
            local ok, p = pcall(A.GetAuctionPriceByItemLink, "ImpotPointGouv", link)
            if ok and p and p > 0 then return p end
        end
        if id and A.GetAuctionPriceByItemID then
            local ok, p = pcall(A.GetAuctionPriceByItemID, "ImpotPointGouv", id)
            if ok and p and p > 0 then return p end
        end
    end
end

-- Is it clearly worth more at the AH (after commission)? Returns the missed gain per unit.
function TR.BetterAtAH(vs, mv)
    if not mv or mv <= 0 then return nil end
    vs = vs or 0
    local net = math.floor(mv * AH_CUT)
    if net >= vs * 2 and net - vs >= 2000 then return net - vs end
end

local function LastBag() return NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + 1) end

local function ReadSlot(bag, slot)
    local info = C_Container and C_Container.GetContainerItemInfo(bag, slot)
    if not info or not info.itemID then return nil end
    local link = info.hyperlink
    local name, _, q, il, _, _, _, _, _, _, vs, cls = ns.GetItemInfo(link or info.itemID)
    if GetDetailedItemLevelInfo and link then il = GetDetailedItemLevelInfo(link) or il end
    return {
        id = info.itemID, link = link, n = info.stackCount or 1,
        name = (link and link:match("%[(.-)%]")) or name,
        qu = q or info.quality, il = il, vs = (not info.hasNoValue) and vs or 0, cl = cls,
        b = info.isBound and 1 or nil,
    }
end

local function Snapshot()
    local out = {}
    if not C_Container then return out end
    for bag = 0, LastBag() do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local r = ReadSlot(bag, slot)
            if r then out[bag .. ":" .. slot] = r end
        end
    end
    return out
end

local function InfoOf(r, n)
    return { i = r.name, q = n or r.n, id = r.id, qu = r.qu, il = r.il, b = r.b, cl = r.cl,
             mv = TR.AHValue(r.id, r.link) }
end

local function Annotate(tx, r, n)
    local info = InfoOf(r, n)
    tx.i, tx.q, tx.id, tx.qu, tx.il, tx.b, tx.cl, tx.mv = info.i, info.q, info.id, info.qu, info.il, info.b, info.cl, info.mv
end

-- ------------------------------------------------------------ vendor sales
-- Right-click (or another addon selling through UseContainerItem): announce the expected amount to the ledger.
local function OnUse(bag, slot)
    if not merchantOpen or not bag or not slot then return end
    local r = ReadSlot(bag, slot) or cache[bag .. ":" .. slot]
    if not r or not r.vs or r.vs <= 0 then return end
    ns.Ledger.Expect({ amount = r.vs * r.n, k = "vendor_sell", ttl = 8, info = InfoOf(r) })
end

-- Fallback: the sale could not be linked to an item (drag and drop, grouped sales...).
-- Compare the bags before / after to find what left.
local recentLost = {}      -- stacks gone from the bags in the last seconds { r, n, v, at }

local function Match()
    local now = GetTime()
    for i = #unknown, 1, -1 do if now - unknown[i].at > 15 then tremove(unknown, i) end end
    for i = #recentLost, 1, -1 do if now - recentLost[i].at > 15 then tremove(recentLost, i) end end
    for ui = #unknown, 1, -1 do
        local tx = unknown[ui].tx
        local hit
        for li, l in ipairs(recentLost) do if l.v == tx.a then hit = li; break end end
        if hit then
            Annotate(tx, recentLost[hit].r, recentLost[hit].n); tremove(recentLost, hit); tremove(unknown, ui)
            TR.OnVendorSale(tx)
        elseif #recentLost > 1 then
            local sum = 0
            for _, l in ipairs(recentLost) do sum = sum + l.v end
            if sum == tx.a then
                -- A single gold change for several items: split it.
                local lost = recentLost; recentLost = {}
                tremove(unknown, ui)
                Annotate(tx, lost[1].r, lost[1].n); tx.a = lost[1].v
                TR.OnVendorSale(tx)
                for k = 2, #lost do
                    local extra = ns.Ledger.AddTx("vendor_sell", lost[k].v, InfoOf(lost[k].r, lost[k].n))
                    extra.t = tx.t -- (TX_ADDED already counted it in the visit)
                end
            end
        end
    end
end

-- The order "gold received" / "bag updated" varies: keep both sides for a few seconds and match them.
local function Reconcile()
    local new = Snapshot()
    local now = GetTime()
    for key, old in pairs(cache) do
        local cur = new[key]
        local left = (cur and cur.id == old.id) and cur.n or 0
        if old.n > left and old.vs and old.vs > 0 then
            recentLost[#recentLost + 1] = { r = old, n = old.n - left, v = (old.n - left) * old.vs, at = now }
        end
    end
    cache = new
    Match()
end

function TR.OnVendorSale(tx)
    if not visit then visit = { n = 0, gold = 0, missed = 0, missedN = 0 } end
    visit.n = visit.n + (tx.q or 1)
    visit.gold = visit.gold + tx.a
    if tx.b or not tx.id then return end
    local unit = (tx.q and tx.q > 0) and math.floor(tx.a / tx.q) or tx.a
    local gain = TR.BetterAtAH(unit, tx.mv)
    if gain then
        visit.missed = visit.missed + gain * (tx.q or 1)
        visit.missedN = visit.missedN + 1
        if ns.db.settings.vendorHints ~= false then
            ns.Print((Tr("%s sold %s  ·  AH ~%s")):format(tx.i or "?", ns.FormatMoney(tx.a, { iconSize = 11 }),
                ns.FormatMoney(math.floor(tx.mv * (tx.q or 1)), { iconSize = 11 })))
        end
    end
end

local function OnTx(tx)
    if tx.k ~= "vendor_sell" then return end
    if tx.id then
        TR.OnVendorSale(tx)
        -- Sale already identified: its vanished stack must not serve another one.
        for i, l in ipairs(recentLost) do if l.r.id == tx.id and l.v == tx.a then tremove(recentLost, i); break end end
    else
        unknown[#unknown + 1] = { tx = tx, at = GetTime() }
        Match()
    end
end

local function EndVisit()
    if visit and visit.n > 0 then
        local msg = (Tr("vendor: %d item%s, %s")):format(visit.n, visit.n == 1 and "" or "s", ns.FormatMoney(visit.gold, { iconSize = 11 }))
        if visit.missedN > 0 then
            msg = msg .. (Tr("  ·  |cffe0a83d%d worth more at the AH (+%s)|r")):format(visit.missedN, ns.FormatMoney(visit.missed, { iconSize = 11 }))
        end
        ns.Print(msg)
    end
    visit = nil
end

-- ------------------------------------------------------------ loot
local function Pat(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
    return "^" .. p .. "$"
end

local PATTERNS -- { pattern, source, multiple }
local function Patterns()
    if PATTERNS then return PATTERNS end
    PATTERNS = {}
    local function add(g, src, multi) local p = Pat(_G[g]); if p then PATTERNS[#PATTERNS + 1] = { p, src, multi } end end
    add("LOOT_ITEM_SELF_MULTIPLE", "l", true)
    add("LOOT_ITEM_SELF", "l")
    add("LOOT_ITEM_PUSHED_SELF_MULTIPLE", "p", true)
    add("LOOT_ITEM_PUSHED_SELF", "p")
    add("LOOT_ITEM_CREATED_SELF_MULTIPLE", "c", true)
    add("LOOT_ITEM_CREATED_SELF", "c")
    return PATTERNS
end

local questUntil = 0
local function OnLoot(text)
    if not ns.db or not text then return end
    for _, pt in ipairs(Patterns()) do
        local link, n = text:match(pt[1])
        if link then
            local id = tonumber(link:match("item:(%d+)"))
            if not id then return end
            local src = pt[2]
            if src == "p" then
                if merchantOpen or GetTime() - closedAt < 2 then src = "v"         -- bought from the vendor
                elseif GetTime() < questUntil then src = "q"                       -- quest reward
                end
            end
            local _, _, q, il, _, _, _, _, _, _, vs = ns.GetItemInfo(link)
            local log = ns.db.loot
            log[#log + 1] = { t = time(), c = Key(), id = id, n = tonumber(n) or 1, z = TR.Zone(), s = src,
                              qu = q, il = il, vs = vs, i = link:match("%[(.-)%]") }
            if #log > MAX_LOOT then tremove(log, 1) end
            return
        end
    end
end

-- ------------------------------------------------------------ play time per zone and per level
local function Tick()
    if not ns.db then return end
    local key = Key()
    if not key or (UnitIsAFK and UnitIsAFK("player")) then return end
    ns.db.zt = ns.db.zt or {}
    ns.db.lt = ns.db.lt or {}
    local z = TR.Zone() or 0
    local lvl = UnitLevel and UnitLevel("player") or 0
    local zt = ns.db.zt[key] or {}; ns.db.zt[key] = zt
    local lt = ns.db.lt[key] or {}; ns.db.lt[key] = lt
    zt[z] = (zt[z] or 0) + 60
    lt[lvl] = (lt[lvl] or 0) + 60
end

-- ------------------------------------------------------------ items that do not sell
-- Per item (name) since its last sale: number of "expired" returns and lost deposits.
-- Returns from the same mail round (same batch) count as a single failure.
local hist, histN
local function BuildHistory()
    local tx = ns.db.tx
    if hist and histN == #tx and tx[#tx] == hist._last then return hist end
    hist = {}
    local open = {}  -- deposits of listings still running (name -> list)
    for _, t in ipairs(tx) do
        local name = t.i
        if name and (t.k == "ah_deposit" or t.k == "ah_sale" or t.k == "ah_expired" or t.k == "ah_cancelled") then
            local h = hist[name]
            if not h then h = { streak = 0, lost = 0, fails = 0, sales = 0 }; hist[name] = h end
            if t.k == "ah_deposit" then
                open[name] = open[name] or {}
                table.insert(open[name], -(t.a or 0))
            elseif t.k == "ah_sale" then
                h.streak, h.lost, h.sales, h.lastSale = 0, 0, h.sales + 1, t.t
                local o = open[name]; if o and #o > 0 then tremove(o, 1) end
            else
                local o = open[name]
                local dep = (o and #o > 0) and tremove(o, 1) or 0
                h.lost = h.lost + dep
                if t.k == "ah_expired" then
                    if not h.lastFail or t.t - h.lastFail > 600 then h.streak = h.streak + 1 end
                    h.fails, h.lastFail = h.fails + 1, t.t
                end
            end
        end
    end
    histN, hist._last = #tx, tx[#tx]
    return hist
end

-- Advice for an item: nil (nothing to report), or { streak, lost, pauseUntil?, vendor? }.
-- * 1 failure: nothing to say (an auction often expires once: undercut, quiet hours).
-- * 2 failures in a row: pause 1 day, then 2, 4… (7 days max).
-- * 3 failures, or lost deposits > what the AH earns above the vendor: sell to the vendor.
function TR.PostAdvice(name, id)
    if not name or not ns.db then return nil end
    local h = BuildHistory()[name]
    if not h or h.streak == 0 then return nil end
    local adv = { streak = h.streak, lost = h.lost, sales = h.sales }
    if h.streak >= 2 then
        local pause = math.min(7, 2 ^ (h.streak - 2)) * 86400
        if time() < (h.lastFail or 0) + pause then adv.pauseUntil = h.lastFail + pause end
    end
    local vs = (id and ns.Prices.VendorSell(id)) or 0
    local mv = id and TR.AHValue(id)
    local edge = mv and (math.floor(mv * AH_CUT) - vs) or nil
    if vs and vs > 0 and (h.streak >= 3 or (edge and h.lost >= edge)) then adv.vendor, adv.edge = vs, edge end
    if not adv.vendor and not adv.pauseUntil then return nil end
    return adv
end

-- The advice in one short line: what happened and what to do.
function TR.AdviceText(adv)
    if not adv then return nil end
    local function M(v) return ns.FormatMoney(v, { iconSize = 10 }) end
    if adv.vendor then
        if adv.streak >= 3 then
            return (Tr("Expired %d× in a row: sell it to a vendor (%s).")):format(adv.streak, M(adv.vendor))
        end
        return (Tr("Expired %d×: a vendor pays %s, the AH only %s more.")):format(adv.streak, M(adv.vendor),
            M(math.max(0, adv.edge or 0)))
    elseif adv.pauseUntil then
        local left = adv.pauseUntil - time()
        local wait = left >= 86400 * 1.5 and (Tr("%d days")):format(math.floor(left / 86400 + 0.5))
            or (Tr("%dh")):format(math.max(1, math.floor(left / 3600 + 0.5)))
        return (Tr("Expired %d× in a row: wait %s before posting it again.")):format(adv.streak, wait)
    end
end

-- ------------------------------------------------------------ tooltips (vendor and AH)
local function TooltipHint(tt, data)
    if tt ~= GameTooltip or not data or not data.id or ns.db.settings.vendorHints == false then return end
    local atAH = AuctionHouseFrame and AuctionHouseFrame:IsShown()
    if not merchantOpen and not atAH then return end
    for _, line in ipairs(data.lines or {}) do
        if line.leftText == ITEM_SOULBOUND or line.leftText == ITEM_ACCOUNTBOUND then return end
    end
    local link = tt.GetItem and select(2, tt:GetItem())
    local name = (link and link:match("%[(.-)%]")) or ns.GetItemInfo(data.id)
    local adv = TR.PostAdvice(name, data.id)
    if adv then
        tt:AddLine("|cffe0a83dIPG|r  " .. TR.AdviceText(adv), 0.93, 0.55, 0.32, true)
        tt:Show()
        return
    end
    if not merchantOpen then return end
    local vs = select(11, ns.GetItemInfo(link or data.id)) or 0
    local mv = TR.AHValue(data.id, link)
    if TR.BetterAtAH(vs, mv) then
        tt:AddLine((Tr("|cffe0a83dAH ~%s|r  ·  vendor %s  —  keep it for the AH")):format(
            ns.FormatMoney(mv, { iconSize = 11 }), ns.FormatMoney(vs, { iconSize = 11 })))
        tt:Show()
    end
end

-- ------------------------------------------------------------ Auctionator's Selling tab
-- When you post an item that keeps expiring, Auctionator's own "Post anyway?" confirmation (the one it shows
-- when a vendor pays more) also says to wait or to vendor it. Only for "wait" and "vendor it".
-- Auctionator keeps its methods on the frame (mixin copied at creation): the frame's method is wrapped once.
local function PostWarning(sale)
    local info = sale and sale.itemInfo
    if not info or not info.itemLink or ns.db.settings.vendorHints == false then return nil end
    local name = info.itemLink:match("%[(.-)%]") or info.itemName
    local adv = TR.PostAdvice(name, info.itemID)
    if not adv or not (adv.pauseUntil or adv.vendor) then return nil end
    return "|cffe0a83dImpotPointGouv|r\n" .. TR.AdviceText(adv) .. "\n\n" .. Tr("Post anyway?")
end
TR._PostWarning = PostWarning

local function HookAuctionator()
    local sell = AuctionHouseFrame and AuctionHouseFrame.AuctionatorSellingFrame
    local sale = sell and sell.SaleItemFrame
    if not sale or sale.ipgHooked or type(sale.GetConfirmationMessage) ~= "function" then return end
    sale.ipgHooked = true
    local orig = sale.GetConfirmationMessage
    sale.GetConfirmationMessage = function(self, ...)
        local msg = orig(self, ...)
        if msg then return msg end
        local ok, warn = pcall(PostWarning, self)
        return ok and warn or nil
    end
end
TR._HookAuctionator = HookAuctionator

-- ------------------------------------------------------------ quick report (/ipg sold)
function TR.Report(days)
    days = days or 7
    local t0 = time() - days * 86400
    local byItem, total, n, missed = {}, 0, 0, 0
    for _, tx in ipairs(ns.db.tx) do
        if tx.t >= t0 and tx.k == "vendor_sell" then
            total, n = total + tx.a, n + 1
            local k = tx.i or "?"
            local e = byItem[k] or { a = 0, q = 0, miss = 0 }; byItem[k] = e
            e.a, e.q = e.a + tx.a, e.q + (tx.q or 1)
            if not tx.b and tx.mv then
                local unit = (tx.q and tx.q > 0) and math.floor(tx.a / tx.q) or tx.a
                local g = TR.BetterAtAH(unit, tx.mv)
                if g then e.miss = e.miss + g * (tx.q or 1); missed = missed + g * (tx.q or 1) end
            end
        end
    end
    local list = {}
    for k, e in pairs(byItem) do e.name = k; list[#list + 1] = e end
    table.sort(list, function(a, b) return a.a > b.a end)
    ns.Print((Tr("vendor sales, last %d days: %d sales, %s")):format(days, n, ns.FormatMoney(total, { iconSize = 11 })))
    for i = 1, math.min(10, #list) do
        local e = list[i]
        ns.Print(("  %s ×%d  %s%s"):format(e.name, e.q, ns.FormatMoney(e.a, { iconSize = 11 }),
            e.miss > 0 and (Tr("  |cffe0a83d(+%s at AH)|r")):format(ns.FormatMoney(e.miss, { iconSize = 11 })) or ""))
    end
    if missed > 0 then ns.Print((Tr("|cffe0a83dleft on the table vs the AH: %s|r")):format(ns.FormatMoney(missed, { iconSize = 11 }))) end
end

-- ------------------------------------------------------------ events
local f = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(f, "Track") end
for _, ev in ipairs({ "AUCTION_HOUSE_SHOW", "MERCHANT_SHOW", "MERCHANT_CLOSED", "BAG_UPDATE_DELAYED", "CHAT_MSG_LOOT",
                      "QUEST_COMPLETE", "QUEST_TURNED_IN", "PLAYER_ENTERING_WORLD" }) do
    pcall(f.RegisterEvent, f, ev)
end

local started = false
f:SetScript("OnEvent", function(_, event, ...)
    if not ns.db then return end
    if event == "PLAYER_ENTERING_WORLD" then
        ns.db.loot = ns.db.loot or {}
        if started then return end
        started = true
        if C_Container and C_Container.UseContainerItem then hooksecurefunc(C_Container, "UseContainerItem", OnUse) end
        if type(UseContainerItem) == "function" and UseContainerItem ~= (C_Container and C_Container.UseContainerItem) then
            hooksecurefunc("UseContainerItem", OnUse)
        end
        if TooltipDataProcessor and Enum and Enum.TooltipDataType then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, TooltipHint)
        end
        if C_Timer then C_Timer.NewTicker(60, Tick) end
        ns.On("TX_ADDED", OnTx)
    elseif event == "AUCTION_HOUSE_SHOW" then
        -- Auctionator builds its tabs when the AH opens.
        if C_Timer then C_Timer.After(1, HookAuctionator) else HookAuctionator() end
    elseif event == "MERCHANT_SHOW" then
        merchantOpen = true; visit = nil
        cache = Snapshot()
    elseif event == "MERCHANT_CLOSED" then
        if merchantOpen then
            merchantOpen, closedAt = false, GetTime()
            -- Lets the last sales arrive before the summary.
            if C_Timer then C_Timer.After(2, function() Reconcile(); EndVisit() end) else EndVisit() end
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        if merchantOpen or GetTime() - closedAt < 3 then Reconcile() end
    elseif event == "CHAT_MSG_LOOT" then
        OnLoot(...)
    elseif event == "QUEST_COMPLETE" or event == "QUEST_TURNED_IN" then
        questUntil = GetTime() + 3
    end
end)
