-- ImpotPointGouv : namespace, base de données, utilitaires.
local ADDON, ns = ...
local Tr = ns.L
ns.name = ADDON
ns.version = "0.20.1"
_G.ImpotPointGouv = ns

ns.MEDIA = "Interface\\AddOns\\" .. ADDON .. Tr("\\media\\")

-- Catégories de mouvements d'or. group = "ah" pour tout ce qui touche l'Hôtel des ventes.
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
    prices = {},  -- [royaume][itemID] = { cur, qty, t, d = { {jour, plusBas, qté}, ... } }
    vendor = {},  -- [itemID] = prix d'achat unitaire chez le marchand (appris)
    items = {},   -- [itemID] = nom
    recipes = {}, -- [métier][recette] = { p = produit, m = quantité produite, r = { {id, n}, ... } }
    scan = {},    -- [royaume] = { lastFull = time }
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

-- v2 : répare les données faussées par l'ancien relevé de déconnexion (GetMoney() = 0 à la sortie).
local function RepairLogoutZeros(db)
    local removedTx, removedSnaps = 0, 0
    -- 1) "Offline change" dont le relevé précédent était ce faux 0 : c'est le solde recompté.
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
    -- 2) Relevés à 0 juste après un relevé non nul (déconnexions), puis solde enregistré corrigé.
    for key, s in pairs(db.snaps) do
        for i = #s, 2, -1 do
            if s[i][2] == 0 and s[i - 1][2] > 0 then table.remove(s, i); removedSnaps = removedSnaps + 1 end
        end
        if db.chars[key] and s[#s] then db.chars[key].money = s[#s][2] end
    end
    return removedTx, removedSnaps
end

-- v3 : un "Offline change" identique à une opération du même perso juste avant = la même somme comptée deux fois.
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
    end
end

-- ---------------------------------------------------------------- argent
local GOLD_ICON   = "|TInterface\\MoneyFrame\\UI-GoldIcon:%d:%d:1:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:%d:%d:1:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:%d:%d:1:0|t"

local function Thousands(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end
ns.Thousands = Thousands

-- Format avec icônes : 12[or] 05[argent] 30[cuivre]. opts.sign = true pour forcer +/−.
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
        if copper > 0 then text = Tr("|cff5cd173") .. text .. "|r"
        elseif copper < 0 then text = Tr("|cffed5c52") .. text .. "|r" end
    end
    return text
end

-- Texte compact pour les axes : "1,2k po", "35 po", "80 pa", "40 pc".
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

-- "CAMWOW EU4 Realm 4 PvP" -> "EU4 · Realm 4 · PvP" (nom interne de WoW Forever).
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


-- ---------------------------------------------------------------- compatibilité retail
-- WoW Forever tourne sur un client retail : plusieurs anciennes fonctions globales n'existent
-- plus (déplacées dans C_Item / C_MerchantFrame). On passe toujours par ces raccourcis.
function ns.GetItemInfo(id)
    if not id then return nil end
    local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not fn then return nil end
    return fn(id)
end
function ns.GetItemCount(id)
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    return fn and fn(id) or 0
end
function ns.GetItemIcon(id)
    local fn = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
    return fn and fn(id) or nil
end
-- Renvoie le format historique : name, texture, price, quantity, numAvailable, isPurchasable, isUsable, extendedCost
function ns.GetMerchantItemInfo(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(i)
        if not info then return nil end
        return info.name, info.texture, info.price, info.stackCount, info.numAvailable, info.isPurchasable,
            info.isUsable, info.hasExtendedCost
    end
    if GetMerchantItemInfo then return GetMerchantItemInfo(i) end
end

-- Reconnaît les courriers de l'HV via les sujets localisés du jeu.
-- Renvoie kind ("sale"|"won"|"expired"|"cancelled"|"outbid") et le nom d'objet capturé.
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

-- Petit bus d'événements interne (le Ledger prévient l'UI).
local listeners = {}
function ns.On(name, fn) listeners[name] = listeners[name] or {}; table.insert(listeners[name], fn) end
function ns.Fire(name, ...)
    for _, fn in ipairs(listeners[name] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then geterrorhandler()(err) end
    end
end


-- Objet "commodité" de l'HV (acheté en quantité, sans choisir l'annonce) : en pratique, ce qui s'empile.
-- (GetItemCommodityStatus attend un emplacement de sac, pas un ID : inutilisable ici.)
function ns.IsCommodity(id)
    local stack = select(8, ns.GetItemInfo(id))
    return stack == nil or stack > 1
end

-- Libellé coloré du meilleur débouché d'une création (affiché sur les lignes de la file).
function ns.ChannelLabel(ch)
    if ch == "vendor" then return "|cffe0a83dVendor|r" end
    if ch == "de" then return "|cffbf8cffDE|r" end
    if ch == "ah" then return "|cff8cbff2AH|r" end
    return ""
end
