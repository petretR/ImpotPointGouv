-- ImpotPointGouv: namespace, database, utilities.
local ADDON, ns = ...
local Tr = ns.L
ns.name = ADDON
ns.version = "1.0.0"
_G.ImpotPointGouv = ns

ns.MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\media\\"

-- Gold movement categories. group = "ah" for everything related to the auction house.
ns.CATEGORIES = {
    ah_sale     = { label = Tr("AH sales"),            group = "ah",     color = {0.36, 0.82, 0.45} },
    ah_buy      = { label = Tr("AH purchases"),            group = "ah",     color = {0.93, 0.42, 0.36} },
    ah_deposit  = { label = Tr("AH deposits"),            group = "ah",     color = {0.85, 0.55, 0.30} },
    ah_refund   = { label = Tr("AH refunds"),    group = "ah",     color = {0.55, 0.75, 0.95} },
    ah_other    = { label = Tr("AH (other)"),           group = "ah",     color = {0.70, 0.62, 0.50} },
    ah_expired  = { label = Tr("AH expired"),           group = "ah",     color = {0.92, 0.58, 0.28} },
    ah_cancelled= { label = Tr("AH cancelled"),         group = "ah",     color = {0.62, 0.60, 0.58} },
    vendor_sell = { label = Tr("Vendor sales"),      group = "vendor", color = {0.60, 0.85, 0.55} },
    vendor_buy  = { label = Tr("Vendor purchases"),      group = "vendor", color = {0.90, 0.55, 0.45} },
    repair      = { label = Tr("Repairs"),          group = "vendor", color = {0.75, 0.50, 0.45} },
    loot        = { label = Tr("Loot"),                group = "loot",   color = {0.95, 0.80, 0.35} },
    quest       = { label = Tr("Quests"),               group = "quest",  color = {0.95, 0.88, 0.50} },
    trainer     = { label = Tr("Training"),           group = "other",  color = {0.65, 0.60, 0.90} },
    travel      = { label = Tr("Travel"),            group = "other",  color = {0.55, 0.70, 0.85} },
    trade       = { label = Tr("Trades"),             group = "other",  color = {0.70, 0.80, 0.80} },
    mail        = { label = Tr("Mail"),             group = "other",  color = {0.75, 0.75, 0.70} },
    offline     = { label = Tr("Offline change"),     group = "other",  color = {0.50, 0.50, 0.50} },
    other       = { label = Tr("Other"),                group = "other",  color = {0.60, 0.60, 0.60} },
}
ns.CATEGORY_ORDER = { "ah_sale", "ah_buy", "ah_deposit", "ah_refund", "ah_other", "ah_expired", "ah_cancelled", "vendor_sell", "vendor_buy",
    "repair", "loot", "quest", "trainer", "travel", "trade", "mail", "offline", "other" }

ns.MAX_TX = 25000
ns.MAX_SNAPS = 20000

local DEFAULTS = {
    version = 2,
    chars = {},   -- [key] = { name, realm, class, money, firstSeen, lastSeen }
    snaps = {},   -- [key] = { {time, money}, ... }
    tx = {},      -- { {t, c, k, a, i, q, who, gross, cut, dep}, ... }
    settings = { minimap = {}, range = "30d", chartMode = "balance", firstRun = true, craftSort = "profit" },
    prices = {},  -- [realm][itemID] = { cur, qty, t, d = { {day, lowest, qty}, ... } }
    vendor = {},  -- [itemID] = unit purchase price at the vendor (learned)
    items = {},   -- [itemID] = name
    recipes = {}, -- [profession][recipe] = { p = product, m = quantity made, r = { {id, n}, ... } }
    scan = {},    -- [realm] = { lastFull = time }
}

local function Merge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            Merge(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

-- v2: repairs data skewed by the old logout reading (GetMoney() = 0 on exit).
local function RepairLogoutZeros(db)
    local removedTx, removedSnaps = 0, 0
    -- 1) "Offline change" whose previous reading was that false 0: it is the balance counted again.
    for i = #db.tx, 1, -1 do
        local tx = db.tx[i]
        if tx.k == "offline" then
            local s, prev = db.snaps[tx.c], nil
            for _, p in ipairs(s or {}) do
                if p[1] < tx.t then prev = p else break end
            end
            if prev and prev[2] == 0 then table.remove(db.tx, i); removedTx = removedTx + 1 end
        end
    end
    -- 2) Readings of 0 right after a non-zero reading (logouts), then the saved balance is corrected.
    for key, s in pairs(db.snaps) do
        for i = #s, 2, -1 do
            if s[i][2] == 0 and s[i - 1][2] > 0 then table.remove(s, i); removedSnaps = removedSnaps + 1 end
        end
        if db.chars[key] and s[#s] then db.chars[key].money = s[#s][2] end
    end
    return removedTx, removedSnaps
end

-- v3: an "Offline change" identical to an operation of the same character just before = the same amount counted twice.
local function RepairDoubleOffline(db)
    local removed = 0
    for i = #db.tx, 1, -1 do
        local tx = db.tx[i]
        if tx.k == "offline" then
            for j = i - 1, 1, -1 do
                local p = db.tx[j]
                if tx.t - p.t > 6 * 3600 then break end
                if p.c == tx.c and p.k ~= "offline" and p.a == tx.a then table.remove(db.tx, i); removed = removed + 1; break end
            end
        end
    end
    return removed
end
ns.RepairDoubleOffline = RepairDoubleOffline

-- ---------------------------------------------------------------- realm
-- Realm name, even when the game returns an empty string (seen on Forever: a whole session without a name).
-- Fallback: the name already seen for this realm number (in the character ID, "Player-6923-…"),
-- then the last known name, then the realm with the most prices.
local function RealmId()
    local guid = UnitGUID and UnitGUID("player")
    return guid and guid:match("^Player%-(%d+)%-")
end
-- Result kept for the session: ns.Realm() is called on every price read (thousands of times per
-- redraw), and without a name from the game the fallback must be computed only once.
local realmCache
function ns.Realm()
    local r = GetRealmName and GetRealmName()
    local db = ns.db
    if r and r ~= "" then
        if realmCache ~= r and db then
            local rid = RealmId()
            db.realmById = db.realmById or {}
            if rid then db.realmById[rid] = r end
            db.lastRealm, db.realmKey = r, r -- realmKey: name kept by v0.23.1 / 0.24.0
        end
        realmCache = r
        return r
    end
    if realmCache then return realmCache end
    if not db then return "?" end
    local rid = RealmId()
    local found = (rid and db.realmById and db.realmById[rid])
        or (db.realmKey ~= "" and db.realmKey) or db.lastRealm
    if not found then
        -- Realm saved for this character.
        local guid = UnitGUID and UnitGUID("player")
        local c = guid and db.chars and db.chars[guid]
        if c and c.realm and c.realm ~= "" then found = c.realm end
    end
    if not found then
        -- No known name: the realm with the most saved prices (computed only once).
        local most = -1
        for k, t in pairs(db.prices or {}) do
            if k ~= "" and k ~= "?" then
                local n = 0
                for _ in pairs(t) do n = n + 1 end
                if n > most then found, most = k, n end
            end
        end
    end
    if not found then return "?" end
    realmCache = found
    db.realmKey = found
    if rid then db.realmById = db.realmById or {}; db.realmById[rid] = found end
    return found
end

-- Data saved under an empty realm (""): merged into the real realm.
local function DayOf(s) return tonumber((s or ""):match("^(%-?%d+)")) end
local function F(s) local o, i = {}, 0; for f in (s .. ","):gmatch("([^,]*),") do i = i + 1; o[i] = tonumber(f) end; return o end
local function N(v) return v and tostring(math.floor(v + 0.5)) or "" end
local function MergePrices(dst, src)
    for id, e in pairs(src) do
        local d = dst[id]
        if not d then dst[id] = e
        else
            local byDay = {}
            for _, p in ipairs(d.d or {}) do byDay[p[1]] = p end
            for _, p in ipairs(e.d or {}) do
                local q = byDay[p[1]]
                if q then q[2] = math.min(q[2], p[2]); q[3] = p[3] else byDay[p[1]] = p end
            end
            local days = {}
            for _, p in pairs(byDay) do days[#days + 1] = p end
            table.sort(days, function(a, b) return a[1] < b[1] end)
            while #days > 30 do table.remove(days, 1) end
            d.d = days
            if e.h then
                d.h = d.h or {}
                for _, p in ipairs(e.h) do d.h[#d.h + 1] = p end
                table.sort(d.h, function(a, b) return a[1] < b[1] end)
                while #d.h > 120 do table.remove(d.h, 1) end
            end
            if (e.t or 0) >= (d.t or 0) then d.cur, d.qty, d.t = e.cur, e.qty, e.t end
        end
    end
end
local function MergeHist(dst, src)
    for id, h in pairs(src) do
        local d = dst[id]
        if not d then dst[id] = h
        else
            for _, s in ipairs(h.s or {}) do d.s[#d.s + 1] = s end
            table.sort(d.s, function(a, b) return (DayOf(a) or 0) < (DayOf(b) or 0) end)
            while #d.s > 400 do table.remove(d.s, 1) end
            local byDay, order = {}, {}
            for _, s in ipairs(d.d or {}) do local f = F(s); byDay[f[1]] = f; order[#order + 1] = f[1] end
            for _, s in ipairs(h.d or {}) do
                local f = F(s)
                local g = byDay[f[1]]
                if g then
                    -- same day: lowest, Σ market, n market, qty (most recent), gone, added, scans
                    g[2] = (g[2] and f[2]) and math.min(g[2], f[2]) or g[2] or f[2]
                    g[3] = ((g[3] or 0) + (f[3] or 0)) > 0 and ((g[3] or 0) + (f[3] or 0)) or nil
                    g[4] = (g[4] or 0) + (f[4] or 0)
                    g[5] = f[5] or g[5]
                    g[6] = (g[6] or f[6]) and ((g[6] or 0) + (f[6] or 0)) or nil
                    g[7] = (g[7] or f[7]) and ((g[7] or 0) + (f[7] or 0)) or nil
                    g[8] = (g[8] or 0) + (f[8] or 0)
                else
                    byDay[f[1]] = f; order[#order + 1] = f[1]
                end
            end
            table.sort(order)
            d.d = {}
            for _, day in ipairs(order) do
                local f = byDay[day]
                d.d[#d.d + 1] = table.concat({ N(f[1]), N(f[2]), N(f[3]), N(f[4] or 0), N(f[5]), N(f[6]), N(f[7]), N(f[8] or 1) }, ",")
            end
            if (h.lt or 0) >= (d.lt or 0) then d.lad, d.lhi, d.lt = h.lad, h.lhi, h.lt end
        end
    end
end
local function MergeMarket(dst, src)
    dst.items, dst.obs = dst.items or {}, dst.obs or {}
    for id, it in pairs(src.items or {}) do
        local d = dst.items[id]
        if not d then dst.items[id] = it
        else
            for day, v in pairs(it.d or {}) do d.d[day] = (d.d[day] or 0) + v end
            d.seen = math.max(d.seen or 0, it.seen or 0)
        end
    end
    for day, v in pairs(src.obs or {}) do dst.obs[day] = (dst.obs[day] or 0) + v end
    dst.scans = (dst.scans or 0) + (src.scans or 0)
    local newer = (src.last and src.last.t or 0) >= (dst.last and dst.last.t or 0)
    if newer then
        dst.last = src.last
        if src.flips then dst.flips = src.flips end
        if src.flipBought then dst.flipBought = src.flipBought end
    end
    if src.book then
        dst.book = dst.book or {}
        for id, b in pairs(src.book) do dst.book[id] = b end
    end
end
function ns.FixEmptyRealm()
    local db = ns.db
    local realm = ns.Realm()
    if realm == "" or realm == "?" then return 0 end
    local moved = 0
    local function Take(root, merge)
        if type(root) ~= "table" or type(root[""]) ~= "table" then return end
        if root[realm] == nil then root[realm] = root[""]
        else merge(root[realm], root[""]) end
        root[""] = nil
        moved = moved + 1
    end
    Take(db.prices, MergePrices)
    Take(db.hist, MergeHist)
    Take(db.market, MergeMarket)
    Take(db.scan, function(dst, src)
        for k, v in pairs(src) do if type(v) == "number" then dst[k] = math.max(dst[k] or 0, v) end end
    end)
    for _, c in pairs(db.chars or {}) do if c.realm == "" then c.realm = realm end end
    return moved
end

function ns.InitDB()
    ImpotPointGouvDB = ImpotPointGouvDB or {}
    local fresh = ImpotPointGouvDB.version == nil
    Merge(ImpotPointGouvDB, DEFAULTS)
    ns.db = ImpotPointGouvDB
    if (ns.db.version or 1) < 2 then
        if not fresh then
            local t, s = RepairLogoutZeros(ns.db)
            if t + s > 0 then
                ns.repairMsg = (Tr("data repaired: %d false \"Offline change\" removed, %d false zero points removed from the chart.")):format(t, s)
            end
        end
        ns.db.version = 2
    end
    if ns.db.version < 3 then
        local n = fresh and 0 or RepairDoubleOffline(ns.db)
        if n > 0 then ns.repairMsg = (Tr("data repaired: %d \"Offline change\" counted twice removed.")):format(n) end
        ns.db.version = 3
    end    -- Session spent with an empty realm name: its data goes back into the real realm.
    if not fresh then ns.FixEmptyRealm() end
    -- Drop empty names saved by scans (listings read before the game had loaded the item).
    for id, n in pairs(ns.db.items or {}) do if n == "" then ns.db.items[id] = nil end end
end

-- ---------------------------------------------------------------- money
local GOLD_ICON   = "|TInterface\\MoneyFrame\\UI-GoldIcon:%d:%d:1:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:%d:%d:1:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:%d:%d:1:0|t"

local function Thousands(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end
ns.Thousands = Thousands

-- Format with icons: 12[gold] 05[silver] 30[copper]. opts.sign = true to force +/−.
function ns.FormatMoney(copper, opts)
    opts = opts or {}
    copper = math.floor((copper or 0) + 0.5)
    local neg = copper < 0
    local v = math.abs(copper)
    local g, s, c = math.floor(v / 10000), math.floor(v / 100) % 100, v % 100
    local size = opts.iconSize or 0
    local parts = {}
    if g > 0 then parts[#parts + 1] = Thousands(g) .. GOLD_ICON:format(size, size) end
    if (s > 0 or g > 0) and not (opts.short and g >= 100) then
        parts[#parts + 1] = (g > 0 and ("%02d"):format(s) or tostring(s)) .. SILVER_ICON:format(size, size)
    end
    if not opts.short or (g == 0) then
        if c > 0 or #parts == 0 then
            parts[#parts + 1] = ((g > 0 or s > 0) and ("%02d"):format(c) or tostring(c)) .. COPPER_ICON:format(size, size)
        end
    end
    local text = table.concat(parts, " ")
    if neg then text = "−" .. text elseif opts.sign and copper > 0 then text = "+" .. text end
    if opts.color then
        if copper > 0 then text = "|cff5cd173" .. text .. "|r"
        elseif copper < 0 then text = "|cffed5c52" .. text .. "|r" end
    end
    return text
end

-- Compact text for axes: "1.2k g", "35 g", "80 s", "40 c".
function ns.FormatMoneyAxis(copper)
    local v = math.abs(copper)
    local sign = copper < 0 and "−" or ""
    if v >= 10000000 then return sign .. ((Tr("%.1fk g")):format(v / 10000000):gsub("%.0k", "k"))
    elseif v >= 10000 then
        local g = v / 10000
        if g >= 10 or g == math.floor(g) then return sign .. ("%d g"):format(math.floor(g + 0.5)) end
        return sign .. ("%.1f g"):format(g)
    elseif v >= 100 then return sign .. ("%d s"):format(math.floor(v / 100 + 0.5))
    else return sign .. ("%d c"):format(v) end
end

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffe0a83dImpotPointGouv|r : " .. tostring(msg))
end

-- "CAMWOW EU4 Realm 4 PvP" -> "EU4 · Realm 4 · PvP" (WoW Forever's internal name).
function ns.PrettyRealm(realm)
    if not realm or realm == "" then return "" end
    local r = realm:gsub("^CAMWOW%s*", "")
    r = r:gsub("%s+(Realm%s+%d+)", " · %1"):gsub("%s+(PvP)$", " · %1"):gsub("%s+(PvE)$", " · %1")
        :gsub("%s+(RP)$", " · %1")
    return r
end

function ns.ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 0.92, 0.90, 0.84
end


-- ---------------------------------------------------------------- retail compatibility
-- WoW Forever runs on a retail client: several old global functions no longer
-- exist (moved to C_Item / C_MerchantFrame). Always go through these shortcuts.
-- Every name the game returns is kept (ns.db.items): lists show it even when the game's item cache
-- no longer has it, instead of an empty name that blinks as items load.
local function LearnName(id, name, ...)
    if name and name ~= "" and type(id) == "number" and ns.db and ns.db.items and ns.db.items[id] ~= name then
        ns.db.items[id] = name
    end
    return name, ...
end
function ns.GetItemInfo(id)
    if not id then return nil end
    local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not fn then return nil end
    return LearnName(id, fn(id))
end

-- Asks the game for an item's info, at most once every 10 min per item. Pages only redraw for
-- items requested this way (ns.ItemWanted), not for every answer from the game:
-- otherwise each redraw asks again, the game answers, we redraw... forever.
local asked = {}
function ns.RequestItem(id)
    if type(id) ~= "number" or not (C_Item and C_Item.RequestLoadItemDataByID) then return end
    local now = GetTime and GetTime() or 0
    if asked[id] and now - asked[id] < 600 then return end
    asked[id] = now
    pcall(C_Item.RequestLoadItemDataByID, id)
end
function ns.ItemWanted(id)
    local t = id and asked[id]
    return t ~= nil and (GetTime and GetTime() or 0) - t < 60
end
function ns.GetItemCount(id)
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    return fn and fn(id) or 0
end
function ns.GetItemIcon(id)
    local fn = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
    return fn and fn(id) or nil
end
-- Returns the historical format: name, texture, price, quantity, numAvailable, isPurchasable, isUsable, extendedCost
function ns.GetMerchantItemInfo(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(i)
        if not info then return nil end
        return info.name, info.texture, info.price, info.stackCount, info.numAvailable, info.isPurchasable,
            info.isUsable, info.hasExtendedCost
    end
    if GetMerchantItemInfo then return GetMerchantItemInfo(i) end
end

-- Recognizes AH mails through the game's localized subjects.
-- Returns kind ("sale"|"won"|"expired"|"cancelled"|"outbid") and the captured item name.
local function SubjectPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
    p = p:gsub("%%s", "(.+)")
    return "^" .. p
end
local subjectPatterns
function ns.AuctionMailKind(subject)
    if not subject then return nil end
    if not subjectPatterns then
        subjectPatterns = {}
        local defs = {
            { "sale", AUCTION_SOLD_MAIL_SUBJECT }, { "won", AUCTION_WON_MAIL_SUBJECT },
            { "expired", AUCTION_EXPIRED_MAIL_SUBJECT }, { "cancelled", AUCTION_REMOVED_MAIL_SUBJECT },
            { "outbid", AUCTION_OUTBID_MAIL_SUBJECT },
        }
        for _, d in ipairs(defs) do
            local p = SubjectPattern(d[2])
            if p then subjectPatterns[#subjectPatterns + 1] = { d[1], p } end
        end
    end
    for _, sp in ipairs(subjectPatterns) do
        local item = subject:match(sp[2])
        if item then return sp[1], (item:gsub("%s*%(%d+%)%s*$", "")) end
    end
end

-- Small internal event bus (the Ledger notifies the UI).
local listeners = {}
function ns.On(name, fn)
    listeners[name] = listeners[name] or {}
    -- Timed per listener (/ipg perf): "File:EVENT".
    if ns.Profile then fn = ns.Profile.Wrap(ns.Profile.Caller(3) .. ":" .. name, fn) end
    table.insert(listeners[name], fn)
end
function ns.Fire(name, ...)
    for _, fn in ipairs(listeners[name] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then geterrorhandler()(err) end
    end
end


-- AH "commodity" item (bought by quantity, without picking the listing): in practice, what stacks.
-- (GetItemCommodityStatus expects a bag slot, not an ID: unusable here.)
function ns.IsCommodity(id)
    local stack = select(8, ns.GetItemInfo(id))
    return stack == nil or stack > 1
end

-- Colored label of a craft's best outlet (shown on the queue rows).
function ns.ChannelLabel(ch)
    if ch == "vendor" then return "|cffe0a83dVendor|r" end
    if ch == "de" then return "|cffbf8cffDE|r" end
    if ch == "ah" then return "|cff8cbff2AH|r" end
    return ""
end
