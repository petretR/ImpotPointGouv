-- ImpotPointGouv : base de prix (HV + marchands) et scan de l'Hôtel des ventes.
--
-- Prix HV : pour chaque objet, un relevé par jour (prix unitaire le plus bas, quantité en vente).
--   Valeur marché = médiane des relevés journaliers des 7 derniers relevés (sur 14 jours max),
--   ce qui lisse les sous-cotes ponctuelles.
-- Prix marchand : appris en ouvrant un marchand (prix réellement payé, réputation comprise).
-- Scans : "Scan professions" (recherche exacte de chaque compo/produit de vos métiers, page par page)
--   et "Full scan" (toute l'HV en une requête, 15 min de recharge imposée par le jeu).
local _, ns = ...
local Tr = ns.L
local P = {}
ns.Prices = P
local T = ns.Theme
local C = T.C

-- Compos classiques vendues par les marchands (Couture / Enchantement).
-- Tant qu'aucun marchand ne vous les a montrées, leur prix est estimé (≈ 4 × prix de revente).
P.SEED_VENDOR = {
    [2320] = true, [2321] = true, [4291] = true, [8343] = true,   -- fils grossier, fin, soie, soie épais
    [2604] = true, [2324] = true, [4340] = true, [6260] = true,   -- teintures rouge, javel, grise, bleue
    [4470] = true, [6217] = true, [3371] = true, [3372] = true,   -- bois simple, bâtonnet de cuivre, fioles
    [14341] = true, [2605] = true, [2325] = true, [4341] = true,  -- fil runique, teintures verte, noire, jaune
    [6261] = true, [4342] = true, [10290] = true, [8925] = true,  -- teintures orange, violette, rose ; fiole de cristal
    [18256] = true, [2880] = true, [3466] = true, [4289] = true,  -- fiole imprégnée, flux faible / fort, sel
    [3857] = true, [6338] = true, [11128] = true, [11144] = true, -- charbon, bâtonnets argent / or / vrai-argent
    [2678] = true, [2692] = true, [3713] = true, [159] = true,    -- épices douces / piquantes / apaisantes, eau
    [1179] = true, [2665] = true, [4399] = true, [4400] = true,   -- lait, herbes, souche de bois, tige lourde
    [10647] = true, [10648] = true, [4471] = true, [17194] = true,-- papier / parchemin d'ingénieur, briquet, épices
}

local function Realm() return (GetRealmName and GetRealmName()) or "?" end
local function DB()
    local r = Realm()
    ns.db.prices[r] = ns.db.prices[r] or {}
    return ns.db.prices[r]
end
local function Today() return math.floor(time() / 86400) end

function P.ItemID(link)
    if type(link) == "number" then return link end
    if not link then return nil end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

function P.Name(id)
    if not id then return "?" end
    local n = ns.GetItemInfo(id)
    return n or ns.db.items[id] or ("item " .. id)
end

-- ------------------------------------------------------------ enregistrement
-- full = true : liste complète de l'objet (scan) -> quantité fiable, prix du jour remplacé.
-- ladder (facultatif) : { [prix unitaire] = quantité } vus par ce scan, pour l'historique de marché.
function P.Record(id, low, qty, full, ladder)
    if not id then return end
    local db = DB()
    local e = db[id]
    if not e then e = { d = {} }; db[id] = e end
    local day = Today()
    local last = e.d[#e.d]
    if low then
        if not last or last[1] ~= day then
            e.d[#e.d + 1] = { day, low, qty or 0 }
            while #e.d > 30 do table.remove(e.d, 1) end
        elseif full then
            last[2], last[3] = low, qty or 0
        else
            last[2] = math.min(last[2], low)
        end
        e.cur = low
    elseif full then
        e.cur = nil -- plus aucune annonce
    end
    -- Partage avec Auctionator : son infobulle affiche alors les prix de nos scans.
    if full and low and ns.db.settings.shareAuctionator ~= false and Auctionator and Auctionator.Database
        and Auctionator.Database.SetPrice then
        pcall(Auctionator.Database.SetPrice, Auctionator.Database, tostring(id), low, qty)
    end
    if full then
        e.qty = qty or 0
        -- Historique fin (un point par scan, 15 min mini entre deux) : prix habituel, volatilité, ventes.
        -- Seulement pour les objets suivis (listes), pour garder un fichier de sauvegarde léger.
        if ns.Lists and ns.Lists.IsWatched and ns.Lists.IsWatched(id) then
        e.h = e.h or {}
        local h, now = e.h, time()
        local lp = h[#h]
        if lp and now - lp[1] < 900 then lp[2], lp[3] = low or 0, qty or 0
        else h[#h + 1] = { now, low or 0, qty or 0 } end
        while #h > 0 and (#h > 120 or now - h[1][1] > 21 * 86400) do table.remove(h, 1) end
        if ns.History then ns.History.Note(id, low, qty, ladder) end
        end
    end
    e.t = time()
end

-- Statistiques sur 7 jours : médiane (prix habituel), bas (20 %), haut (80 %), volatilité, ventes / jour.
local function Pct(sorted, p)
    local n = #sorted
    if n == 0 then return nil end
    return sorted[math.max(1, math.min(n, math.ceil(n * p)))]
end
function P.Stats(id)
    local e = P.Entry(id)
    if not e then return nil end
    local now, vals = time(), {}
    local h = e.h or {}
    for _, pt in ipairs(h) do
        if now - pt[1] <= 7 * 86400 and pt[2] > 0 then vals[#vals + 1] = pt[2] end
    end
    if #vals < 3 and e.d then
        for i = #e.d, math.max(1, #e.d - 6), -1 do
            if e.d[i][1] >= math.floor(now / 86400) - 7 then vals[#vals + 1] = e.d[i][2] end
        end
    end
    local st = { cur = e.cur, t = e.t, qty = e.qty, n = #vals }
    if #vals > 0 then
        table.sort(vals)
        st.med, st.low, st.high = Pct(vals, 0.5), Pct(vals, 0.2), Pct(vals, 0.8)
        local sum = 0
        for _, v in ipairs(vals) do sum = sum + v end
        local mean = sum / #vals
        local var = 0
        for _, v in ipairs(vals) do var = var + (v - mean) ^ 2 end
        st.cv = mean > 0 and math.sqrt(var / #vals) / mean or 0
    end
    -- Ventes estimées : baisses de quantité entre deux scans successifs (annulations comprises).
    local drop, first, last = 0, nil, nil
    for i, pt in ipairs(h) do
        if now - pt[1] <= 7 * 86400 then
            first = first or pt[1]; last = pt[1]
            local prev = h[i - 1]
            if prev and now - prev[1] <= 7 * 86400 and prev[3] > pt[3] then drop = drop + (prev[3] - pt[3]) end
        end
    end
    if first and last and last - first >= 6 * 3600 then st.sales = drop / ((last - first) / 86400) end
    -- Courbe : plus bas prix par jour, 7 derniers jours.
    local today, spark = math.floor(now / 86400), {}
    for _, pt in ipairs(h) do
        local d = today - math.floor(pt[1] / 86400)
        if d < 7 and pt[2] > 0 then
            local k = 7 - d
            spark[k] = spark[k] and math.min(spark[k], pt[2]) or pt[2]
        end
    end
    st.spark = spark
    return st
end

function P.Entry(id) return id and DB()[id] end

function P.Market(id)
    local e = P.Entry(id)
    if not e or not e.d or #e.d == 0 then return nil end
    local vals, minDay = {}, Today() - 14
    for i = #e.d, math.max(1, #e.d - 6), -1 do
        if e.d[i][1] >= minDay then vals[#vals + 1] = e.d[i][2] end
    end
    if #vals == 0 then return nil end
    table.sort(vals)
    local n = #vals
    if n % 2 == 1 then return vals[(n + 1) / 2] end
    return math.floor((vals[n / 2] + vals[n / 2 + 1]) / 2)
end

-- Valeur HV retenue : la plus basse entre marché et annonce actuelle récente (on vend au prix du marché réel).
function P.AHValue(id)
    local e = P.Entry(id)
    local m = P.Market(id)
    if e and e.cur and e.t and time() - e.t < 2 * 86400 then
        return m and math.min(m, e.cur) or e.cur
    end
    return m
end

function P.Age(id)
    local e = P.Entry(id)
    return e and e.t and (time() - e.t) or nil
end

function P.VendorSell(id)
    if not id then return nil end
    ns.db.vsell = ns.db.vsell or {}
    local sp = select(11, ns.GetItemInfo(id))
    if sp then
        if sp > 0 then ns.db.vsell[id] = sp else ns.db.vsell[id] = nil end
        return sp > 0 and sp or nil
    end
    return ns.db.vsell[id] -- appris plus tôt (prix marchand fixe)
end

-- Prix d'achat marchand : appris (exact) ou estimé pour les compos connues.
function P.VendorBuy(id)
    local v = id and ns.db.vendor[id]
    if v then return v, false end
    if id and P.SEED_VENDOR[id] then
        local sp = P.VendorSell(id)
        if sp then return sp * 4, true end
    end
    return nil
end

-- ------------------------------------------------------------ désenchantement
-- Table Classic (WoW Forever peut l'avoir modifiée : valeur indicative).
-- Pour chaque tranche de niveau d'objet : { {itemID, chance, qtéMoyenne}, ... }
-- Armures vertes : surtout poussière ; armes vertes : surtout essence (75/20 inversé).
P.DE_MATS = { 10940, 10938, 10939, 10978, 10998, 11082, 11083, 11084, 11134, 11135, 11137, 11138, 11139 }
local DE_GREEN = {
    { 15, { { 10940, 0.80, 1.5 }, { 10938, 0.20, 1.5 } } },
    { 20, { { 10940, 0.75, 2.5 }, { 10939, 0.20, 1.5 }, { 10978, 0.05, 1 } } },
    { 25, { { 10940, 0.75, 5.0 }, { 10998, 0.15, 1.5 }, { 10978, 0.10, 1 } } },
    { 30, { { 11083, 0.75, 1.5 }, { 11082, 0.20, 1.5 }, { 11084, 0.05, 1 } } },
    { 35, { { 11083, 0.75, 3.5 }, { 11134, 0.20, 1.5 }, { 11138, 0.05, 1 } } },
    { 40, { { 11137, 0.75, 1.5 }, { 11135, 0.20, 1.5 }, { 11139, 0.05, 1 } } },
}
local DE_BLUE = { { 25, 10978 }, { 30, 11084 }, { 35, 11138 }, { 40, 11139 } }

-- Résultats réels (journal des désenchantements) regroupés par tranche : qualité / niveau d'objet / arme-armure.
local obs, obsDirty = {}, true
ns.On("DE_LOGGED", function() obsDirty = true end)

local function TrancheKey(quality, ilvl, classID)
    local table_ = quality == 3 and DE_BLUE or DE_GREEN
    for i, row in ipairs(table_) do
        if ilvl <= row[1] then return quality .. ":" .. i .. ":" .. (classID == 2 and "w" or "a") end
    end
end

local function BuildObserved()
    wipe(obs)
    for _, e in ipairs(ns.db.deLog or {}) do
        if e.id then
            local _, _, q, il, _, _, _, _, _, _, _, cid = ns.GetItemInfo(e.id)
            q, il = e.q or q, e.ilvl or il
            local key = q and il and TrancheKey(q, il, cid)
            if key then
                local o = obs[key] or { n = 0, out = {} }
                obs[key] = o
                o.n = o.n + 1
                for _, out in ipairs(e.out) do o.out[out[1]] = (o.out[out[1]] or 0) + out[2] end
            end
        end
    end
    obsDirty = false
end

P.MIN_DE_SAMPLES = 5

-- Valeur nette attendue (HV − 5 %) d'un désenchantement, ou nil si non désenchantable / prix inconnus.
-- 2e valeur : "observed" (vos résultats, ≥ 5 désenchantements de cette tranche) ou "table" (table Classic).
function P.DisenchantValue(id)
    local v, src = P.DisenchantValueRaw(id)
    return v, src
end

function P.DisenchantValueRaw(id)
    if not id then return nil end
    local _, _, quality, ilvl, _, _, _, _, equipLoc, _, _, classID = ns.GetItemInfo(id)
    if not quality or not ilvl or quality < 2 or quality > 3 then return nil end
    if classID and classID ~= 2 and classID ~= 4 then return nil end
    if not equipLoc or equipLoc == "" or equipLoc == "INVTYPE_BAG" then return nil end
    local function Price(mat) local v = P.AHValue(mat); return v and v * 0.95 end
    if obsDirty then BuildObserved() end
    local o = obs[TrancheKey(quality, ilvl, classID) or ""]
    if o and o.n >= P.MIN_DE_SAMPLES then
        local total, known = 0, false
        for mat, qty in pairs(o.out) do
            local p = Price(mat)
            if p then total = total + p * qty / o.n; known = true end
        end
        if known then return total, "observed" end
    end
    if quality == 3 then
        for _, row in ipairs(DE_BLUE) do
            if ilvl <= row[1] then return Price(row[2]), "table" end
        end
        return nil
    end
    for _, row in ipairs(DE_GREEN) do
        if ilvl <= row[1] then
            local outs = row[2]
            if classID == 2 and outs[2] then -- arme : chances poussière/essence inversées
                outs = { { outs[1][1], outs[2][2], outs[1][3] }, { outs[2][1], outs[1][2], outs[2][3] }, outs[3] }
            end
            local total, known = 0, false
            for _, o in ipairs(outs) do
                local p = Price(o[1])
                if p then total = total + p * o[2] * o[3]; known = true end
            end
            if known then return total, "table" end
            return nil
        end
    end
end

function P.IsVendorItem(id) return id and (ns.db.vendor[id] or P.SEED_VENDOR[id]) and true or false end

function P.Ago(seconds)
    if not seconds then return "never" end
    if seconds < 90 then return "just now" end
    if seconds < 3600 then return (Tr("%d min ago")):format(math.floor(seconds / 60)) end
    if seconds < 86400 * 2 then return (Tr("%dh ago")):format(math.floor(seconds / 3600)) end
    return (Tr("%dd ago")):format(math.floor(seconds / 86400))
end

-- ------------------------------------------------------------ marchands
local function LearnMerchant()
    if not GetMerchantNumItems then return end
    local learned = 0
    for i = 1, GetMerchantNumItems() do
        local name, _, price, quantity, numAvailable, _, _, extendedCost = ns.GetMerchantItemInfo(i)
        local id = P.ItemID(GetMerchantItemLink and GetMerchantItemLink(i))
        if id and price and price > 0 and (quantity or 0) > 0 and not extendedCost and numAvailable == -1 then
            local unit = price / quantity
            if ns.db.vendor[id] ~= unit then learned = learned + 1 end
            ns.db.vendor[id] = unit
            if name then ns.db.items[id] = name end
        end
    end
    if learned > 0 then ns.Fire("PRICES_CHANGED") end
end

-- ------------------------------------------------------------ lecture d'une page HV
local function ReadListing(i)
    local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemId, hasAllInfo = GetAuctionItemInfo("list", i)
    if not itemId or itemId == 0 then itemId = P.ItemID(GetAuctionItemLink and GetAuctionItemLink("list", i)) end
    return name, count or 1, buyout or 0, itemId, hasAllInfo
end

local function Accumulate(acc, name, count, buyout, id)
    if not id or not buyout or buyout <= 0 or count <= 0 then return end
    local unit = math.floor(buyout / count)
    local a = acc[id]
    if not a then a = { low = unit, qty = 0 }; acc[id] = a end
    if unit < a.low then a.low = unit end
    a.qty = a.qty + count
    -- Détail par prix (en mémoire seulement) : sert à repérer ce qui est listé sous le prix marchand.
    a.b = a.b or {}
    a.b[unit] = (a.b[unit] or 0) + count
    if name then ns.db.items[id] = name end
end

-- ------------------------------------------------------------ scan
local scan -- état courant
local bar  -- barre d'interface sur l'HV

local function Status(text)
    if bar then bar.status:SetText(text or "") end
end
P.Status = Status
function P.Bar() return bar end

local function ScanTargets()
    local ids, list = {}, {}
    for _, recipes in pairs(ns.db.recipes) do
        for _, r in pairs(recipes) do
            if r.p then ids[r.p] = true end
            for _, rg in ipairs(r.r or {}) do
                if not ns.db.vendor[rg[1]] then ids[rg[1]] = true end
            end
        end
    end
    for _, id in ipairs(P.DE_MATS) do ids[id] = true end
    for id in pairs(ids) do
        local name = ns.db.items[id] or ns.GetItemInfo(id)
        if name then list[#list + 1] = { id = id, name = name } end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local SendNext, FinishScan

local function UpdateBar()
    if not bar then return end
    if scan and scan.mode == "items" then
        bar.scan.text:SetText(scan.manual and "Continue" or "Stop")
    elseif scan then
        bar.scan.text:SetText(Tr("Stop"))
    else
        bar.scan.text:SetText(Tr("Scan"))
    end
end

local StartDepth
function FinishScan(msg)
    local s = scan
    scan = nil
    -- Après le scan des métiers : profondeur (quantités par prix) des composants, objet par objet.
    if s and not msg and s.mode == "items" and StartDepth and StartDepth(s) then return end
    if s and s.mode == "list" and not msg then
        msg = (Tr("%s scanned: %d / %d items found.")):format(s.label, s.got or 0, #s.ids)
    end
    if s and s.mode == "depth" and not msg then
        msg = (Tr("Scan done: %d prices, market depth of %d reagents.")):format(s.items or 0, s.got or 0)
    end
    if s and not msg then
        if s.mode == "full" then
            local n = 0
            for _ in pairs(s.acc) do n = n + 1 end
            msg = (Tr("Full scan done: %d items recorded.")):format(n)
        else
            msg = (Tr("Profession scan done: %d items, %d listed.")):format(#s.queue, s.found or 0)
        end
    end
    Status(msg)
    UpdateBar()
    ns.Fire("PRICES_CHANGED")
end

local function FinalizeItem()
    local q = scan.queue[scan.idx]
    local a = scan.acc[q.id]
    if a then
        P.Record(q.id, a.low, a.qty, true, a.b)
        scan.found = (scan.found or 0) + 1
    else
        P.Record(q.id, nil, 0, true, {})
    end
    scan.idx, scan.page = scan.idx + 1, 0
end

-- Envoie la requête suivante (recherche exacte, page par page).
function SendNext(fromClick)
    if not scan or scan.mode ~= "items" then return end
    if scan.manual and not fromClick then return end
    if scan.idx > #scan.queue then FinishScan(); return end
    local canQuery = CanSendAuctionQuery()
    if not canQuery then
        if not scan.manual then C_Timer.After(0.25, function() SendNext(false) end) end
        return
    end
    local q = scan.queue[scan.idx]
    scan.awaiting = true
    scan.reqId = (scan.reqId or 0) + 1
    local req = scan.reqId
    scan.ours = true
    Status((Tr("Profession scan: %d / %d  ·  %s%s")):format(scan.idx, #scan.queue, q.name,
        scan.page > 0 and (" (page " .. (scan.page + 1) .. ")") or ""))
    QueryAuctionItems(q.name, nil, nil, scan.page, false, nil, false, true, nil)
    -- Pas de réponse : on réessaie une fois puis on passe à l'objet suivant.
    C_Timer.After(5, function()
        if scan and scan.reqId == req and scan.awaiting and not scan.manual then
            scan.awaiting = false
            scan.retries = (scan.retries or 0) + 1
            if scan.retries > 1 then scan.retries = 0; FinalizeItem() end
            SendNext(false)
        end
    end)
end

local function OnItemsPage()
    local batch, total = GetNumAuctionItems("list")
    local q = scan.queue[scan.idx]
    for i = 1, batch do
        local name, count, buyout, id = ReadListing(i)
        if id == q.id or (name == q.name) then Accumulate(scan.acc, name, count, buyout, q.id) end
    end
    scan.awaiting = false
    scan.retries = 0
    if (scan.page + 1) * (NUM_AUCTION_ITEMS_PER_PAGE or 50) < (total or 0) and scan.page < 20 then
        scan.page = scan.page + 1
    else
        FinalizeItem()
    end
    if scan.idx > #scan.queue then FinishScan(); return end
    if scan.manual then
        Status((Tr("%d / %d  ·  click Continue for the next search")):format(scan.idx, #scan.queue))
    else
        C_Timer.After(0.05, function() SendNext(false) end)
    end
end

-- Scan complet : lecture par lots pour ne pas figer le jeu.
local function ProcessFull()
    local n = GetNumAuctionItems("list")
    local i = 1
    local function Chunk()
        if not scan or scan.mode ~= "full" then return end
        local last = math.min(n, i + 399)
        for k = i, last do
            local name, count, buyout, id = ReadListing(k)
            Accumulate(scan.acc, name, count, buyout, id)
        end
        i = last + 1
        Status((Tr("Full scan: reading %d / %d auctions…")):format(last, n))
        if i <= n then
            C_Timer.After(0.02, Chunk)
        else
            for id, a in pairs(scan.acc) do P.Record(id, a.low, a.qty, true, a.b) end
            if ns.Market then ns.Market.OnFullScan(scan.acc) end
            ns.db.scan[Realm()] = ns.db.scan[Realm()] or {}
            ns.db.scan[Realm()].lastFull = time()
            FinishScan()
        end
    end
    Chunk()
end

-- ------------------------------------------------------------ HV moderne (C_AuctionHouse)
-- WoW Forever utilise l'HV moderne : recherche "browse" par nom, résultats agrégés par objet
-- (prix minimum + quantité totale), et ReplicateItems pour le scan complet.
local AHM = C_AuctionHouse
local function IsModern() AHM = C_AuctionHouse; return AHM ~= nil and AHM.SendBrowseQuery ~= nil end
P.IsModern = IsModern

local function ModernReady()
    return not AHM.IsThrottledMessageSystemReady or AHM.IsThrottledMessageSystemReady()
end

local ModernSend
local function ModernFinalize(found, low, qty)
    local q = scan.queue[scan.idx]
    if found then
        P.Record(q.id, low, qty, true)
        scan.found = (scan.found or 0) + 1
    elseif scan.complete then
        P.Record(q.id, nil, 0, true)
    end
    scan.idx = scan.idx + 1
    if scan.idx > #scan.queue then FinishScan(); return end
    if scan.manual then
        Status((Tr("%d / %d  ·  click Continue for the next search")):format(scan.idx, #scan.queue))
    else
        C_Timer.After(0.05, function() ModernSend(false) end)
    end
end

function ModernSend(fromClick)
    if not scan or scan.mode ~= "items" then return end
    if scan.manual and not fromClick then return end
    if scan.idx > #scan.queue then FinishScan(); return end
    if not ModernReady() then
        if not scan.manual then C_Timer.After(0.2, function() ModernSend(false) end) end
        return
    end
    local q = scan.queue[scan.idx]
    scan.awaiting = true
    scan.reqId = (scan.reqId or 0) + 1
    local req = scan.reqId
    Status((Tr("Profession scan: %d / %d  ·  %s")):format(scan.idx, #scan.queue, q.name))
    local sorts = {}
    if Enum and Enum.AuctionHouseSortOrder then
        sorts[1] = { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }
    end
    local ok = pcall(AHM.SendBrowseQuery, { searchString = q.name, sorts = sorts, filters = {}, itemClassFilters = {} })
    if not ok then
        scan.awaiting = false
        ModernFinalize(false)
        return
    end
    C_Timer.After(6, function()
        if scan and scan.reqId == req and scan.awaiting and not scan.manual then
            scan.awaiting = false
            ModernFinalize(false)
        end
    end)
end

local function ModernOnBrowse()
    if not IsModern() then return end
    local results = AHM.GetBrowseResults and AHM.GetBrowseResults() or {}
    if scan and scan.mode == "items" and scan.awaiting then
        scan.awaiting = false
        local q = scan.queue[scan.idx]
        local low, qty
        for _, r in ipairs(results) do
            local id = r.itemKey and r.itemKey.itemID
            if id == q.id and r.minPrice and r.minPrice > 0 then
                if not low or r.minPrice < low then low = r.minPrice end
                qty = (qty or 0) + (r.totalQuantity or 0)
            end
        end
        scan.complete = not AHM.HasFullBrowseResults or AHM.HasFullBrowseResults()
        ModernFinalize(low ~= nil, low, qty)
        return
    end
    -- Recherche faite à la main ou par un autre addon : on note les prix minimums vus.
    for _, r in ipairs(results) do
        local id = r.itemKey and r.itemKey.itemID
        if id and r.minPrice and r.minPrice > 0 then P.Record(id, r.minPrice, r.totalQuantity, false) end
    end
end

local function ModernProcessFull()
    if not IsModern() then return end
    local n = AHM.GetNumReplicateItems and AHM.GetNumReplicateItems() or 0
    local i = 0
    local function Chunk()
        if not scan or scan.mode ~= "full" then return end
        local last = math.min(n - 1, i + 499)
        for k = i, last do
            local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemId = AHM.GetReplicateItemInfo(k)
            Accumulate(scan.acc, name, count or 1, buyout or 0, itemId)
        end
        i = last + 1
        Status((Tr("Full scan: reading %d / %d auctions…")):format(math.min(i, n), n))
        if i < n then
            C_Timer.After(0.02, Chunk)
        else
            for id, a in pairs(scan.acc) do P.Record(id, a.low, a.qty, true, a.b) end
            if ns.Market then ns.Market.OnFullScan(scan.acc) end
            ns.db.scan[Realm()] = ns.db.scan[Realm()] or {}
            ns.db.scan[Realm()].lastFull = time()
            FinishScan()
        end
    end
    Chunk()
end

function P.StartItemScan()
    if scan then
        if scan.mode == "items" and scan.manual then
            if IsModern() then ModernSend(true) else SendNext(true) end
            return
        end
        FinishScan(Tr("Scan stopped.")); return
    end
    local queue = ScanTargets()
    if #queue == 0 then
        Status(Tr("Open your profession windows first so the addon learns your recipes."))
        return
    end
    scan = { mode = "items", queue = queue, idx = 1, page = 0, acc = {} }
    UpdateBar()
    if IsModern() then ModernSend(true) else SendNext(true) end
end

-- ------------------------------------------------------------ profondeur des composants
-- Pour chaque composant empilable de vos recettes : toutes les annonces, prix par prix (recherche de commodité).
-- Marche à tout moment, contrairement au scan complet limité à une fois par 15 min.
local function DepthIds()
    local ids, list = {}, {}
    for _, recipes in pairs(ns.db.recipes) do
        for _, r in pairs(recipes) do
            for _, rg in ipairs(r.r or {}) do
                local id = rg[1]
                if id and not ids[id] and not ns.db.vendor[id] and ns.IsCommodity(id) then ids[id] = true; list[#list + 1] = id end
            end
        end
    end
    return list
end

local function DepthNext()
    if not scan or scan.mode ~= "depth" then return end
    scan.i = scan.i + 1
    local id = scan.ids[scan.i]
    if not id then FinishScan(); return end
    local function Send()
        if not scan or scan.mode ~= "depth" or scan.ids[scan.i] ~= id then return end
        if AHM.IsThrottledMessageSystemReady and not AHM.IsThrottledMessageSystemReady() then C_Timer.After(0.2, Send); return end
        Status((Tr("Market depth: %s (%d / %d)…")):format(P.Name(id), scan.i, #scan.ids))
        scan.cur, scan.sent = id, GetTime()
        AHM.SendSearchQuery(AHM.MakeItemKey(id), { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }, false)
        -- Pas de réponse : on passe au suivant.
        local my = scan.i
        C_Timer.After(5, function() if scan and scan.mode == "depth" and scan.i == my and scan.cur == id then scan.cur = nil; DepthNext() end end)
    end
    Send()
end

StartDepth = function(prev)
    if not IsModern() or not AHM.SendSearchQuery or not AHM.MakeItemKey or not AHM.GetCommoditySearchResultInfo then return false end
    local ids = DepthIds()
    if #ids == 0 then return false end
    scan = { mode = "depth", ids = ids, i = 0, got = 0, items = prev and #prev.queue or 0 }
    UpdateBar()
    DepthNext()
    return true
end

-- ------------------------------------------------------------ scan d'une liste (onglet Lists)
local ListNext
function P.ScanIds(ids, label)
    if not IsModern() or not AHM.SendSearchQuery or not AHM.MakeItemKey then Status(Tr("List scan needs the auction house.")); return false end
    if scan then FinishScan(Tr("Scan stopped.")); return false end
    if not ids or #ids == 0 then return false end
    scan = { mode = "list", ids = ids, i = 0, got = 0, label = label or "List" }
    UpdateBar()
    ns.Fire("LIST_SCAN", scan)
    ListNext()
    return true
end
function P.Scanning() return scan end

ListNext = function()
    if not scan or scan.mode ~= "list" then return end
    scan.i = scan.i + 1
    local id = scan.ids[scan.i]
    if not id then FinishScan(); return end
    local function Send()
        if not scan or scan.mode ~= "list" or scan.ids[scan.i] ~= id then return end
        if AHM.IsThrottledMessageSystemReady and not AHM.IsThrottledMessageSystemReady() then C_Timer.After(0.15, Send); return end
        Status(("%s: %s (%d / %d)…"):format(scan.label, P.Name(id), scan.i, #scan.ids))
        scan.cur = id
        scan.commodity = ns.IsCommodity(id)
        local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
        local ok = pcall(AHM.SendSearchQuery, AHM.MakeItemKey(id), sorts, false)
        if not ok then scan.cur = nil; C_Timer.After(0.05, ListNext); return end
        local my = scan.i
        C_Timer.After(4, function()
            if scan and scan.mode == "list" and scan.i == my and scan.cur == id then scan.cur = nil; ListNext() end
        end)
        ns.Fire("LIST_SCAN", scan)
    end
    Send()
end

local function OnListItemResults(itemKey)
    if not scan or scan.mode ~= "list" or not itemKey or itemKey.itemID ~= scan.cur then return end
    local low, total, ladder = nil, 0, {}
    for k = 1, (AHM.GetNumItemSearchResults(itemKey) or 0) do
        local r = AHM.GetItemSearchResultInfo(itemKey, k)
        if r and r.buyoutAmount then
            local q = r.quantity or 1
            local unit = math.floor(r.buyoutAmount / math.max(1, q))
            low = low and math.min(low, unit) or unit
            total = total + q
            ladder[unit] = (ladder[unit] or 0) + q
        end
    end
    P.Record(itemKey.itemID, low, total, true, ladder)
    scan.got = scan.got + 1
    scan.cur = nil
    C_Timer.After(0.05, ListNext)
end

local function OnCommodityResults(itemID)
    if scan and scan.mode == "list" and itemID == scan.cur then
        local n = AHM.GetNumCommoditySearchResults and AHM.GetNumCommoditySearchResults(itemID) or 0
        local ladder, total, low = {}, 0, nil
        for k = 1, n do
            local r = AHM.GetCommoditySearchResultInfo(itemID, k)
            if r and r.unitPrice and r.quantity then
                ladder[r.unitPrice] = (ladder[r.unitPrice] or 0) + r.quantity
                total = total + r.quantity
                low = low and math.min(low, r.unitPrice) or r.unitPrice
            end
        end
        P.Record(itemID, low, total, true, ladder)
        if ns.Market and ns.Market.SetBook then ns.Market.SetBook(itemID, ladder) end
        scan.got = scan.got + 1
        scan.cur = nil
        C_Timer.After(0.05, ListNext)
        return
    end
    if not scan or scan.mode ~= "depth" or itemID ~= scan.cur then return end
    local n = AHM.GetNumCommoditySearchResults and AHM.GetNumCommoditySearchResults(itemID) or 0
    local ladder, total, low = {}, 0, nil
    for k = 1, n do
        local r = AHM.GetCommoditySearchResultInfo(itemID, k)
        if r and r.unitPrice and r.quantity then
            ladder[r.unitPrice] = (ladder[r.unitPrice] or 0) + r.quantity
            total = total + r.quantity
            low = low and math.min(low, r.unitPrice) or r.unitPrice
        end
    end
    if low then P.Record(itemID, low, total, true, ladder) end
    if ns.Market and ns.Market.SetBook then ns.Market.SetBook(itemID, ladder) end
    scan.got = scan.got + 1
    scan.cur = nil
    C_Timer.After(0.05, DepthNext)
end

-- Scan complet possible maintenant ? (le jeu l'autorise toutes les 15 min)
local function FullReady()
    local st = ns.db.scan[Realm()] or {}
    local since = math.min(st.lastFull and (time() - st.lastFull) or math.huge, st.fullFail and (time() - st.fullFail) or math.huge)
    if since < 15 * 60 then return false end
    if IsModern() then return AHM.ReplicateItems ~= nil end
    local _, canAll = CanSendAuctionQuery()
    return canAll and true or false
end

-- Un seul bouton : scan complet quand le jeu le permet (prix de tout + onglet Market),
-- sinon scan de vos métiers seulement (composants et créations).
function P.Scan()
    if scan then
        if scan.mode == "items" then P.StartItemScan() else FinishScan(Tr("Scan stopped.")) end
        return
    end
    if FullReady() then P.StartFullScan() else P.StartItemScan() end
end

function P.StartFullScan()
    if scan then FinishScan(Tr("Scan stopped.")); return end
    if IsModern() then
        local last = ns.db.scan[Realm()] and ns.db.scan[Realm()].lastFull
        if last and time() - last < 15 * 60 then
            Status((Tr("Full scan available in ~%d min (game limit).")):format(math.ceil((15 * 60 - (time() - last)) / 60)))
            return
        end
        if not AHM.ReplicateItems then Status(Tr("Full scan not supported here.")); return end
        scan = { mode = "full", acc = {} }
        UpdateBar()
        local started, my = GetTime(), scan
        AHM.ReplicateItems()
        -- Si le serveur refuse (recharge en cours), aucun résultat n'arrive : abandon après 60 s.
        local function Tick()
            if not scan or scan ~= my or scan.got then return end
            local el = math.floor(GetTime() - started)
            if el >= 120 then
                ns.db.scan[Realm()] = ns.db.scan[Realm()] or {}
                ns.db.scan[Realm()].fullFail = time()
                FinishScan(Tr("Full scan: no answer in 2 min (server busy or cooldown). Click Scan again: it scans your professions and their market depth."))
                return
            end
            Status((Tr("Full scan: waiting for the server… %d s")):format(el))
            C_Timer.After(1, Tick)
        end
        Tick()
        return
    end
    local _, canAll = CanSendAuctionQuery()
    if not canAll then
        local last = ns.db.scan[Realm()] and ns.db.scan[Realm()].lastFull
        local wait = last and math.max(0, 15 * 60 - (time() - last))
        Status(wait and wait > 0 and (Tr("Full scan available in ~%d min (game limit).")):format(math.ceil(wait / 60))
            or "Full scan unavailable right now (game limit).")
        return
    end
    scan = { mode = "full", acc = {} }
    scan.ours = true
    UpdateBar()
    Status(Tr("Full scan: request sent, the server is preparing the list…"))
    QueryAuctionItems("", nil, nil, 0, false, nil, true, false, nil)
end


-- ------------------------------------------------------------ barre HV
local function BuildBar()
    local host = AuctionHouseFrame or AuctionFrame
    if bar or not host then return end
    bar = CreateFrame("Frame", nil, host)
    bar:SetSize(790, 60)
    bar:SetPoint("BOTTOMLEFT", host, "TOPLEFT", 80, 4)
    bar:SetFrameLevel((host:GetFrameLevel() or 1) + 5)
    T.Surface(bar, C.window, 10, { 1, 1, 1, 0.09 })
    local icon = bar:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ns.MEDIA .. Tr("icon.tga")); icon:SetSize(22, 22); icon:SetPoint("TOPLEFT", 10, -8)
    bar.scan = T.Button(bar, Tr("Scan"), 96, 26, function() P.Scan() end)
    bar.scan:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    bar.scan.tooltip = Tr("Scans the whole auction house (prices of everything + Market tab). The game allows it every 15 minutes: in between, it scans only your professions' reagents and crafts.")
    -- Ligne d'état sous les boutons : ce qui vient de se passer, ou ce que l'addon prépare.
    bar.status = T.Text(bar, 11, { color = C.muted })
    bar.status:SetPoint("BOTTOMLEFT", 40, 8)
    bar.status:SetPoint("RIGHT", -10, 0)
    bar.status:SetWordWrap(false)
    local n = 0
    for _ in pairs(DB()) do n = n + 1 end
    local last = ns.db.scan[Realm()] and ns.db.scan[Realm()].lastFull
    local txt = (Tr("%d prices known%s")):format(n, last and ("  ·  full scan " .. P.Ago(time() - last)) or "")
    -- Le marché a besoin d'un scan complet à chaque session : on le rappelle.
    if not last or time() - last > 2 * 3600 then txt = txt .. Tr("  ·  |cffe0a83dclick Scan (Market tab needs one per session)|r") end
    bar.status:SetText(txt)
    UpdateBar()
    ns.Fire("AH_BAR_READY", bar)
end

-- ------------------------------------------------------------ événements
local ev = CreateFrame("Frame")
for _, e in ipairs({ "MERCHANT_SHOW", "MERCHANT_UPDATE", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
    "AUCTION_ITEM_LIST_UPDATE", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN",
    "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "REPLICATE_ITEM_LIST_UPDATE",
    "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
local debounce = 0
ev:SetScript("OnEvent", function(_, event, ...)
    if not ns.db then return end
    if event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
        LearnMerchant()
    elseif event == "AUCTION_HOUSE_SHOW" then
        C_Timer.After(0, BuildBar)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        if scan then FinishScan(Tr("AH closed, scan interrupted.")) end
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        local addon = ...
        if addon == ns.name and scan and scan.mode == "items" then
            scan.manual = true
            scan.awaiting = false
            UpdateBar()
            Status(Tr("The game requires one click per search: click Continue."))
        end
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        ModernOnBrowse()
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        OnCommodityResults(...)
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        OnListItemResults(...)
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        if scan and scan.mode == "full" then
            scan.got = true
            debounce = debounce + 1
            local my = debounce
            C_Timer.After(2, function() if my == debounce and scan and scan.mode == "full" then ModernProcessFull() end end)
        end
    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        if scan and scan.mode == "full" then
            debounce = debounce + 1
            local my = debounce
            C_Timer.After(2, function() if my == debounce and scan and scan.mode == "full" then ProcessFull() end end)
        elseif scan and scan.mode == "items" and scan.awaiting then
            debounce = debounce + 1
            local my = debounce
            C_Timer.After(0.3, function()
                if my == debounce and scan and scan.mode == "items" and scan.awaiting then OnItemsPage() end
            end)
        else
            -- Recherche faite à la main (ou par un autre addon) : on note les prix vus.
            local batch = GetNumAuctionItems("list")
            if batch and batch > 0 and batch <= 50 then
                local acc = {}
                for i = 1, batch do
                    local name, count, buyout, id = ReadListing(i)
                    Accumulate(acc, name, count, buyout, id)
                end
                for id, a in pairs(acc) do P.Record(id, a.low, nil, false) end
            end
        end
    end
end)
