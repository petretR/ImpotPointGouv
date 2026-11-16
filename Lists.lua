-- ImpotPointGouv : listes d'objets à surveiller (raid, pré-BiS, montée de métier, recharges, listes perso).
-- * Les listes sont construites à partir de Data.lua ; les composants des recettes sont demandés au jeu
--   (GetRecipeSchematic), sinon tirés des recettes connues de vos persos, sinon de la table de secours.
-- * Pour chaque objet : prix habituel, bas/haut, volatilité, ventes estimées, et un verdict
--   (acheter / vendre / farmer). L'achat ne prend que les unités sous le seuil, vérifié au prix en direct.
local _, ns = ...
local Tr = ns.L
local P = ns.Prices
local LS = {}
ns.Lists = LS

LS.PROF_NAME = { alch = "Alchemy", bs = "Blacksmithing", ench = "Enchanting", eng = "Engineering",
    lw = "Leatherworking", tail = "Tailoring", cook = "Cooking", fa = "First Aid" }
LS.ROLES = { { "tank", "Tank" }, { "melee", "Melee" }, { "ranged", "Ranged" }, { "caster", "Caster" }, { "heal", "Healer" } }
local ALL_ROLES = { tank = true, melee = true, ranged = true, caster = true, heal = true }

local function Data() return ns.Data or {} end
local function RDB() ns.db.reagents = ns.db.reagents or {}; return ns.db.reagents end

local function Instant(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f or not id then return nil end
    local ok, _, _, _, equipLoc, icon, classID, subID = pcall(f, id)
    if ok then return classID, subID, icon, equipLoc end
end
LS.Instant = Instant

-- ------------------------------------------------------------ composants des recettes
local function FromSchematic(spellID)
    if not spellID or not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeSchematic then return nil end
    local ok, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, spellID, false)
    if not ok or type(sch) ~= "table" or not sch.reagentSlotSchematics then return nil end
    local out = {}
    local basicType = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
    for _, slot in ipairs(sch.reagentSlotSchematics) do
        local r = slot.reagents and slot.reagents[1]
        if r and r.itemID and (not basicType or slot.reagentType == nil or slot.reagentType == basicType) then
            out[#out + 1] = { r.itemID, slot.quantityRequired or 1 }
        end
    end
    return #out > 0 and out or nil
end

-- Nom d'objet -> id, à partir de tout ce que l'addon connaît (noms dans la langue du jeu).
local nameIndex
local function NameIndex()
    if nameIndex then return nameIndex end
    nameIndex = {}
    local function Put(id)
        local n = id and ns.GetItemInfo(id)
        if n then nameIndex[n] = id end
    end
    for id, n in pairs(ns.db.items or {}) do nameIndex[n] = id end
    local D = Data()
    for id in pairs(D.items or {}) do Put(id) end
    for _, r in pairs(D.spellReagents or {}) do for _, rg in ipairs(r) do Put(rg[1]) end end
    for _, r in pairs(D.reagents or {}) do for _, rg in ipairs(r) do Put(rg[1]) end end
    for _, rows in pairs(D.level or {}) do for _, row in ipairs(rows) do Put(row[3]) end end
    return nameIndex
end

-- Secours : l'infobulle de l'objet recette (patron, formule…) affiche "Composants : X (2), Y".
local function FromRecipeTooltip(rec)
    if not rec or not C_TooltipInfo or not C_TooltipInfo.GetItemByID then return nil end
    local ok, data = pcall(C_TooltipInfo.GetItemByID, rec)
    if not ok or type(data) ~= "table" or not data.lines then
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, rec) end
        return nil
    end
    local head = SPELL_REAGENTS and SPELL_REAGENTS:gsub("%%s", ""):gsub("[:：]%s*$", ""):gsub("%s+$", "") or nil
    for _, line in ipairs(data.lines) do
        local t = line.leftText and line.leftText:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        local list = t and ((head and head ~= "" and t:match("^" .. head:gsub("%p", "%%%0") .. "%s*[:：]%s*(.+)$"))
            or t:match("^Reagents%s*:%s*(.+)$") or t:match("^Composants%s*:%s*(.+)$"))
        if list then
            local out, idx, miss = {}, NameIndex(), 0
            for part in (list .. ","):gmatch("%s*(.-)%s*,") do
                local name, n = part:match("^(.-)%s*%((%d+)%)$")
                name = name or part
                local id = idx[name]
                if id then out[#out + 1] = { id, tonumber(n) or 1 } elseif name ~= "" then miss = miss + 1 end
            end
            if #out > 0 and miss == 0 then return out end
            return nil
        end
    end
end

-- Demande au jeu les composants de toutes les recettes des listes. Renvoie trouvés, total.
function LS.ResolveReagents()
    local db, D = RDB(), Data()
    local found, total = 0, 0
    nameIndex = nil
    local function Try(spell, rec)
        if not spell then return end
        total = total + 1
        if db[spell] or (D.spellReagents and D.spellReagents[spell]) then found = found + 1; return end
        local r = FromSchematic(spell) or FromRecipeTooltip(rec)
        if r then db[spell] = r; found = found + 1 end
    end
    for _, it in pairs(D.items or {}) do Try(it.s, it.rec) end
    for spell, e in pairs(D.ench or {}) do Try(spell, e.rec) end
    for _, cd in ipairs(D.cooldowns or {}) do Try(cd.s) end
    LS.resolved = { found = found, total = total, t = time() }
    LS.dirty = true
    return found, total
end

-- Produit -> composants, d'après les recettes que vos personnages connaissent (fenêtre de métier ouverte).
local productIndex
local function ProductIndex()
    if productIndex then return productIndex end
    productIndex = {}
    for _, recipes in pairs(ns.db.recipes or {}) do
        for _, r in pairs(recipes) do
            if r.p and r.r and #r.r > 0 then productIndex[r.p] = r.r end
        end
    end
    return productIndex
end

local function IsVendor(id) return P.IsVendorItem and P.IsVendorItem(id) end

-- Composants d'un objet fabriqué (sans les objets vendus par les marchands), ou nil.
function LS.ReagentsOf(id)
    local D = Data()
    local it = D.items and D.items[id]
    local r = (it and it.s and (RDB()[it.s] or (D.spellReagents and D.spellReagents[it.s]))) or ProductIndex()[id] or (D.reagents and D.reagents[id])
    if not r then return nil end
    local out = {}
    for _, rg in ipairs(r) do
        if rg[1] and not IsVendor(rg[1]) then out[#out + 1] = rg end
    end
    return out
end

-- ------------------------------------------------------------ construction des listes
local function RolesOf(sp)
    local out = {}
    if not sp then return ALL_ROLES end
    local specs = Data().specs or {}
    for idx in sp:gmatch("%d+") do
        local s = specs[tonumber(idx)]
        if s then out[s[3]] = true end
    end
    return next(out) and out or ALL_ROLES
end

local function NewList(key, title, info)
    return { key = key, title = title, info = info, entries = {}, byId = {} }
end

local function Add(list, id, kind, roles, qty, note)
    if not id then return end
    local e = list.byId[id]
    if not e then
        e = { id = id, kind = kind, roles = {}, uses = 0, qty = 0 }
        list.byId[id] = e
        list.entries[#list.entries + 1] = e
    elseif kind == "product" then
        e.kind = "product"
    end
    e.uses = e.uses + 1
    for r in pairs(roles or ALL_ROLES) do e.roles[r] = true end
    if qty then e.qty = e.qty + qty end
    if note and not e.note then e.note = note end
end

-- Composants (et composants des intermédiaires, 2 niveaux) d'un produit.
local function AddMats(list, id, roles, depth, mult)
    local rg = LS.ReagentsOf(id)
    if not rg then return false end
    for _, r in ipairs(rg) do
        Add(list, r[1], "mat", roles, (mult or 1) * (r[2] or 1))
        if (depth or 0) < 2 then AddMats(list, r[1], roles, (depth or 0) + 1, (mult or 1) * (r[2] or 1)) end
    end
    return true
end

local function ArmorBucket(id)
    local classID, subID, _, equipLoc = Instant(id)
    if classID == 2 or equipLoc == "INVTYPE_SHIELD" or equipLoc == "INVTYPE_HOLDABLE" then return "weapon" end
    if classID == 4 and equipLoc ~= "INVTYPE_CLOAK" then
        if subID == 1 then return "cloth" elseif subID == 2 then return "leather"
        elseif subID == 3 then return "mail" elseif subID == 4 then return "plate" end
    end
    return "other"
end

function LS.Build()
    local D = Data()
    productIndex = nil
    local groups = {}

    -- Raid : consommables, enchantements, recharges
    local consum = NewList("consum", Tr("Consumables"), "Flasks, elixirs, potions, food, weapon oils and stones, armor kits, and what they're made of.")
    local seen = {}
    local function IsGear(id, it)
        if not it.g then return false end
        local classID = Instant(id)
        return classID ~= 0 and classID ~= 7 and classID ~= 8
    end
    LS._IsGear = IsGear
    for id, it in pairs(D.items or {}) do
        if not IsGear(id, it) and not it.low then
            seen[id] = true
            local roles = RolesOf(it.sp)
            Add(consum, id, "product", roles)
            AddMats(consum, id, roles)
        end
    end
    for _, id in ipairs(D.raidConsumables or {}) do
        if not seen[id] then Add(consum, id, "product", ALL_ROLES); AddMats(consum, id, ALL_ROLES) end
    end

    local ench = NewList("enchant", Tr("Enchanting"), "Materials of the enchants used by each spec.")
    local nRes = 0
    for spell, e in pairs(D.ench or {}) do
        if not e.low then
            local r = RDB()[spell] or (D.spellReagents and D.spellReagents[spell])
            if r then
                nRes = nRes + 1
                local roles = RolesOf(e.sp)
                for _, rg in ipairs(r) do
                    if not IsVendor(rg[1]) then
                        Add(ench, rg[1], "mat", roles, rg[2])
                        AddMats(ench, rg[1], roles, 1, rg[2])
                    end
                end
            end
        end
    end
    -- Enchantements dont le jeu n'a pas encore donné les composants : matériaux de raid habituels.
    if nRes == 0 then
        for _, id in ipairs(D.enchantMats or {}) do Add(ench, id, "mat", ALL_ROLES) end
        ench.info = ench.info .. Tr(" (Showing the usual raid enchanting materials until the game provides the exact recipes.)")
    end

    local cds = NewList("cd", Tr("Cooldowns"), "Daily or multi-day crafts: limited supply, steadier margins.")
    for _, cd in ipairs(D.cooldowns or {}) do
        Add(cds, cd.out, "product", ALL_ROLES, nil, cd.n)
        for _, rg in ipairs(cd.r or {}) do Add(cds, rg[1], "mat", ALL_ROLES, rg[2]) end
        if cd.item then Add(cds, cd.item, "tool", ALL_ROLES, nil, "Tool") end
    end
    groups[#groups + 1] = { key = "raid", title = Tr("CONSUMABLES & ENCHANTS"), lists = { consum, ench } }
    groups[#groups + 1] = { key = "cd", title = Tr("DAILY COOLDOWNS"), lists = { cds } }

    -- Pré-BiS craftés par type d'armure
    local buckets = {
        cloth = NewList("pb_cloth", Tr("Cloth"), "Crafted pre-raid gear (cloth) and its materials."),
        leather = NewList("pb_leather", Tr("Leather"), "Crafted pre-raid gear (leather) and its materials."),
        mail = NewList("pb_mail", Tr("Mail"), "Crafted pre-raid gear (mail) and its materials."),
        plate = NewList("pb_plate", Tr("Plate"), "Crafted pre-raid gear (plate) and its materials."),
        weapon = NewList("pb_weapon", Tr("Weapons & shields"), "Crafted pre-raid weapons, shields and off-hands."),
        other = NewList("pb_other", Tr("Cloaks, trinkets, relics"), "Crafted cloaks, trinkets, relics and engineering items."),
    }
    for id, it in pairs(D.items or {}) do
        if IsGear(id, it) then
            local b = buckets[ArmorBucket(id)]
            local roles = RolesOf(it.sp)
            Add(b, id, "product", roles)
            AddMats(b, id, roles)
        end
    end
    groups[#groups + 1] = { key = "prebis", title = Tr("PRE-BIS CRAFTS"),
        lists = { buckets.cloth, buckets.leather, buckets.mail, buckets.plate, buckets.weapon, buckets.other } }

    -- Montée de métier 1-300 (quantités)
    local lv = {}
    for _, prof in ipairs({ "alch", "bs", "ench", "eng", "lw", "tail", "cook", "fa" }) do
        local rows = D.level and D.level[prof]
        if rows then
            local pn = Tr(LS.PROF_NAME[prof])
            local l = NewList("lv_" .. prof, pn .. " 1-300", Tr("Shopping list to level %s to 300 (vendor items left out)."):format(pn))
            l.leveling = true
            for _, row in ipairs(rows) do
                Add(l, row[3], "mat", ALL_ROLES, row[2])
                local e = l.byId[row[3]]
                e.range = e.range and (e.range:find(row[1], 1, true) and e.range or (e.range .. ", " .. row[1])) or row[1]
            end
            lv[#lv + 1] = l
        end
    end
    groups[#groups + 1] = { key = "level", title = Tr("PROFESSION LEVELING"), lists = lv }

    -- Listes perso
    local mine = {}
    for i, cl in ipairs(ns.db.lists or {}) do
        local l = NewList("my_" .. i, cl.name, "Your list. Right-click an item in any list to add it here.")
        l.custom = i
        for _, id in ipairs(cl.ids or {}) do Add(l, id, "mat", ALL_ROLES) end
        mine[#mine + 1] = l
    end
    groups[#groups + 1] = { key = "mine", title = Tr("MY LISTS"), lists = mine, custom = true }

    LS.groups = groups
    LS.byKey = {}
    LS.watch = {}
    for _, g in ipairs(groups) do
        for _, l in ipairs(g.lists) do
            LS.byKey[l.key] = l
            for _, e in ipairs(l.entries) do LS.watch[e.id] = true end
        end
    end
    LS.dirty = false
    return groups
end

-- Objet présent dans une liste : son historique de prix est gardé.
function LS.IsWatched(id)
    if not LS.watch or LS.dirty then LS.Build() end
    return LS.watch[id] or false
end

function LS.Groups()
    if not LS.groups or LS.dirty then LS.Build() end
    return LS.groups
end
function LS.Get(key) LS.Groups(); return LS.byKey[key] end

-- ------------------------------------------------------------ listes perso
function LS.NewCustom(name)
    ns.db.lists = ns.db.lists or {}
    ns.db.lists[#ns.db.lists + 1] = { name = name or ("My list " .. (#ns.db.lists + 1)), ids = {} }
    LS.dirty = true
    return #ns.db.lists
end
function LS.AddToCustom(i, id)
    local cl = ns.db.lists and ns.db.lists[i]
    if not cl then return end
    for _, x in ipairs(cl.ids) do if x == id then return end end
    cl.ids[#cl.ids + 1] = id
    LS.dirty = true
end
function LS.RemoveFromCustom(i, id)
    local cl = ns.db.lists and ns.db.lists[i]
    if not cl then return end
    for k, x in ipairs(cl.ids) do if x == id then table.remove(cl.ids, k); break end end
    LS.dirty = true
end
function LS.DeleteCustom(i)
    if ns.db.lists and ns.db.lists[i] then table.remove(ns.db.lists, i); LS.dirty = true end
end

-- ------------------------------------------------------------ verdicts
-- Seuil d'achat : sous le bas habituel (20 %) ET 15 % sous la médiane.
function LS.BuyMax(st)
    if not st or not st.med or not st.low then return nil end
    return math.min(st.low, math.floor(st.med * 0.85))
end

function LS.Have(id)
    local I = ns.Inventory
    return I and I.Stock and I.Stock(id) or ns.GetItemCount(id)
end

-- "buy" | "sell" | "farm" | nil, plus un court motif.
function LS.Verdict(e, st)
    if not st or not st.med then
        if e.kind == "product" or e.uses >= 2 then return "farm", "never seen at the AH" end
        return nil, "not scanned yet"
    end
    local cur = st.cur
    if not cur or (st.qty or 0) == 0 then return "farm", "none listed right now" end
    local enough = (st.n or 0) >= 4
    local max = LS.BuyMax(st)
    if enough and max and cur <= max then return "buy", "well under its usual price" end
    if enough and st.high and cur >= st.high and cur >= st.med * 1.1 and LS.Have(e.id) > 0 then
        return "sell", "above its usual price and you have some"
    end
    if (st.cv or 0) > 0.35 and enough then return nil, "unstable price" end
    return nil
end

function LS.Row(e)
    local st = P.Stats(e.id)
    local v, why = LS.Verdict(e, st)
    return { e = e, id = e.id, st = st, verdict = v, why = why }
end

function LS.Deals(list)
    local n = 0
    for _, e in ipairs(list.entries) do
        local st = P.Stats(e.id)
        if LS.Verdict(e, st) == "buy" then n = n + 1 end
    end
    return n
end

-- Coût d'une liste de montée de métier : au prix actuel et au prix habituel.
function LS.LevelCost(list)
    local now, usual, missing = 0, 0, 0
    for _, e in ipairs(list.entries) do
        local st = P.Stats(e.id)
        local q = e.qty or 0
        if st and st.cur then now = now + st.cur * q else missing = missing + 1 end
        if st and st.med then usual = usual + st.med * q end
    end
    return now, usual, missing
end

function LS.IdsOf(list)
    local ids = {}
    for _, e in ipairs(list.entries) do if e.kind ~= "tool" then ids[#ids + 1] = e.id end end
    return ids
end

-- ------------------------------------------------------------ Auctionator (lecture seule)
function LS.ExportAuctionator(list)
    local A = Auctionator and Auctionator.API and Auctionator.API.v1
    if not A or not A.CreateShoppingList then return false, "Auctionator not found." end
    local terms = {}
    for _, e in ipairs(list.entries) do
        local name = ns.GetItemInfo(e.id) or ns.db.items[e.id]
        if name then terms[#terms + 1] = '"' .. name .. '"' end
    end
    local ok, err = pcall(A.CreateShoppingList, "ImpotPointGouv", "IPG - " .. list.title, terms)
    if not ok then return false, tostring(err) end
    return true, #terms
end

-- ------------------------------------------------------------ achat des affaires (empilables)
-- 1er clic : lit le carnet en direct et demande le prix des unités sous le seuil ; 2e clic : confirme.
local buy
function LS.Buying() return buy end
local function BuyMsg(t) LS.msg, LS.msgT = t, GetTime(); if P.Status then P.Status(t) end; ns.Fire("LISTS_CHANGED") end

local function AHOpen() return AuctionHouseFrame and AuctionHouseFrame:IsShown() end

function LS.Buy(id)
    local AH = C_AuctionHouse
    if not AH or not AHOpen() then BuyMsg(Tr("Open the auction house to buy.")); return end
    if buy and buy.id == id and buy.stage == "confirm" then
        buy.stage = "wait"
        BuyMsg((Tr("Buying %d× %s…")):format(buy.qty, P.Name(id)))
        AH.ConfirmCommoditiesPurchase(id, buy.qty)
        return
    end
    if buy then return end
    if not ns.IsCommodity(id) then BuyMsg(Tr("Only stackable items can be bought from here: use the AH for gear.")); return end
    local st = P.Stats(id)
    local max = LS.BuyMax(st)
    if not max then BuyMsg(Tr("Not enough price history yet: scan this list a few times first.")); return end
    buy = { id = id, max = max, stage = "book" }
    BuyMsg((Tr("Checking live listings of %s under %s…")):format(P.Name(id), ns.FormatMoney(max, { iconSize = 10 })))
    AH.SendSearchQuery(AH.MakeItemKey(id), { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }, false)
    local my = buy
    C_Timer.After(5, function() if buy == my and buy.stage == "book" then buy = nil; BuyMsg(Tr("No answer from the AH, click again.")) end end)
end

local function EndBuy(msg)
    if buy and buy.stage == "confirm" and C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then
        pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    end
    buy = nil
    if msg then BuyMsg(msg) end
end
LS.CancelBuy = function() EndBuy(Tr("Purchase cancelled.")) end

local bev = CreateFrame("Frame")
for _, e in ipairs({ "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
    "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_CLOSED" }) do pcall(bev.RegisterEvent, bev, e) end
bev:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "AUCTION_HOUSE_CLOSED" then if buy then EndBuy() end; return end
    if not buy then return end
    local AH = C_AuctionHouse
    if event == "COMMODITY_SEARCH_RESULTS_UPDATED" and buy.stage == "book" and a1 == buy.id then
        local units, cost = 0, 0
        for k = 1, (AH.GetNumCommoditySearchResults(buy.id) or 0) do
            local r = AH.GetCommoditySearchResultInfo(buy.id, k)
            if r and r.unitPrice and r.quantity and r.unitPrice <= buy.max then
                local mine = r.numOwnerItems or 0
                local q = r.quantity - mine
                if q > 0 then units = units + q; cost = cost + q * r.unitPrice end
            end
        end
        -- Garde-fou budget : au plus 25 % de l'or du personnage par achat.
        local budget = math.floor(GetMoney() * 0.25)
        while units > 0 and cost > budget do
            local avg = cost / units
            local cut = math.max(1, math.ceil((cost - budget) / avg))
            units = units - cut; cost = math.floor(avg * units)
        end
        if units <= 0 then EndBuy((Tr("%s: nothing left under %s (or over your budget).")):format(P.Name(buy.id), ns.FormatMoney(buy.max, { iconSize = 10 }))); return end
        buy.qty, buy.stage = units, "price"
        AH.StartCommoditiesPurchase(buy.id, units)
    elseif event == "COMMODITY_PRICE_UPDATED" and buy.stage == "price" then
        local total = a2
        if not total or total / buy.qty > buy.max then
            EndBuy((Tr("%s: the price moved above your limit, nothing bought.")):format(P.Name(buy.id)))
            return
        end
        buy.stage, buy.total = "confirm", total
        BuyMsg((Tr("Buy %d× %s for %s (%s each, limit %s)? Click Confirm.")):format(buy.qty, P.Name(buy.id),
            ns.FormatMoney(total, { iconSize = 10 }), ns.FormatMoney(math.floor(total / buy.qty), { iconSize = 10 }),
            ns.FormatMoney(buy.max, { iconSize = 10 })))
    elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
        EndBuy(Tr("Not available anymore."))
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" and buy.stage == "wait" then
        local msg = (Tr("Bought %d× %s for %s.")):format(buy.qty, P.Name(buy.id), ns.FormatMoney(buy.total or 0, { iconSize = 10 }))
        buy = nil
        BuyMsg(msg)
    elseif event == "COMMODITY_PURCHASE_FAILED" and buy.stage == "wait" then
        EndBuy(Tr("Purchase failed (price changed or not enough gold)."))
    end
end)

-- ------------------------------------------------------------ recharges
local function CDDB()
    ns.db.cds = ns.db.cds or {}
    local key = ns.Ledger and ns.Ledger.CharKey()
    if not key then return nil end
    ns.db.cds[key] = ns.db.cds[key] or {}
    return ns.db.cds[key]
end

-- Met à jour l'état des recharges du perso connecté : { [nom] = readyAt }.
function LS.UpdateCooldowns()
    local db = CDDB()
    if not db then return end
    for _, cd in ipairs(Data().cooldowns or {}) do
        local known, start, dur
        if cd.s and IsPlayerSpell and IsPlayerSpell(cd.s) then
            known = true
            local f = (C_Spell and C_Spell.GetSpellCooldown) and function(s)
                local i = C_Spell.GetSpellCooldown(s); return i and i.startTime, i and i.duration end or GetSpellCooldown
            start, dur = f(cd.s)
        elseif cd.item and ns.GetItemCount(cd.item) > 0 then
            known = true
            local f = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
            if f then start, dur = f(cd.item) end
        end
        if known then
            local left = (start and dur and start > 0 and dur > 1.5) and (start + dur - GetTime()) or 0
            db[cd.n] = time() + math.max(0, math.floor(left))
        end
    end
end

-- Gain estimé d'une recharge : valeur HV du produit (après commission) − composants (prix habituel).
function LS.CooldownGain(cd)
    local out = P.Stats(cd.out)
    local value = out and (out.med or out.cur)
    if not value then return nil end
    local cost = 0
    for _, rg in ipairs(cd.r or {}) do
        local st = P.Stats(rg[1])
        local p = st and (st.med or st.cur)
        if not p then return nil end
        cost = cost + p * (rg[2] or 1)
    end
    return math.floor(value * 0.95) - cost
end

-- Recharges de tous les persos : { {char, cd, readyAt, gain}, ... } triées (prêtes d'abord).
function LS.CooldownBoard()
    local out = {}
    local byName = {}
    for _, cd in ipairs(Data().cooldowns or {}) do byName[cd.n] = cd end
    for key, list in pairs(ns.db.cds or {}) do
        local ch = ns.db.chars[key]
        for name, readyAt in pairs(list) do
            local cd = byName[name]
            if cd then out[#out + 1] = { char = ch and ch.name or "?", cd = cd, readyAt = readyAt, gain = LS.CooldownGain(cd) } end
        end
    end
    table.sort(out, function(a, b)
        local ra, rb = a.readyAt <= time(), b.readyAt <= time()
        if ra ~= rb then return ra end
        return (a.gain or -1e9) > (b.gain or -1e9)
    end)
    return out
end

-- Rappel à la connexion : recharges prêtes sur ce perso (la plus rentable des transmutations en tête).
local function Remind()
    LS.UpdateCooldowns()
    local db = CDDB()
    if not db then return end
    local ready, bestT = {}, nil
    for _, cd in ipairs(Data().cooldowns or {}) do
        local at = db[cd.n]
        if at and at <= time() then
            local g = LS.CooldownGain(cd)
            if cd.n:find("^Transmute") then
                if not bestT or (g or -1e9) > (bestT.g or -1e9) then bestT = { cd = cd, g = g } end
            else
                ready[#ready + 1] = cd.n .. (g and (" (" .. ns.FormatMoney(g, { iconSize = 10, sign = true }) .. ")") or "")
            end
        end
    end
    if bestT then
        table.insert(ready, 1, (Tr("Transmute — best today: %s%s")):format(bestT.cd.n:gsub("^Transmute: ", ""),
            bestT.g and (" (" .. ns.FormatMoney(bestT.g, { iconSize = 10, sign = true }) .. ")") or ""))
    end
    if #ready > 0 then ns.Print(Tr("|cffe0a83dcooldowns ready:|r ") .. table.concat(ready, "  ·  ")) end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "TRADE_SKILL_SHOW", "SPELL_UPDATE_COOLDOWN", "TRADE_SKILL_LIST_UPDATE" }) do
    pcall(ev.RegisterEvent, ev, e)
end
local started, cdPend = false, false
ev:SetScript("OnEvent", function(_, event)
    if not ns.db then return end
    if event == "PLAYER_ENTERING_WORLD" then
        if started then return end
        started = true
        C_Timer.After(6, function()
            LS.ResolveReagents()
            Remind()
        end)
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" then
        -- Nouvelles recettes connues : on refait l'index et on retente les composants manquants.
        productIndex = nil
        C_Timer.After(1, function() LS.ResolveReagents(); LS.UpdateCooldowns() end)
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        if cdPend then return end
        cdPend = true
        C_Timer.After(2, function() cdPend = false; LS.UpdateCooldowns() end)
    end
end)

-- Diagnostic (/ipg lists) : combien de recettes le jeu a pu détailler.
function LS.Diag()
    local found, total = LS.ResolveReagents()
    LS.Build()
    local n = 0
    for _, g in ipairs(LS.groups) do for _, l in ipairs(g.lists) do n = n + #l.entries end end
    ns.Print((Tr("lists: recipe materials known for %d / %d recipes · %d items across all lists.")):format(found, total, n))
    -- Recette propre à Forever (Living Crown) : le jeu donne-t-il ses composants ?
    local it = Data().items and Data().items[252561]
    local function Fmt(r)
        local parts = {}
        for _, rg in ipairs(r or {}) do parts[#parts + 1] = rg[2] .. "× " .. P.Name(rg[1]) end
        return table.concat(parts, ", ")
    end
    local a = it and FromSchematic(it.s)
    local b = it and FromRecipeTooltip(it.rec)
    ns.Print(Tr("test, Living Crown — recipe data: ") .. (a and Fmt(a) or Tr("not available")))
    ns.Print(Tr("test, Living Crown — pattern tooltip: ") .. (b and Fmt(b) or Tr("not available")))
end
