-- ImpotPointGouv: estimate of what sells across the whole AH, professions or not.
-- The AH never shows other people's sales: two successive full scans are compared, and the
-- quantities that vanished count as sold (cancels and expiries included: an estimate).
local _, ns = ...
local Tr = ns.L
local T, P = ns.Theme, ns.Prices
local C = T.C
local M = {}
ns.Market = M

local MAX_GAP = 48 * 3600   -- beyond that, the gap between two scans says nothing useful
local KEEP_DAYS = 7

local function Realm() return ns.Realm() end
local function Today() return math.floor(time() / 86400) end
local function DB()
    ns.db.market = ns.db.market or {}
    local r = Realm()
    ns.db.market[r] = ns.db.market[r] or { items = {}, obs = {}, scans = 0 }
    return ns.db.market[r]
end

-- Item class without cache (works for any ID).
local function Instant(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f then return nil end
    local ok, _, _, _, equipLoc, icon, classID, subID = pcall(f, id)
    if ok then return classID, subID, icon, equipLoc end
end

-- Called at the end of each full scan with { [id] = { low, qty } }.
function M.OnFullScan(acc)
    local db = DB()
    local now, day = time(), Today()
    local prev = db.last
    if prev and prev.t and now - prev.t > 60 and now - prev.t <= MAX_GAP then
        local gap = now - prev.t
        db.obs[day] = (db.obs[day] or 0) + gap
        for id, q0 in pairs(prev.q) do
            local a = acc[id]
            local drop = q0 - (a and a.qty or 0)
            if drop > 0 then
                local it = db.items[id]
                if not it then it = { d = {} }; db.items[id] = it end
                it.d[day] = (it.d[day] or 0) + drop
            end
        end
    end
    local snap = { t = now, q = {} }
    for id, a in pairs(acc) do
        snap.q[id] = a.qty
        local it = db.items[id]
        if it then it.seen = now end
    end
    db.last = snap
    db.scans = (db.scans or 0) + 1
    M.ScanFlips(acc)
    M.StoreBooks(acc)
    -- Purge: older than 7 days.
    local minDay = day - KEEP_DAYS
    for d in pairs(db.obs) do if d < minDay then db.obs[d] = nil end end
    for id, it in pairs(db.items) do
        for d in pairs(it.d) do if d < minDay then it.d[d] = nil end end
        if not next(it.d) then db.items[id] = nil end
    end
    M.dirty = true
    ns.Fire("MARKET_CHANGED")
end

-- ------------------------------------------------------------ market depth (materials)
-- For each material of your recipes: how many units are listed at each price (40 cheapest levels).
-- Used to say "craft 30 while the cloth stays under 24c".
function M.StoreBooks(acc)
    local ids = {}
    for _, list in pairs(ns.db.recipes or {}) do
        for _, r in pairs(list) do
            for _, rg in ipairs(r.r or {}) do if rg[1] then ids[rg[1]] = true end end
        end
    end
    local db = DB()
    db.book = db.book or {}
    local now = time()
    for id in pairs(ids) do
        local a = acc[id]
        if a and a.b then
            local prices = {}
            for unit in pairs(a.b) do prices[#prices + 1] = unit end
            table.sort(prices)
            local flat = {}
            for i = 1, math.min(40, #prices) do
                flat[#flat + 1] = prices[i]; flat[#flat + 1] = a.b[prices[i]]
            end
            db.book[id] = { t = now, l = flat }
        elseif not a then
            db.book[id] = { t = now, l = {} } -- nothing listed
        end
    end
end

-- Records the price ladder of a material (commodity search): { [price] = quantity }.
function M.SetBook(id, ladder)
    local db = DB()
    db.book = db.book or {}
    local prices = {}
    for unit in pairs(ladder) do prices[#prices + 1] = unit end
    table.sort(prices)
    local flat = {}
    for i = 1, math.min(40, #prices) do flat[#flat + 1] = prices[i]; flat[#flat + 1] = ladder[prices[i]] end
    db.book[id] = { t = time(), l = flat }
end

-- Levels { price, quantity } of a material, and the age of the scan.
function M.Book(id)
    local b = DB().book and DB().book[id]
    if not b then return nil end
    local out = {}
    for i = 1, #b.l, 2 do out[#out + 1] = { b.l[i], b.l[i + 1] } end
    return out, time() - (b.t or 0)
end

-- ------------------------------------------------------------ vendor flip
-- Listings under the vendor price: buy then resell to the vendor. The vendor price comes from the game
-- (GetItemInfo); for items not cached yet, it is requested in the background, without hovering.
local lastAcc, waiting = nil, {}
local MIN_UNIT_GAIN = 1

local function FlipOf(id, a)
    local vs = P.VendorSell(id)
    if not vs or not a or not a.b then return nil end
    local units, cost = 0, 0
    for unit, count in pairs(a.b) do
        if unit <= vs - MIN_UNIT_GAIN then units = units + count; cost = cost + unit * count end
    end
    if units == 0 then return nil end
    return { id = id, units = units, cost = cost, gain = vs * units - cost, vs = vs, low = a.low }
end

local function StoreFlip(f, id)
    local db = DB()
    db.flips = db.flips or { t = time(), list = {} }
    db.flips.list[id] = f and { u = f.units, c = f.cost, g = f.gain, v = f.vs, l = f.low } or nil
end

function M.ScanFlips(acc)
    lastAcc = acc
    local db = DB()
    db.flips = { t = time(), list = {} }
    wipe(waiting)
    local ask = {}
    for id, a in pairs(acc) do
        if P.VendorSell(id) then StoreFlip(FlipOf(id, a), id)
        else waiting[id] = true; ask[#ask + 1] = id end
    end
    -- Requests missing info in small batches (the game answers with GET_ITEM_INFO_RECEIVED).
    local i = 0
    local function Batch()
        for _ = 1, 40 do
            i = i + 1
            local id = ask[i]
            if not id then return end
            ns.RequestItem(id)
        end
        C_Timer.After(0.1, Batch)
    end
    Batch()
end

function M.OnItemInfo(id)
    if not id or not waiting[id] or not lastAcc then return end
    if P.VendorSell(id) ~= nil or select(11, ns.GetItemInfo(id)) then
        waiting[id] = nil
        StoreFlip(FlipOf(id, lastAcc[id]), id)
        M.dirty = true
    end
end

function M.Flips()
    local db = DB()
    local out, minGain = {}, ns.Craft and ns.Craft.Rules().minProfit or 10
    if not db.flips then return out, nil end
    local bought = ns.db.flipBought or {}
    for id, f in pairs(db.flips.list) do
        if f.g >= minGain then
            out[#out + 1] = { id = id, units = f.u, cost = f.c, gain = f.g, vs = f.v, cur = f.l, rate = M.Rate(id),
                listed = (P.Entry(id) and P.Entry(id).qty) or 0 }
        end
    end
    table.sort(out, function(a, b) return a.gain > b.gain end)
    return out, db.flips.t
end

function M.FlipCount()
    local db = DB()
    if not db.flips or time() - (db.flips.t or 0) > 6 * 3600 then return 0 end
    return #(M.Flips())
end

-- Buying a flip (stackable items): 1st click = price, 2nd click = confirm if still profitable.
local mb
local ahOpen = false
local function IsAHOpen() return ahOpen or (AuctionHouseFrame and AuctionHouseFrame:IsShown()) or false end
function M.Buying() return mb end

-- A purchase done: remove it from the list and remember what to resell to the vendor.
local function Bought(id, qty)
    ns.db.flipBought = ns.db.flipBought or {}
    ns.db.flipBought[id] = (ns.db.flipBought[id] or 0) + qty
    local db = DB()
    local f = db.flips and db.flips.list[id]
    if f then
        f.u = f.u - qty
        if f.u <= 0 then db.flips.list[id] = nil else f.g = f.g * f.u / (f.u + qty) end
    end
end

-- 1st click: checks the actual price; 2nd click: confirms. Stackable = whole lot; gear = one listing per click.
function M.Buy(row)
    local AH = C_AuctionHouse
    if not AH or not IsAHOpen() then M.Msg(Tr("Open the auction house to buy.")); return end
    if mb and mb.stage == "confirm" and mb.id == row.id then
        mb.stage = "wait"
        M.Msg((Tr("Buying %d× %s…")):format(mb.qty, P.Name(mb.id)))
        if mb.item then
            AH.PlaceBid(mb.auctionID, mb.price)
            -- No reliable confirmation event for gear: the purchase is considered done without an error.
            local my = mb
            C_Timer.After(1.5, function()
                if mb == my and mb.stage == "wait" then
                    Bought(my.id, my.qty)
                    mb = nil
                    M.Msg((Tr("Bought %s: sell it at any vendor (merchant bar > Sell to vendor).")):format(P.Name(my.id)))
                end
            end)
        else
            AH.ConfirmCommoditiesPurchase(mb.id, mb.qty)
        end
        return
    end
    if mb then return end
    if ns.IsCommodity(row.id) then
        mb = { id = row.id, qty = row.units, vs = row.vs, stage = "price" }
        M.Msg((Tr("Getting the price for %d× %s…")):format(row.units, P.Name(row.id)))
        AH.StartCommoditiesPurchase(row.id, row.units)
    else
        mb = { id = row.id, vs = row.vs, stage = "search", item = true }
        M.Msg((Tr("Looking for %s under %s…")):format(P.Name(row.id), ns.FormatMoney(row.vs, { iconSize = 10 })))
        AH.SendSearchQuery(AH.MakeItemKey(row.id), { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }, false)
        local my = mb
        C_Timer.After(5, function() if mb == my and mb.stage == "search" then mb = nil; M.Msg(Tr("No answer from the AH, click again.")) end end)
    end
    ns.Fire("MARKET_CHANGED")
end

function M.Msg(text)
    if P.Status then P.Status(text) end
    M.lastMsg, M.lastMsgT = text, GetTime()
    ns.Fire("MARKET_CHANGED")
end

local function EndBuy(msg)
    if mb and mb.stage == "confirm" and not mb.item and C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then
        pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    end
    mb = nil
    if msg then M.Msg(msg) end
end

local function OnItemResults(itemKey)
    if not mb or mb.stage ~= "search" or not itemKey or itemKey.itemID ~= mb.id then return end
    local AH = C_AuctionHouse
    for k = 1, (AH.GetNumItemSearchResults(itemKey) or 0) do
        local r = AH.GetItemSearchResultInfo(itemKey, k)
        local qty = (r and r.quantity) or 1
        if r and r.buyoutAmount and not r.containsOwnerItem and r.buyoutAmount / qty <= mb.vs - 1 then
            mb.auctionID, mb.price, mb.qty, mb.stage = r.auctionID, r.buyoutAmount, qty, "confirm"
            M.Msg((Tr("Buy %s for %s, vendor pays %s (+%s)? Click Confirm.")):format(P.Name(mb.id),
                ns.FormatMoney(r.buyoutAmount, { iconSize = 10 }), ns.FormatMoney(mb.vs * qty, { iconSize = 10 }),
                ns.FormatMoney(mb.vs * qty - r.buyoutAmount, { iconSize = 10 })))
            return
        end
    end
    local id = mb.id
    local db = DB()
    if db.flips then db.flips.list[id] = nil end
    EndBuy((Tr("%s: none left under the vendor price (someone bought it).")):format(P.Name(id)))
end

local bev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(bev, "Market") end
for _, e in ipairs({ "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED",
    "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "ITEM_SEARCH_RESULTS_UPDATED",
    "UI_ERROR_MESSAGE" }) do pcall(bev.RegisterEvent, bev, e) end
bev:SetScript("OnEvent", function(_, event, unit, total)
    if event == "AUCTION_HOUSE_SHOW" then ahOpen = true; ns.Fire("MARKET_CHANGED"); return end
    if event == "AUCTION_HOUSE_CLOSED" then ahOpen = false; EndBuy(); ns.Fire("MARKET_CHANGED"); return end
    if not mb then return end
    if event == "ITEM_SEARCH_RESULTS_UPDATED" then
        OnItemResults(unit)
    elseif event == "UI_ERROR_MESSAGE" and mb.stage == "wait" and mb.item then
        EndBuy((Tr("Purchase refused: %s")):format(type(total) == "string" and total or tostring(unit)))
    elseif event == "COMMODITY_PRICE_UPDATED" and mb.stage == "price" then
        local gain = mb.vs * mb.qty - (total or math.huge)
        if not total or gain <= 0 then
            EndBuy((Tr("%s: price went up, no profit left (someone bought them).")):format(P.Name(mb.id)))
        else
            mb.stage, mb.total = "confirm", total
            M.Msg((Tr("Buy %d× %s for %s, vendor pays %s (+%s)? Click Confirm.")):format(mb.qty, P.Name(mb.id),
                ns.FormatMoney(total, { iconSize = 10 }), ns.FormatMoney(mb.vs * mb.qty, { iconSize = 10 }),
                ns.FormatMoney(gain, { iconSize = 10 })))
        end
    elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
        EndBuy(Tr("Not available anymore."))
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
        Bought(mb.id, mb.qty)
        local msg = (Tr("Bought %d× %s: sell them at any vendor (merchant bar > Sell to vendor).")):format(mb.qty, P.Name(mb.id))
        mb = nil
        M.Msg(msg)
    elseif event == "COMMODITY_PURCHASE_FAILED" then
        EndBuy(Tr("Purchase failed (price changed or not enough gold)."))
    end
end)

-- Hours observed over 7 days.
function M.ObservedHours()
    local s = 0
    for _, v in pairs(DB().obs) do s = s + v end
    return s / 3600
end

-- Estimated sales per day for an item.
function M.Rate(id)
    local db = DB()
    local it = db.items[id]
    if not it then return 0 end
    local obs = 0
    for _, v in pairs(db.obs) do obs = obs + v end
    if obs <= 0 then return 0 end
    local units = 0
    for _, v in pairs(it.d) do units = units + v end
    return units / obs * 86400
end

-- ------------------------------------------------------------ categories
-- Raw materials: what you farm (cloth, leather, ore, meat/fish, herbs, elemental, enchanting).
local RAW = { [5] = "Cloth", [6] = "Leather", [7] = "Metal & Stone", [8] = "Cooking", [9] = "Herb", [10] = "Elemental", [12] = "Enchanting" }
M.FILTERS = {
    { "all", "All" }, { "raw", "Farm" }, { "gear", "Gear" }, { "consum", "Consumables" }, { "flip", "AH flip" },
    { "vflip", "Vendor flip" }, { "vcraft", "Vendor crafts" },
}

local function Category(id)
    local classID, subID = Instant(id)
    if classID == 7 and RAW[subID] then return "raw", RAW[subID] end
    if classID == 2 or classID == 4 then return "gear" end
    if classID == 0 then return "consum" end
    return "other"
end
M.Category = Category

-- Sorted list for a filter. Flip: current listing far below the usual price, item that sells.
function M.List(filter)
    local db = DB()
    local out = {}
    local obs = 0
    for _, v in pairs(db.obs) do obs = obs + v end
    if obs <= 0 then return out end
    local deposit = ns.Craft and ns.Craft.Rules().deposit or 100
    for id, it in pairs(db.items) do
        local units = 0
        for _, v in pairs(it.d) do units = units + v end
        local rate = units / obs * 86400
        if rate >= 0.5 then
            local cat, sub = Category(id)
            local e = P.Entry(id)
            local market = P.Market(id)
            local cur = e and e.cur
            local price = market or cur
            if price and price > 0 then
                local row = { id = id, rate = rate, price = price, cur = cur, market = market, listed = e and e.qty or 0,
                    gold = rate * price, cat = cat, sub = sub }
                local keep = filter == "all" or filter == cat
                if filter == "flip" then
                    keep = false
                    if cur and market and cur < market * 0.7 and rate >= 1 then
                        row.gain = market * 0.95 - cur - deposit
                        keep = row.gain > 0
                    end
                end
                if keep then out[#out + 1] = row end
            end
        end
    end
    if filter == "flip" then
        table.sort(out, function(a, b) return a.gain > b.gain end)
    else
        table.sort(out, function(a, b) return a.gold > b.gold end)
    end
    return out
end

-- ------------------------------------------------------------ crafts that pay at a vendor
-- Every recipe of every profession whose product sells to a vendor for more than its materials
-- (bought now at the AH, or at the vendor for supplies). No risk: the vendor buys everything.
local function BuyNow(id)
    if P.IsVendorItem(id) then
        local v = P.VendorBuy(id)
        if v then return v, math.huge end
    end
    local e = P.Entry(id)
    if e and e.cur and e.t and time() - e.t < 2 * 86400 and (e.qty or 0) > 0 then return e.cur, e.qty end
    local m = P.Market(id)
    if m then return m, 0 end
end

function M.VendorCrafts()
    local RO = ns.Route
    local out, waiting = {}, 0
    if not RO then return out, 0 end
    for prof in pairs(RO.AL_PROF) do
        local known = RO.KnownSet(prof)
        local skill, who = RO.CurrentSkill(prof)
        for _, r in ipairs(RO.Recipes(prof)) do
            if r.out and #r.mats > 0 then
                local cost, maxN, ok = 0, math.huge, true
                for _, m in ipairs(r.mats) do
                    local p, avail = BuyNow(m[1])
                    if not p then ok = false; break end
                    cost = cost + p * m[2]
                    maxN = math.min(maxN, math.floor((avail or 0) / m[2]))
                end
                if ok then
                    local vs = P.VendorSell(r.out)
                    if not vs and not ns.GetItemInfo(r.out) then
                        waiting = waiting + 1
                        ns.RequestItem(r.out)
                    end
                    local gain = vs and (vs * r.n - cost)
                    if gain and gain > 0 then
                        r.name = r.name or RO.SpellName(r.spell)
                        local F, label, qty, est = RO.Access(r, known, {})
                        out[#out + 1] = { id = r.out, rec = r, prof = prof, gain = gain, cost = cost, vs = vs * r.n,
                            units = r.cd and math.min(maxN, 1) or maxN, skill = r.o, mySkill = skill, who = who,
                            access = F, label = label, est = est, rate = 0, listed = 0 }
                    end
                end
            end
        end
    end
    -- Recipes you can craft right now first, then gain per craft.
    table.sort(out, function(a, b)
        local ra = a.label == "known" and a.mySkill >= a.skill
        local rb = b.label == "known" and b.mySkill >= b.skill
        if ra ~= rb then return ra end
        return a.gain > b.gain
    end)
    return out, waiting
end

-- Does the character know a recipe that makes / uses this item?
local function Relation(id)
    if ns.Craft and ns.Craft.ProducerOf and ns.Craft.ProducerOf(id) then return "you craft it" end
    for prof, list in pairs(ns.db.recipes or {}) do
        for _, rec in pairs(list) do
            if type(rec) == "table" and rec.r then
                for _, rg in ipairs(rec.r) do
                    if rg[1] == id or rg.id == id then return "you use it (" .. prof .. ")" end
                end
            end
        end
    end
end
M.Relation = Relation

-- ------------------------------------------------------------ page
local ROWS = 14
function M.BuildPage(page)
    local title = T.Text(page, 20, { bold = true, text = Tr("Market") })
    title:SetPoint("TOPLEFT", 0, -2)
    page.sub = T.Text(page, 11, { color = C.muted })
    page.sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    page.filter = ns.db.settings.marketFilter or "all"
    page.offset = 0
    page.fb = {}
    local prev
    for i = #M.FILTERS, 1, -1 do
        local d = M.FILTERS[i]
        local b = T.Button(page, Tr(d[2]), (d[1] == "vflip" or d[1] == "vcraft") and 100 or 92, 26, function()
            page.filter = d[1]; ns.db.settings.marketFilter = d[1]; page.offset = 0; page:Refresh()
        end, "pill")
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", 0, 0) end
        prev = b
        page.fb[d[1]] = b
    end
    page.fb.raw.tooltip = Tr("Raw materials (cloth, leather, ore, meat & fish, herbs, elemental, enchanting): what is worth farming.")
    page.fb.flip.tooltip = Tr("Listed well below their usual price and selling regularly: buy and relist (after 5 % cut and deposit).")
    page.fb.vcraft.tooltip = Tr("Recipes (all professions) whose result sells to a vendor for more than its materials cost at the AH. The ones you can craft now come first.")
    page.fb.vflip.tooltip = Tr("Listed below what a vendor pays for them: buy, then sell at any vendor. Risk-free while the price holds.")

    local list = CreateFrame("Frame", nil, page)
    T.Surface(list, C.surface, 10)
    list:SetPoint("TOPLEFT", 0, -46); list:SetPoint("BOTTOMRIGHT", 0, 0)
    local heads = { { "Item", "LEFT", 44 }, { "Price", "RIGHT", -470 }, { "Sold / day", "RIGHT", -370 },
        { "Gold / day", "RIGHT", -250 }, { "Listed", "RIGHT", -160 }, { "", "RIGHT", -14 } }
    page.heads = {}
    for _, h in ipairs(heads) do
        local t = T.Text(list, 10, { bold = true, color = C.faint, text = h[1], justify = h[2] })
        t:SetPoint("TOP" .. h[2], h[3], -10)
        page.heads[#page.heads + 1] = t
    end
    page.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Frame", nil, list)
        r:SetHeight(28)
        r:SetPoint("TOPLEFT", 8, -28 - (i - 1) * 28); r:SetPoint("TOPRIGHT", -8, -28 - (i - 1) * 28)
        r:EnableMouse(true)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(20, 20); r.icon:SetPoint("LEFT", 8, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.name = T.Text(r, 12); r.name:SetPoint("LEFT", 36, 0); r.name:SetWidth(300); r.name:SetWordWrap(false)
        r.price = T.Text(r, 12, { justify = "RIGHT" }); r.price:SetPoint("RIGHT", -462, 0)
        r.rate = T.Text(r, 12, { justify = "RIGHT", bold = true }); r.rate:SetPoint("RIGHT", -362, 0)
        r.gold = T.Text(r, 12, { justify = "RIGHT" }); r.gold:SetPoint("RIGHT", -242, 0)
        r.listed = T.Text(r, 12, { justify = "RIGHT", color = C.muted }); r.listed:SetPoint("RIGHT", -152, 0)
        r.tag = T.Text(r, 11, { justify = "RIGHT", color = C.gold }); r.tag:SetPoint("RIGHT", -6, 0); r.tag:SetWidth(140)
        r.buy = T.Button(r, Tr("Buy"), 90, 20, function()
            if r.row then ns.Market.Buy(r.row) end
        end, "primary")
        r.buy:SetPoint("RIGHT", -6, 0)
        r:SetScript("OnEnter", function(self)
            local row = self.row
            if not row then return end
            T.ItemTooltip(self, row.id)
            GameTooltip:AddLine(" ")
            if row.rec then
                local rc = row.rec
                GameTooltip:AddLine((rc.name or "?") .. "  |cff8a877f(" .. Tr(ns.Route.NAME_KEYS[row.prof]) .. " " .. rc.o .. ")|r", 1, 1, 1)
                for _, m in ipairs(rc.mats) do
                    local p = BuyNow(m[1])
                    GameTooltip:AddDoubleLine(m[2] .. "× " .. P.Name(m[1]), p and ns.FormatMoney(p * m[2], { iconSize = 11 }) or "?", 0.8, 0.8, 0.8, 1, 1, 1)
                end
                GameTooltip:AddDoubleLine(Tr("Vendor pays") .. (rc.n > 1 and (" (×" .. rc.n .. ")") or ""), ns.FormatMoney(row.vs, { iconSize = 11 }), 0.7, 0.7, 0.7, 1, 1, 1)
                GameTooltip:AddDoubleLine(Tr("Profit per craft"), ns.FormatMoney(row.gain, { sign = true, color = true, iconSize = 11 }), 0.7, 0.7, 0.7)
                if row.units < math.huge then
                    GameTooltip:AddDoubleLine(Tr("Crafts with the materials listed now"), tostring(row.units), 0.7, 0.7, 0.7, 1, 1, 1)
                end
                if row.access and row.access > 0 then
                    GameTooltip:AddDoubleLine(Tr("Learn it (once)"), ns.FormatMoney(row.access, { iconSize = 11 }) .. (row.est and " ~" or ""), 0.7, 0.7, 0.7, 1, 1, 1)
                end
                if row.who then GameTooltip:AddDoubleLine(Tr("Your skill"), ("%s %d"):format(row.who, row.mySkill), 0.7, 0.7, 0.7, 1, 1, 1) end
                GameTooltip:AddLine(Tr("Materials at today's AH price (vendor price for vendor supplies)."), 0.5, 0.5, 0.5, true)
                GameTooltip:AddLine(Tr("Click: price history"), 0.88, 0.66, 0.24)
                GameTooltip:Show()
                return
            end
            GameTooltip:AddDoubleLine(Tr("Sold per day (est.)"), ("%.1f"):format(row.rate), 0.7, 0.7, 0.7, 1, 1, 1)
            if row.market then GameTooltip:AddDoubleLine(Tr("Usual price"), ns.FormatMoney(row.market, { iconSize = 11 }), 0.7, 0.7, 0.7) end
            if row.cur then GameTooltip:AddDoubleLine(Tr("Lowest now"), ns.FormatMoney(row.cur, { iconSize = 11 }), 0.7, 0.7, 0.7) end
            if row.vs then
                GameTooltip:AddDoubleLine(Tr("Vendor pays"), ns.FormatMoney(row.vs, { iconSize = 11 }), 0.7, 0.7, 0.7)
                GameTooltip:AddDoubleLine((Tr("Buy %d (below vendor price)")):format(row.units), ns.FormatMoney(row.cost, { iconSize = 11 }), 0.7, 0.7, 0.7)
                GameTooltip:AddDoubleLine(Tr("Profit"), ns.FormatMoney(row.gain, { sign = true, color = true, iconSize = 11 }), 0.7, 0.7, 0.7)
            elseif row.gain then GameTooltip:AddDoubleLine(Tr("Flip gain / unit"), ns.FormatMoney(row.gain, { sign = true, color = true, iconSize = 11 }), 0.7, 0.7, 0.7) end
            local rel = Relation(row.id)
            if rel then GameTooltip:AddLine(rel, 0.88, 0.66, 0.24) end
            GameTooltip:AddLine(Tr("Estimated from quantities that vanished between your full scans (cancels and expiries count too)."), 0.5, 0.5, 0.5, true)
            GameTooltip:AddLine(Tr("Click: price history"), 0.88, 0.66, 0.24)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- Click: price history; Shift-click: link in chat.
        r:SetScript("OnMouseUp", function(self, button)
            local row = self.row
            if not row or button ~= "LeftButton" then return end
            if IsModifiedClick and IsModifiedClick("CHATLINK") then
                local _, link = ns.GetItemInfo(row.id)
                if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
            elseif ns.History then
                ns.History.Show(row.id)
            end
        end)
        page.rows[i] = r
    end
    page.empty = T.Text(list, 12, { color = C.muted, justify = "CENTER", wrap = true })
    page.empty:SetPoint("CENTER"); page.empty:SetWidth(520)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, d)
        page.offset = math.max(0, math.min(math.max(0, #(page.data or {}) - ROWS), page.offset - d * 3))
        page:Draw()
    end)

    local function Money(v) return ns.FormatMoney(v, { iconSize = 11, short = true }) end
    function page:Draw()
        local data = self.data or {}
        for i, r in ipairs(self.rows) do
            local row = data[self.offset + i]
            r.row = row
            if row then
                local name = ns.GetItemInfo(row.id)
                if not name then ns.RequestItem(row.id) end
                local _, _, icon = Instant(row.id)
                r.icon:SetTexture(ns.GetItemIcon(row.id) or icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                r.name:SetText(P.Name(row.id))
                r.buy:SetShown(self.filter == "vflip"); r.tag:SetShown(self.filter ~= "vflip")
                if self.filter == "vcraft" then
                    local rc = row.rec
                    local n = P.Name(row.id)
                    r.name:SetText(n .. (rc.n > 1 and n ~= "" and ("  |cff8a877f×" .. rc.n .. "|r") or ""))
                    r.price:SetText(Money(row.cost) .. Tr("  |cff615f5c/ ") .. Money(row.vs) .. "|r")
                    r.rate:SetText(row.units == math.huge and "∞" or tostring(row.units))
                    r.gold:SetText(ns.FormatMoney(row.gain, { sign = true, color = true, iconSize = 11, short = true }))
                    local mine = row.mySkill >= row.skill
                    r.listed:SetText((mine and "|cff5cd173" or "|cff8a877f") .. row.skill .. "|r")
                    local SRC = { known = { "Known", "|cff5cd173" }, trainer = { "Trainer", "|cffcdc8b8" },
                        ah = { "AH", "|cffe0a83d" }, vendor = { "Vendor", "|cff73adf2" } }
                    local s = SRC[row.label] or { "?", "|cff8a877f" }
                    local learn = (row.access and row.access > 0) and (" " .. Money(row.access) .. (row.est and "~" or "")) or ""
                    r.tag:SetText(Tr(ns.Route.NAME_KEYS[row.prof]) .. "  " .. s[2] .. Tr(s[1]) .. "|r" .. learn)
                    r.tag:SetTextColor(unpack(C.faint))
                    r.buy:Hide(); r.tag:Show()
                    r:Show()
                elseif self.filter == "vflip" then
                    local b = M.Buying()
                    r.buy.text:SetText((b and b.id == row.id) and (b.stage == "confirm" and "Confirm" or "…") or "Buy")
                    r.buy:SetDisabled(not IsAHOpen() or (b ~= nil and b.id ~= row.id))
                    r.price:SetText(Money(row.cur) .. Tr("  |cff615f5c/ ") .. Money(row.vs) .. "|r")
                    r.rate:SetText(tostring(row.units))
                    r.gold:SetText(ns.FormatMoney(row.gain, { sign = true, color = true, iconSize = 11, short = true }))
                elseif self.filter == "flip" then
                    r.price:SetText(Money(row.cur) .. Tr("  |cff615f5c/ ") .. Money(row.market) .. "|r")
                    r.gold:SetText(ns.FormatMoney(row.gain, { sign = true, color = true, iconSize = 11, short = true }))
                else
                    r.price:SetText(Money(row.price))
                    r.gold:SetText(Money(row.gold))
                end
                if self.filter ~= "vcraft" then
                    if self.filter ~= "vflip" then
                        r.rate:SetText(row.rate >= 10 and ("%d"):format(math.floor(row.rate + 0.5)) or ("%.1f"):format(row.rate))
                    end
                    r.listed:SetText(tostring(row.listed))
                    local rel = Relation(row.id)
                    r.tag:SetText(rel and (rel:find("craft") and "you craft it" or "you use it") or (row.sub or ""))
                    r.tag:SetTextColor(unpack(rel and C.gold or C.faint))
                    r:Show()
                end
            else
                r:Hide()
            end
        end
    end

    function page:Refresh()
        for k, b in pairs(self.fb) do b:SetSelected(k == self.filter) end
        local db = DB()
        local hours = M.ObservedHours()
        local vf = self.filter == "vflip"
        self.heads[2]:SetText(vf and "Price / vendor" or self.filter == "flip" and "Now / usual" or "Price")
        self.heads[3]:SetText(vf and "Units" or "Sold / day")
        self.heads[4]:SetText(vf and "Profit" or self.filter == "flip" and "Gain / unit" or "Gold / day")
        if self.filter == "vcraft" then
            self.heads[2]:SetText(Tr("Materials / vendor")); self.heads[3]:SetText(Tr("Crafts"))
            self.heads[4]:SetText(Tr("Profit / craft")); self.heads[5]:SetText(Tr("Skill"))
            local list, waiting = M.VendorCrafts()
            self.data = list
            local sub = (Tr("%d recipes sell at a vendor for more than their materials cost")):format(#list)
            if waiting > 0 then sub = sub .. (Tr("  ·  loading %d items…")):format(waiting) end
            self.sub:SetText(sub)
            self.empty:SetText(Tr("No profitable vendor craft found. Scan the AH so materials get a price."))
            self.empty:SetShown(#list == 0)
            self:Draw()
            return
        end
        self.heads[5]:SetText(Tr("Listed"))
        if vf then
            local list, t = M.Flips()
            self.data = list
            self.sub:SetText(t and ((Tr("last scan %s ago  ·  %d flip%s  ·  buy, then Routine > Sell to vendor")):format(
                P.Ago(time() - t), #list, #list == 1 and "" or "s")) or "no full scan yet")
            self.empty:SetText(t and "Nothing listed below vendor price in your last scan." or "Click Scan at the auction house first.")
            self.empty:SetShown(#list == 0)
            if M.lastMsg and M.lastMsgT and GetTime() - M.lastMsgT < 15 then self.sub:SetText(M.lastMsg) end
            self:Draw()
            return
        end
        self.data = M.List(self.filter)
        if (db.scans or 0) < 2 or hours <= 0 then
            self.sub:SetText((Tr("%d full scan%s")):format(db.scans or 0, (db.scans or 0) == 1 and "" or "s"))
            self.empty:SetText(Tr("Click Scan at the auction house at each session (at least two, a few hours apart).\nSales volumes appear from the second scan and get reliable after a few days."))
            self.empty:Show()
        else
            self.sub:SetText((Tr("%d full scans  ·  %d h observed (7 days)  ·  %d items")):format(db.scans, math.floor(hours + 0.5), #self.data))
            self.empty:SetText(self.filter == "flip" and "No good flip right now." or "Nothing selling here yet.")
            self.empty:SetShown(#self.data == 0)
        end
        self:Draw()
    end
end

-- Names that arrive later: redraw the page (after a short delay).
local pend
local ev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(ev, "Market") end
pcall(ev.RegisterEvent, ev, "GET_ITEM_INFO_RECEIVED")
-- Items that do not exist (success = false): ignored, otherwise each redraw asks again and fires the event again.
-- At most one redraw every 2 s: info arrives by the thousands after a full scan.
local lastDraw = 0
ev:SetScript("OnEvent", function(_, _, id, success)
    if success == false then return end
    M.OnItemInfo(id)
    -- Redraw only for an item the addon asked for (or a deal waiting for its vendor price).
    if pend or not (ns.ItemWanted(id) or M.dirty) then return end
    pend = true
    C_Timer.After(math.max(0.5, 2 - (GetTime() - lastDraw)), function()
        pend = false
        lastDraw = GetTime()
        local f = _G.ImpotPointGouvFrame
        if f and f:IsShown() and ns.UI.Current and ns.UI.Current() == "market" then ns.UI.Refresh() end
        if M.dirty then M.dirty = false; ns.Fire("MARKET_CHANGED") end
    end)
end)

-- Profiling (/ipg perf): heavy functions called outside timed events.
if ns.Profile then
    M.OnFullScan = ns.Profile.Wrap("Market:OnFullScan", M.OnFullScan)
    M.List = ns.Profile.Wrap("Market:List", M.List)
    M.VendorCrafts = ns.Profile.Wrap("Market:VendorCrafts", M.VendorCrafts)
end
