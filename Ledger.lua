-- ImpotPointGouv: tracks every gold movement and sorts it by category.
--
-- Principle: each change of GetMoney() (PLAYER_MONEY) becomes ONE operation.
-- The sum of the operations = the actual change in gold. The category is chosen from:
--   1. explicit expectations set by our hooks (AH mail, AH purchase, deposit...),
--      matched to the exact amount when it is known;
--   2. otherwise the context (vendor / mail / AH / loot window open...);
--   3. otherwise "Other", possibly reclassified a second later
--      (CHAT_MSG_MONEY -> Loot, QUEST_TURNED_IN -> Quests).
local _, ns = ...
local L = {}
ns.Ledger = L

local GetTime, time = GetTime, time
local tinsert, tremove = table.insert, table.remove

local charKey, lastMoney
local pending = {}       -- attentes { amount?, sign?, k, info, exp, multi }
local ctx = {}           -- [name] = time until which the context is active
local lastTx, lastTxTime

-- ------------------------------------------------------------ character
function L.CharKey() return charKey end

-- WoW Forever: first name + last name. UnitName only gives the first name; the full name is found elsewhere.
local function FullFrom(text, first)
    if type(text) ~= "string" or not first then return nil end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local pos = text:find(first, 1, true)
    if not pos then return nil end
    local rest = text:sub(pos):gsub("%s*<.*$", ""):gsub("%s+$", "")
    if rest:find(" ") and #rest > #first then return rest end
end

function L.DetectFullName(first)
    local cands = {}
    if UnitPVPName then cands[#cands + 1] = UnitPVPName("player") end
    if GetUnitName then cands[#cands + 1] = GetUnitName("player", false) end
    if UnitFullName then cands[#cands + 1] = (UnitFullName("player")) end
    for _, t in ipairs(cands) do
        local full = FullFrom(t, first)
        if full then return full end
    end
end

-- Character sheet title (C key): shows the full name on Forever.
function L.HookCharacterFrame()
    if L.charHooked or not CharacterFrame then return end
    L.charHooked = true
    CharacterFrame:HookScript("OnShow", function()
        C_Timer.After(0.1, function()
            local key = UnitGUID("player")
            local c = key and ns.db.chars[key]
            if not c then return end
            local texts = {}
            local fs = _G.CharacterFrameTitleText
                or (CharacterFrame.TitleContainer and CharacterFrame.TitleContainer.TitleText)
            if fs and fs.GetText then texts[#texts + 1] = fs:GetText() end
            if CharacterFrame.GetTitleText then
                local t = CharacterFrame:GetTitleText()
                texts[#texts + 1] = type(t) == "table" and t.GetText and t:GetText() or t
            end
            -- Last resort: any text on the sheet that starts with the first name.
            for _, region in ipairs({ CharacterFrame:GetRegions() }) do
                if region.GetObjectType and region:GetObjectType() == "FontString" then texts[#texts + 1] = region:GetText() end
            end
            local full
            for _, t in ipairs(texts) do full = full or FullFrom(t, c.name) end
            if not full and c.full then
                -- (silent)
                return
            end
            if full and c.full ~= full then
                c.full = full
                -- (silent)
                ns.Fire("LEDGER_CHANGED")
            elseif full and not L.namePrinted then
                L.namePrinted = true
                -- (silent)
            end
        end)
    end)
end

-- The character's professions (without opening a window): used by the Characters page and the setup guide.
function L.ReadProfessions(c)
    c = c or (charKey and ns.db.chars[charKey])
    if not c or not GetProfessions or not GetProfessionInfo then return end
    local list = {}
    local ok, p1, p2, arch, fish, cook = pcall(GetProfessions)
    if not ok then return end
    for _, i in ipairs({ p1 or 0, p2 or 0, cook or 0, fish or 0 }) do
        if i and i > 0 then
            local name, _, rank, maxRank, _, _, line = GetProfessionInfo(i)
            -- Herbalism, skinning, fishing: no recipes to read.
            local gather = i == fish or line == 182 or line == 393 or line == 356
            if name then list[#list + 1] = { name = name, rank = rank, max = maxRank, gather = gather } end
        end
    end
    c.profs = list
end

local function EnsureChar()
    local db = ns.db
    local guid = UnitGUID("player")
    if not guid then return nil end
    charKey = guid
    local c = db.chars[guid]
    local name = UnitName("player")
    local realm = ns.Realm()
    local _, class = UnitClass("player")
    local isNew = false
    if not c then
        c = { firstSeen = time() }
        db.chars[guid] = c
        isNew = true
    end
    c.name, c.class = name, class
    if realm ~= "" then c.realm = realm end -- empty since the 1.60.1 hotfix: keep the old one
    local full = L.DetectFullName(name)
    if full and c.full ~= full then
        c.full = full
        -- full name saved without a chat message
    end
    c.lastSeen = time()
    c.level = UnitLevel and UnitLevel("player") or c.level
    L.ReadProfessions(c)
    db.snaps[guid] = db.snaps[guid] or {}
    return c, isNew
end

-- ------------------------------------------------------------ recording
function L.Snapshot(money)
    local s = ns.db.snaps[charKey]
    if not s then return end
    local now = time()
    local last = s[#s]
    if last and now - last[1] < 60 then
        last[2] = money
    elseif not last or last[2] ~= money then
        s[#s + 1] = { now, money }
        if #s > ns.MAX_SNAPS then tremove(s, 1) end
    end
    ns.db.chars[charKey].money = money
    ns.db.chars[charKey].lastSeen = now
end

function L.AddTx(k, amount, info)
    local tx = { t = time(), c = charKey, k = k, a = amount }
    if info then
        tx.i, tx.q, tx.who = info.i, info.q, info.who
        tx.gross, tx.cut, tx.dep, tx.unit = info.gross, info.cut, info.dep, info.unit
        tx.st = info.st
        -- Item detail (vendor sales): id, quality, item level, bound, class, AH value at the time.
        tx.id, tx.qu, tx.il, tx.b, tx.cl, tx.mv = info.id, info.qu, info.il, info.b, info.cl, info.mv
    end
    -- Where and at what level: to measure gold per zone and per level.
    if ns.Track then tx.z = ns.Track.Zone() end
    tx.pl = UnitLevel and UnitLevel("player") or nil
    local list = ns.db.tx
    list[#list + 1] = tx
    if #list > ns.MAX_TX then tremove(list, 1) end
    lastTx, lastTxTime = tx, GetTime()
    ns.Fire("TX_ADDED", tx)
    return tx
end

-- Expectation: the next matching change will get this category.
function L.Expect(e)
    e.exp = GetTime() + (e.ttl or 6)
    pending[#pending + 1] = e
end

local function TakePending(delta)
    local now = GetTime()
    for i = #pending, 1, -1 do
        if pending[i].exp < now then tremove(pending, i) end
    end
    for i, e in ipairs(pending) do
        if e.amount and e.amount == delta then tremove(pending, i); return e end
    end
    -- Expectations without an amount: the most recent wins (e.g. a purchase right after a listing).
    for i = #pending, 1, -1 do
        local e = pending[i]
        if not e.amount and e.sign and ((delta > 0) == (e.sign > 0)) then
            if not e.multi then tremove(pending, i) end
            return e
        end
    end
end

-- Sum of expected vendor sales (in order) equal to the change, when none matches on its own.
local function TakeVendorBatch(delta)
    local now, sum, picks = GetTime(), 0, {}
    for _, e in ipairs(pending) do
        if e.exp >= now and e.amount == delta then return nil end
    end
    for i, e in ipairs(pending) do
        if e.k == "vendor_sell" and e.amount and e.exp >= now then
            sum = sum + e.amount
            picks[#picks + 1] = i
            if sum >= delta then break end
        end
    end
    if sum ~= delta or #picks < 2 then return nil end
    local out = {}
    for j = #picks, 1, -1 do table.insert(out, 1, tremove(pending, picks[j])) end
    return out
end

local function Active(name) return (ctx[name] or 0) >= GetTime() end

local function Classify(delta)
    local e = TakePending(delta)
    if e then return e.k, e.info end
    if Active("merchant") then
        if delta > 0 then return "vendor_sell" end
        if InRepairMode and InRepairMode() then return "repair" end
        return "vendor_buy"
    end
    if Active("mail") then return "mail" end
    if Active("ah") then return "ah_other" end
    if Active("loot") then return "loot" end
    if Active("quest") and delta > 0 then return "quest" end
    if Active("trainer") and delta < 0 then return "trainer" end
    if Active("taxi") and delta < 0 then return "travel" end
    if Active("trade") then return "trade" end
    return "other"
end
L._Classify = Classify -- for tests

-- Reclassifies a very recent "Other" operation when the info arrives after the money.
local function Retag(k, amount)
    if lastTx and lastTx.k == "other" and lastTxTime and GetTime() - lastTxTime <= 2
        and (not amount or lastTx.a == amount) then
        lastTx.k = k
        ns.Fire("LEDGER_CHANGED")
        return true
    end
end

function L.OnMoney()
    if not charKey then return end
    local now = GetMoney()
    if lastMoney == nil then lastMoney = now; L.Snapshot(now); return end
    local delta = now - lastMoney
    lastMoney = now
    if delta == 0 then return end
    -- Several vendor sales arriving in a single gold change: one row per item.
    local batch = delta > 0 and TakeVendorBatch(delta)
    if batch then
        for _, e in ipairs(batch) do L.AddTx("vendor_sell", e.amount, e.info) end
        L.Snapshot(now)
        ns.Fire("LEDGER_CHANGED")
        return
    end
    local k, info = Classify(delta)
    L.AddTx(k, delta, info)
    L.Snapshot(now)
    ns.Fire("LEDGER_CHANGED")
end

-- ------------------------------------------------------------ mail / AH hooks
local AH_SUBJECT_HINTS = { "Outbid", "Surench", "enchère", "Auction", "Hôtel des ventes", "Hotel des ventes" }

local function ParseCount(subject)
    if not subject then return nil end
    local n = subject:match("%((%d+)%)%s*$")
    return n and tonumber(n) or nil
end

local function PrepareMail(index)
    if not index or not GetInboxHeaderInfo then return end
    local _, _, sender, subject, money, _, daysLeft = GetInboxHeaderInfo(index)
    -- Actual time of the sale: an AH mail lives 30 days, daysLeft tells when it arrived.
    local soldAt = daysLeft and (time() - math.floor(math.max(0, 30 - daysLeft) * 86400)) or nil
    if not money or money <= 0 then return end
    local invoiceType, itemName, playerName, bid, _, deposit, consignment, _, _, count
    if GetInboxInvoiceInfo then
        invoiceType, itemName, playerName, bid, _, deposit, consignment, _, _, count = GetInboxInvoiceInfo(index)
    end
    if invoiceType == "seller" then
        L.Expect({ amount = money, k = "ah_sale", ttl = 20, info = {
            i = itemName, who = playerName, q = (count and count > 0 and count) or ParseCount(subject) or 1,
            gross = bid, cut = consignment, dep = deposit, st = soldAt } })
        return
    end
    local kind, subjItem = ns.AuctionMailKind(subject)
    if kind == "sale" then
        L.Expect({ amount = money, k = "ah_sale", ttl = 20, info = { i = itemName or subjItem, q = ParseCount(subject), st = soldAt } })
        return
    end
    itemName = itemName or subjItem
    local isAH = invoiceType ~= nil or kind ~= nil
    if not isAH then
        local hay = (sender or "") .. " " .. (subject or "")
        for _, hint in ipairs(AH_SUBJECT_HINTS) do
            if hay:find(hint, 1, true) then isAH = true; break end
        end
    end
    if isAH then
        L.Expect({ amount = money, k = "ah_refund", ttl = 20, info = { i = itemName, who = sender } })
    else
        L.Expect({ amount = money, k = "mail", ttl = 20, info = { who = sender, i = subject } })
    end
end

-- Item back from the AH (expired / cancelled) collected from the mail: noted for the sell rate.
local returnedSeen = {}
function L.NoteReturnedItem(index)
    if not index or not GetInboxHeaderInfo then return end
    local _, _, sender, subject, _, _, daysLeft = GetInboxHeaderInfo(index)
    local kind, item = ns.AuctionMailKind(subject)
    if kind ~= "expired" and kind ~= "cancelled" then return end
    local sig = (sender or "") .. (subject or "") .. tostring(daysLeft)
    if returnedSeen[sig] then return end
    returnedSeen[sig] = true
    local count = 1
    if GetInboxItem then
        local _, _, _, c = GetInboxItem(index, 1)
        count = c or 1
    end
    L.AddTx(kind == "expired" and "ah_expired" or "ah_cancelled", 0, { i = item, q = count })
    ns.Fire("LEDGER_CHANGED")
end

-- The listed item: remembered as soon as it is placed in the sell slot,
-- because PostAuction empties the slot before our hook runs.
local sellItem
local function CacheSellItem()
    if not GetAuctionSellItemInfo then return end
    local name, _, count = GetAuctionSellItemInfo()
    if name then sellItem = { i = name, q = count } end
end

local function OnPost(_, _, _, stackSize, numStacks)
    local info = sellItem and { i = sellItem.i, q = (stackSize and numStacks) and stackSize * numStacks or sellItem.q }
    L.Expect({ sign = -1, multi = true, k = "ah_deposit", ttl = 15, info = info })
end

local function OnBid(listType, index, bid)
    if not bid or bid <= 0 then return end
    local name, count
    if GetAuctionItemInfo then
        local n, _, c = GetAuctionItemInfo(listType, index)
        name, count = n, c
    end
    L.Expect({ amount = -bid, k = "ah_buy", ttl = 15, info = { i = name, q = count } })
end

local function SafeHook(name, fn)
    if type(_G[name]) == "function" then hooksecurefunc(name, fn) end
end

-- ------------------------------------------------------------ events
local CONTEXT_EVENTS = {
    MERCHANT_SHOW = { "merchant", true },      MERCHANT_CLOSED = { "merchant", false },
    MAIL_SHOW = { "mail", true },              MAIL_CLOSED = { "mail", false },
    AUCTION_HOUSE_SHOW = { "ah", true },       AUCTION_HOUSE_CLOSED = { "ah", false },
    LOOT_OPENED = { "loot", true },            LOOT_CLOSED = { "loot", false },
    QUEST_COMPLETE = { "quest", true },        QUEST_FINISHED = { "quest", false },
    TRAINER_SHOW = { "trainer", true },        TRAINER_CLOSED = { "trainer", false },
    TAXIMAP_OPENED = { "taxi", true },         TAXIMAP_CLOSED = { "taxi", false },
    TRADE_SHOW = { "trade", true },            TRADE_CLOSED = { "trade", false },
}

local frame = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(frame, "Ledger") end
local function Register(ev) pcall(frame.RegisterEvent, frame, ev) end

Register("ADDON_LOADED")
Register("PLAYER_ENTERING_WORLD")
Register("PLAYER_MONEY")
Register("CHAT_MSG_MONEY")
Register("QUEST_TURNED_IN")
Register("NEW_AUCTION_UPDATE")
Register("PLAYER_LOGOUT")
Register("SKILL_LINES_CHANGED")
for ev in pairs(CONTEXT_EVENTS) do Register(ev) end

local started = false
local function Start()
    if started then return end
    local c, isNew = EnsureChar()
    if not c then return end
    started = true
    local money = GetMoney()
    if not isNew and c.money and c.money ~= money then
        -- Gold changed out of our sight (addon disabled, another PC...).
        -- Unless this same amount was just recorded for this character (balance not saved yet): no double count.
        local delta, dup = money - c.money, false
        for i = #ns.db.tx, 1, -1 do
            local tx = ns.db.tx[i]
            if time() - tx.t > 6 * 3600 then break end
            if tx.c == charKey and tx.a == delta and tx.k ~= "offline" then dup = true; break end
        end
        if not dup then L.AddTx("offline", delta) end
    end
    lastMoney = money
    L.Snapshot(money)
    L.HookCharacterFrame()
    if L.hooked then ns.Fire("LEDGER_READY"); return end
    L.hooked = true

    SafeHook("TakeInboxMoney", PrepareMail)
    SafeHook("AutoLootMailItem", PrepareMail)
    SafeHook("AutoLootMailItem", L.NoteReturnedItem)
    SafeHook("TakeInboxItem", L.NoteReturnedItem)
    SafeHook("PlaceAuctionBid", OnBid)
    SafeHook("PostAuction", OnPost)
    SafeHook("StartAuction", OnPost)
    SafeHook("RepairAllItems", function() L.Expect({ sign = -1, k = "repair", ttl = 4 }) end)

    -- Modern AH (C_AuctionHouse), used by WoW Forever.
    local AHM = C_AuctionHouse
    if AHM then
        local lastItemID
        local function NameOf(id) return id and ((ns.GetItemInfo(id)) or ns.db.items[id]) or nil end
        local function LocName(loc)
            if C_Item and C_Item.GetItemName then
                local ok, n = pcall(C_Item.GetItemName, loc)
                if ok then return n end
            end
        end
        local function Hook(fname, fn) if type(AHM[fname]) == "function" then hooksecurefunc(AHM, fname, fn) end end
        Hook("SendSearchQuery", function(itemKey) lastItemID = itemKey and itemKey.itemID end)
        -- Also keep the asked price (unit = unit price) to measure actual sales.
        Hook("PostItem", function(loc, _, qty, _, buyout)
            L.Expect({ sign = -1, multi = true, k = "ah_deposit", ttl = 10,
                info = { i = LocName(loc), q = qty, unit = buyout and qty and qty > 0 and math.floor(buyout / qty) or buyout } })
        end)
        Hook("PostCommodity", function(loc, _, qty, unitPrice)
            L.Expect({ sign = -1, multi = true, k = "ah_deposit", ttl = 10, info = { i = LocName(loc), q = qty, unit = unitPrice } })
        end)
        -- Buyout of a listing: the game only gives its auction ID. The item comes from the search results
        -- that showed that listing (not from the last search, which may be another item, e.g. the one
        -- Auctionator looks up while you post). Unknown: the purchase keeps no item name.
        local byAuction = {}
        L._byAuction = byAuction
        local f = CreateFrame("Frame")
        pcall(f.RegisterEvent, f, "ITEM_SEARCH_RESULTS_UPDATED")
        f:SetScript("OnEvent", function(_, _, itemKey)
            if not (itemKey and itemKey.itemID and AHM.GetNumItemSearchResults and AHM.GetItemSearchResultInfo) then return end
            for i = 1, (AHM.GetNumItemSearchResults(itemKey) or 0) do
                local r = AHM.GetItemSearchResultInfo(itemKey, i)
                if r and r.auctionID then byAuction[r.auctionID] = itemKey.itemID end
            end
        end)
        Hook("PlaceBid", function(auctionID, bid)
            if bid and bid > 0 then
                L.Expect({ amount = -bid, k = "ah_buy", ttl = 15, info = { i = NameOf(byAuction[auctionID]), q = 1 } })
            end
        end)
        Hook("ConfirmCommoditiesPurchase", function(itemID, qty)
            L.Expect({ sign = -1, k = "ah_buy", ttl = 15, info = { i = NameOf(itemID), q = qty } })
        end)
    end
    ns.Fire("LEDGER_READY")
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... == ns.name then ns.InitDB(); ns.Fire("DB_READY") end
        return
    end
    if not ns.db then return end
    if event == "PLAYER_ENTERING_WORLD" then
        Start()
    elseif event == "SKILL_LINES_CHANGED" then
        if started then L.ReadProfessions(); ns.Fire("CHARS_CHANGED") end
    elseif event == "PLAYER_MONEY" then
        if not started then Start() else L.OnMoney() end
    elseif event == "CHAT_MSG_MONEY" then
        ctx.loot = math.max(ctx.loot or 0, GetTime() + 1.5)
        Retag("loot")
    elseif event == "QUEST_TURNED_IN" then
        local _, _, money = ...
        if money and money > 0 then
            if not Retag("quest", money) then L.Expect({ amount = money, k = "quest", ttl = 5 }) end
        end
    elseif event == "NEW_AUCTION_UPDATE" then
        CacheSellItem()
    elseif event == "PLAYER_LOGOUT" then
        -- Nothing: on logout the game returns 0 gold; every change is already recorded.
    else
        local def = CONTEXT_EVENTS[event]
        if def then
            -- Closing: keep the context 2 s, the money often arrives right after.
            ctx[def[1]] = def[2] and math.huge or (GetTime() + 2)
        end
    end
end)

-- ------------------------------------------------------------ queries for the UI
function L.TotalMoney()
    local total = 0
    for key, c in pairs(ns.db.chars) do
        if key == charKey and started then total = total + GetMoney()
        else total = total + (c.money or 0) end
    end
    return total
end

function L.FirstTime()
    local first
    for _, s in pairs(ns.db.snaps) do
        if s[1] and (not first or s[1][1] < first) then first = s[1][1] end
    end
    return first
end

-- Total balance (all characters) at time t. Before a character's first reading,
-- that first reading is used (avoids a false "gain" when a character is added).
local function ValueAt(s, t, startIdx)
    local i = startIdx or 1
    if not s[1] then return 0, i end
    if t < s[1][1] then return s[1][2], 1 end
    while s[i + 1] and s[i + 1][1] <= t do i = i + 1 end
    return s[i][2], i
end

-- Sampled series for the chart: n points between t0 and t1.
function L.BalanceSeries(t0, t1, n)
    local pts, idx = {}, {}
    for i = 0, n - 1 do
        local t = t0 + (t1 - t0) * i / (n - 1)
        local total = 0
        for key, s in pairs(ns.db.snaps) do
            local v
            v, idx[key] = ValueAt(s, t, idx[key])
            total = total + v
        end
        pts[#pts + 1] = { t, total }
    end
    if pts[#pts] then pts[#pts][2] = L.TotalMoney() end
    return pts
end

-- Cumulative AH profit over the period.
function L.AHProfitSeries(t0, t1, n)
    local pts = {}
    local list = ns.db.tx
    local j, acc = 1, 0
    while list[j] and list[j].t < t0 do j = j + 1 end
    for i = 0, n - 1 do
        local t = t0 + (t1 - t0) * i / (n - 1)
        while list[j] and list[j].t <= t do
            local cat = ns.CATEGORIES[list[j].k]
            if cat and cat.group == "ah" then acc = acc + list[j].a end
            j = j + 1
        end
        pts[#pts + 1] = { t, acc }
    end
    return pts
end

-- Statistics for the period [t0, now].
function L.Stats(t0)
    local st = { byCat = {}, items = {}, sales = 0, salesCount = 0, buys = 0, refunds = 0,
        deposits = 0, cut = 0, depRefund = 0, ahNet = 0, count = 0 }
    for _, tx in ipairs(ns.db.tx) do
        if tx.t >= t0 then
            st.count = st.count + 1
            st.byCat[tx.k] = (st.byCat[tx.k] or 0) + tx.a
            local cat = ns.CATEGORIES[tx.k]
            if cat and cat.group == "ah" then st.ahNet = st.ahNet + tx.a end
            if tx.k == "ah_sale" then
                st.sales = st.sales + tx.a
                st.salesCount = st.salesCount + 1
                st.cut = st.cut + (tx.cut or 0)
                st.depRefund = st.depRefund + (tx.dep or 0)
                local name = tx.i or "?"
                local it = st.items[name]
                if not it then it = { name = name, total = 0, qty = 0, n = 0 }; st.items[name] = it end
                it.total = it.total + tx.a
                it.qty = it.qty + (tx.q or 1)
                it.n = it.n + 1
            elseif tx.k == "ah_buy" then st.buys = st.buys + tx.a
            elseif tx.k == "ah_refund" then st.refunds = st.refunds + tx.a
            elseif tx.k == "ah_deposit" then st.deposits = st.deposits + tx.a
            end
        end
    end
    -- Trade: everything bought and sold (AH + vendor), AH fees included. Mail between your characters excluded.
    local TRADE = { ah_sale = true, ah_buy = true, ah_deposit = true, ah_refund = true, ah_other = true,
        vendor_sell = true, vendor_buy = true }
    st.trade, st.sold, st.bought, st.soldCount = 0, 0, 0, 0
    for k, v in pairs(st.byCat) do if TRADE[k] then st.trade = st.trade + v end end
    st.sold = (st.byCat.ah_sale or 0) + (st.byCat.vendor_sell or 0)
    st.bought = (st.byCat.ah_buy or 0) + (st.byCat.vendor_buy or 0)
    for _, tx in ipairs(ns.db.tx) do
        if tx.t >= t0 and (tx.k == "ah_sale" or tx.k == "vendor_sell") then st.soldCount = st.soldCount + 1 end
    end
    -- Taxes = AH commission + deposits not refunded (expired / cancelled).
    st.fees = st.cut + math.max(0, -st.deposits - st.depRefund)
    local top = {}
    for _, it in pairs(st.items) do top[#top + 1] = it end
    table.sort(top, function(a, b) return a.total > b.total end)
    st.top = top
    return st
end

function L.Reset()
    wipe(ns.db.tx)
    wipe(ns.db.snaps)
    wipe(ns.db.chars)
    started = false
    lastMoney = nil
    Start()
    ns.Fire("LEDGER_CHANGED")
end
