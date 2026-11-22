-- ImpotPointGouv : conseiller de craft, ancré à droite de la fenêtre de métier.
local _, ns = ...
local Tr = ns.L
local T, P = ns.Theme, ns.Prices
local C = T.C
local CR = {}
ns.Craft = CR

local AH_CUT = 0.05
local PW, PH = 440, 600
local ROW_H = 28
local VIS = 7
local DE_ICON = "|TInterface\\Icons\\INV_Enchant_Disenchant:13:13:0:0:64:64:5:59:5:59|t "
CR.DE_ICON = DE_ICON

-- ------------------------------------------------------------ accès aux API de métier
-- Couture, etc. : API TradeSkill. Enchantement (Classic) : API Craft. On gère les deux.
local Trade = {
    key = "trade",
    Frame = function() return TradeSkillFrame end,
    Available = function() return GetNumTradeSkills ~= nil end,
    Num = function() return GetNumTradeSkills() or 0 end,
    Info = function(i) local name, kind, avail = GetTradeSkillInfo(i); return name, kind, avail end,
    Link = function(i) return GetTradeSkillItemLink and GetTradeSkillItemLink(i) end,
    Made = function(i) if GetTradeSkillNumMade then return GetTradeSkillNumMade(i) end return 1, 1 end,
    NumReagents = function(i) return GetTradeSkillNumReagents(i) or 0 end,
    Reagent = function(i, r) return GetTradeSkillReagentInfo(i, r) end,
    ReagentLink = function(i, r) return GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(i, r) end,
    Icon = function(i) return GetTradeSkillIcon and GetTradeSkillIcon(i) end,
    Line = function() return GetTradeSkillLine and GetTradeSkillLine() end,
    Selected = function() return GetTradeSkillSelectionIndex and GetTradeSkillSelectionIndex() end,
    Select = function(i)
        if TradeSkillFrame_SetSelection then TradeSkillFrame_SetSelection(i) end
        if TradeSkillFrame_Update then TradeSkillFrame_Update() end
    end,
}
local Craft = {
    key = "craft",
    Frame = function() return CraftFrame end,
    Available = function() return GetNumCrafts ~= nil end,
    Num = function() return GetNumCrafts() or 0 end,
    Info = function(i) local name, _, kind, avail = GetCraftInfo(i); return name, kind, avail end,
    Link = function(i) return GetCraftItemLink and GetCraftItemLink(i) end,
    Made = function() return 1, 1 end,
    NumReagents = function(i) return GetCraftNumReagents(i) or 0 end,
    Reagent = function(i, r) return GetCraftReagentInfo(i, r) end,
    ReagentLink = function(i, r) return GetCraftReagentItemLink and GetCraftReagentItemLink(i, r) end,
    Icon = function(i) return GetCraftIcon and GetCraftIcon(i) end,
    Line = function() return GetCraftDisplaySkillLine and GetCraftDisplaySkillLine() end,
    Selected = function() return GetCraftSelectionIndex and GetCraftSelectionIndex() end,
    Select = function(i)
        if CraftFrame_SetSelection then CraftFrame_SetSelection(i) end
        if CraftFrame_Update then CraftFrame_Update() end
    end,
}

-- Nouvelle API (C_TradeSkillUI), au cas où la fenêtre de Forever l'utilise.
local DIFF_ENUM = { [0] = "optimal", [1] = "medium", [2] = "easy", [3] = "trivial" }
local Modern = {
    key = "modern",
    Frame = function() return (ProfessionsFrame and ProfessionsFrame:IsShown() and ProfessionsFrame) or TradeSkillFrame end,
    Available = function() return C_TradeSkillUI ~= nil and C_TradeSkillUI.GetAllRecipeIDs ~= nil end,
    Line = function()
        local info = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
        if info and info.professionName then return info.professionName end
        if C_TradeSkillUI.GetTradeSkillLine then return (C_TradeSkillUI.GetTradeSkillLine()) end
    end,
    Selected = function() return nil end,
    Select = function() end,
    Read = function()
        local out = {}
        local basic = (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 1
        for _, rid in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
            local info = C_TradeSkillUI.GetRecipeInfo(rid)
            -- Recettes pas encore apprises : on garde au moins le nombre produit par craft.
            if info and info.learned == false and ns.Lists and ns.Lists.NoteMade and C_TradeSkillUI.GetRecipeSchematic then
                local ok, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, rid, false)
                if ok then ns.Lists.NoteMade(sch) end
            end
            if info and info.name and info.learned ~= false then
                local rec = { index = rid, name = info.name, icon = info.icon, made = 1, reagents = {},
                    kind = DIFF_ENUM[info.relativeDifficulty] }
                local sch = C_TradeSkillUI.GetRecipeSchematic and C_TradeSkillUI.GetRecipeSchematic(rid, false)
                if sch then
                    if ns.Lists and ns.Lists.NoteMade then ns.Lists.NoteMade(sch) end
                    rec.pid = sch.outputItemID
                    rec.made = ((sch.quantityMin or 1) + (sch.quantityMax or sch.quantityMin or 1)) / 2
                    for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
                        local r = slot.reagents and slot.reagents[1]
                        if r and r.itemID and (slot.reagentType == nil or slot.reagentType == basic) then
                            rec.reagents[#rec.reagents + 1] = {
                                id = r.itemID, name = (ns.GetItemInfo(r.itemID)) or ns.db.items[r.itemID] or "?",
                                icon = ns.GetItemIcon(r.itemID), n = slot.quantityRequired or 1,
                                have = ns.GetItemCount(r.itemID) or 0,
                            }
                        end
                    end
                end
                rec.enchant = rec.pid == nil
                out[#out + 1] = rec
            end
        end
        return out
    end,
}

local DIFF = {
    optimal = { 1.00, 0.50, 0.25 }, medium = { 1.00, 1.00, 0.00 },
    easy = { 0.25, 0.75, 0.25 }, trivial = { 0.50, 0.50, 0.50 },
}

-- ------------------------------------------------------------ lecture des recettes
local api, recipes, profName = nil, {}, nil

local function StoreRecipe(store, rec)
    if rec.pid then ns.db.items[rec.pid] = ns.db.items[rec.pid] or rec.name end
    local saved = { p = rec.pid, m = rec.made, r = {} }
    for _, rg in ipairs(rec.reagents) do
        if rg.id then
            saved.r[#saved.r + 1] = { rg.id, rg.n }
            if rg.name and rg.name ~= "?" then ns.db.items[rg.id] = rg.name end
        end
    end
    store[rec.name] = saved
end

local function ReadRecipes()
    wipe(recipes)
    if not api or not api.Available() then return end
    profName = api.Line() or "Profession"
    ns.db.profChars = ns.db.profChars or {}
    ns.db.profChars[profName] = ns.db.profChars[profName] or {}
    if UnitGUID("player") then ns.db.profChars[profName][UnitGUID("player")] = true end
    local store = ns.db.recipes[profName] or {}
    ns.db.recipes[profName] = store
    if api.Read then
        for _, rec in ipairs(api.Read()) do
            StoreRecipe(store, rec)
            recipes[#recipes + 1] = rec
        end
        return
    end
    for i = 1, api.Num() do
        local name, kind = api.Info(i)
        if name and kind ~= "header" and kind ~= "subheader" then
            local link = api.Link(i)
            local pid = P.ItemID(link)
            local mn, mx = api.Made(i)
            local rec = {
                index = i, name = name, kind = kind, pid = pid, icon = api.Icon(i),
                made = ((mn or 1) + (mx or mn or 1)) / 2, reagents = {},
                enchant = (pid == nil),
            }
            if pid then ns.db.items[pid] = (link and link:match("%[(.-)%]")) or name end
            local saved = { p = pid, m = rec.made, r = {} }
            for r = 1, api.NumReagents(i) do
                local rname, rtex, rcount, have = api.Reagent(i, r)
                local rid = P.ItemID(api.ReagentLink(i, r))
                if rid and rname then ns.db.items[rid] = rname end
                rec.reagents[#rec.reagents + 1] = { id = rid, name = rname or "?", icon = rtex, n = rcount or 1, have = have or 0 }
                if rid then saved.r[#saved.r + 1] = { rid, rcount or 1 } end
            end
            store[name] = saved
            recipes[#recipes + 1] = rec
        end
    end
end

-- Toutes les recettes connues (tous métiers) qui produisent un objet : pour coûter les intermédiaires.
local function ProducerOf(id)
    for prof, list in pairs(ns.db.recipes) do
        for name, r in pairs(list) do
            if r.p == id then return r, prof, name end
        end
    end
end
CR.ProducerOf = ProducerOf

-- ------------------------------------------------------------ modèle de coût
-- Coût unitaire d'un objet : le moins cher entre marchand, HV et fabrication maison.
local function UnitCost(id, depth)
    if not id then return nil, "unknown" end
    local best, src, est
    local v, vest = P.VendorBuy(id)
    if v then best, src, est = v, "vendor", vest end
    local ah = P.AHValue(id)
    if ah and (not best or ah < best) then best, src, est = ah, "ah", false end
    if (depth or 0) < 2 then
        local prod = ProducerOf(id)
        if prod and prod.r and #prod.r > 0 then
            local total, ok = 0, true
            for _, rg in ipairs(prod.r) do
                local c = UnitCost(rg[1], (depth or 0) + 1)
                if not c then ok = false; break end
                total = total + c * rg[2]
            end
            if ok then
                local c = total / math.max(1, prod.m or 1)
                if not best or c < best then best, src, est = c, "craft", false end
            end
        end
    end
    return best, src or "unknown", est
end
CR.UnitCost = UnitCost

local function SalesOf(name, days)
    local n, since = 0, time() - (days or 7) * 86400
    for i = #ns.db.tx, 1, -1 do
        local tx = ns.db.tx[i]
        if tx.t < since then break end
        if tx.k == "ah_sale" and tx.i == name then n = n + (tx.q or 1) end
    end
    return n
end
CR.SalesOf = SalesOf

-- Nombre de mises en vente (dépôts HV) d'un objet sur la période.
local function PostsOf(name, days)
    local n, since = 0, time() - (days or 14) * 86400
    for i = #ns.db.tx, 1, -1 do
        local tx = ns.db.tx[i]
        if tx.t < since then break end
        if tx.k == "ah_deposit" and tx.i == name then n = n + 1 end
    end
    return n
end
CR.PostsOf = PostsOf

-- Unités mises en vente (une pile de 20 compte pour 20) : base du taux de vente.
local function PostedUnits(name, days)
    local n, since = 0, time() - (days or 14) * 86400
    for i = #ns.db.tx, 1, -1 do
        local tx = ns.db.tx[i]
        if tx.t < since then break end
        if tx.k == "ah_deposit" and tx.i == name then n = n + math.max(1, tx.q or 1) end
    end
    return n
end
CR.PostedUnits = PostedUnits

function CR.Rules()
    ns.db.settings.queue = ns.db.settings.queue or {}
    local q = ns.db.settings.queue
    if q.minProfit == nil then q.minProfit = 10 end        -- cuivre
    if q.minMargin == nil then q.minMargin = 20 end        -- %
    if q.startQty == nil or q.startQty == 3 then q.startQty = 2 end
    if q.minQty == nil then q.minQty = 2 end
    if q.maxQty == nil or not q.adaptive then q.maxQty = math.max(q.maxQty or 0, 200); q.adaptive = true end -- plafond de la cible adaptative
    if q.maxListed == nil or q.maxListed == 500 then q.maxListed = 10000 end -- HV régionale
    if q.unsoldPosts == nil then q.unsoldPosts = 3 end
    if q.ignoreWhiteGear == nil then q.ignoreWhiteGear = true end
    if q.deposit == nil then q.deposit = 100 end           -- dépôt HV par mise en vente (cuivre)
    if q.sellChance == nil then q.sellChance = 50 end      -- % supposé sans historique
    if q.budgetPct == nil then q.budgetPct = 50 end        -- % de l'or du perso que la file peut engager
    if q.vendorCap == nil then q.vendorCap = 40 end        -- crafts pour le marchand : quantité visée par session
    return q
end

-- Dépôt réel d'un objet : moyenne de vos 5 dernières mises en vente (sinon la valeur des règles).
-- Suit automatiquement la durée que vous choisissez si le dépôt en dépend.
function CR.DepositFor(name)
    local sum, n = 0, 0
    for i = #ns.db.tx, 1, -1 do
        local tx = ns.db.tx[i]
        if tx.k == "ah_deposit" and tx.i == name and tx.a < 0 then
            sum, n = sum - tx.a / math.max(1, tx.q or 1), n + 1
            if n >= 5 then break end
        end
    end
    if n > 0 then return sum / n end
    return CR.Rules().deposit
end

-- Valeur nette d'une vente HV : prix − 5 % − dépôts perdus en moyenne (selon l'historique de l'objet).
function CR.AHNet(id, name)
    local ah = P.AHValue(id)
    if not ah then return nil end
    local rules = CR.Rules()
    name = name or ns.db.items[id]
    local chance = rules.sellChance / 100
    local posts, sold = PostedUnits(name, 14), SalesOf(name, 14)
    if posts > 0 then chance = math.max(0.1, math.min(1, sold / posts)) end
    return ah * (1 - AH_CUT) - CR.DepositFor(name) * (1 - chance) / chance
end

function CR.Evaluate(rec)
    local ev = { cost = 0, vendorPart = 0, marketPart = 0, unknown = 0, estimated = false, matsAH = 0, lines = {} }
    for _, rg in ipairs(rec.reagents) do
        local unit, src, est = UnitCost(rg.id)
        local line = { rg = rg, unit = unit, src = src, est = est }
        if unit then
            local total = unit * rg.n
            line.total = total
            ev.cost = ev.cost + total
            if src == "vendor" then ev.vendorPart = ev.vendorPart + total else ev.marketPart = ev.marketPart + total end
            if est then ev.estimated = true end
        else
            ev.unknown = ev.unknown + 1
        end
        -- Valeur des compos si on les revendait au lieu de crafter (hors compos marchand).
        if rg.id and not P.IsVendorItem(rg.id) then
            local ah = P.AHValue(rg.id)
            local vs = P.VendorSell(rg.id)
            local best = math.max(ah and ah * (1 - AH_CUT) or 0, vs or 0)
            ev.matsAH = ev.matsAH + best * rg.n
        end
        ev.lines[#ev.lines + 1] = line
    end
    if rec.enchant then
        ev.verdict, ev.vcolor = "Enchant", C.muted
        ev.note = "No item to sell: this is the cost to charge the customer."
        return ev
    end
    local ahv = P.AHValue(rec.pid)
    local vs = P.VendorSell(rec.pid)
    -- Équipement blanc (ou gris) : ne se vend pas à l'HV, on ne garde que le prix marchand.
    -- Les sacs, kits d'armure et compos (non équipables) gardent leur valeur HV.
    local _, _, quality, _, _, _, _, _, equipLoc, _, _, _, _, bindType = ns.GetItemInfo(rec.pid)
    if bindType == 1 then
        -- Lié quand ramassé : invendable à l'HV, il reste le marchand ou le désenchantement.
        ahv = nil
        ev.bop = true
    end
    if not quality then
        -- Détails de l'objet pas encore chargés par le jeu : on les demande, et on ne conclut rien.
        ev.infoPending = true
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, rec.pid) end
    end
    if CR.Rules().ignoreWhiteGear and quality and quality <= 1 and equipLoc and equipLoc ~= ""
        and equipLoc ~= "INVTYPE_BAG" and equipLoc ~= "INVTYPE_QUIVER" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" then
        ahv = nil
        ev.whiteGear = true
    end
    local pname = ns.db.items[rec.pid] or rec.name
    ev.sold7 = SalesOf(pname, 7)
    ev.sold14 = SalesOf(pname, 14)
    ev.posts14 = PostsOf(pname, 14)
    -- Risque de dépôt : remboursé si l'objet se vend, perdu sinon (à chaque mise en vente ratée).
    local rules0 = CR.Rules()
    local chance = rules0.sellChance / 100
    ev.units14 = PostedUnits(pname, 14)
    if ev.units14 > 0 then chance = math.max(0.1, math.min(1, ev.sold14 / ev.units14)) end
    ev.sellChance = chance
    ev.depositRisk = CR.DepositFor(pname) * (1 - chance) / chance -- dépôts perdus en moyenne avant une vente
    ev.ahNet = ahv and (ahv * (1 - AH_CUT) - ev.depositRisk) * rec.made
    ev.vendorNet = vs and vs * rec.made
    local de = P.DisenchantValue(rec.pid)
    ev.deNet = de and de * rec.made
    ev.listed = P.Entry(rec.pid) and P.Entry(rec.pid).qty
    if ev.ahNet and (not ev.vendorNet or ev.ahNet >= ev.vendorNet) then
        ev.value, ev.channel = ev.ahNet, "ah"
    elseif ev.vendorNet then
        ev.value, ev.channel = ev.vendorNet, "vendor"
    end
    if ev.deNet and (not ev.value or ev.deNet > ev.value) then
        ev.value, ev.channel = ev.deNet, "de"
    end
    if not ev.value then
        ev.verdict, ev.vcolor = "No price", C.faint
        ev.note = "Scan the AH to learn what this item is worth."
        return ev
    end
    if ev.whiteGear then ev.note = "White gear: valued at vendor price only (rarely sells on the AH)." end
    if ev.bop then ev.note = "Binds when picked up: can't be sold on the AH (vendor or disenchant only)." end
    if ev.unknown > 0 then
        ev.verdict, ev.vcolor = "Unknown cost", C.faint
        ev.note = "A reagent has no price yet: scan the AH."
        return ev
    end
    ev.profit = ev.value - ev.cost
    ev.margin = ev.cost > 0 and ev.profit / ev.cost or (ev.profit > 0 and 9.99 or 0)
    if ev.profit > 0 then
        if ev.channel == "vendor" then
            ev.verdict, ev.vcolor = "Vendor it", { 0.88, 0.66, 0.24 }
            ev.note = "Worth more sold to a vendor than on the AH."
        elseif ev.channel == "de" then
            ev.verdict, ev.vcolor = "Disenchant", { 0.75, 0.55, 1.0 }
            ev.note = "Worth more disenchanted (dust/essence sold on the AH) than sold as is. Estimate based on the Classic disenchant table."
        elseif ev.margin >= 0.2 then
            ev.verdict, ev.vcolor = "Profitable", C.pos
        else
            ev.verdict, ev.vcolor = "Thin margin", { 0.95, 0.80, 0.30 }
        end
        if ev.matsAH > ev.value then
            ev.verdict, ev.vcolor = "Sell mats", C.neg
            ev.note = "Your reagents are worth more on the AH than the finished item."
        end
    else
        if ev.matsAH > ev.value then
            ev.verdict, ev.vcolor = "Sell mats", C.neg
            ev.note = "Your reagents are worth more on the AH than the finished item."
        else
            ev.verdict, ev.vcolor = "Loss", C.neg
        end
    end
    -- Posté plusieurs fois sans jamais se vendre : pas rentable en pratique.
    local rules = CR.Rules()
    if ev.posts14 >= rules.unsoldPosts and ev.sold14 == 0 then
        ev.unsold = true
        ev.verdict, ev.vcolor = "Doesn't sell", { 0.62, 0.60, 0.58 }
        ev.note = (Tr("Posted %d× in 14 days without a single sale.")):format(ev.posts14)
    end
    return ev
end

-- ------------------------------------------------------------ interface
local panel, reopen, selected
local evals = {}

local SORTS = {
    { "profit", "Profit" }, { "margin", "Margin" },
}

local function Sorted()
    local list = {}
    for _, rec in ipairs(recipes) do
        evals[rec] = CR.Evaluate(rec)
        list[#list + 1] = rec
    end
    if ns.db.settings.craftSort ~= "margin" then ns.db.settings.craftSort = "profit" end
    local mode = ns.db.settings.craftSort
    table.sort(list, function(a, b)
        local ea, eb = evals[a], evals[b]
        if mode == "name" then return a.name < b.name end
        local va = mode == "margin" and ea.margin or ea.profit
        local vb = mode == "margin" and eb.margin or eb.profit
        if va == nil and vb == nil then return a.name < b.name end
        if va == nil then return false end
        if vb == nil then return true end
        if va == vb then return a.name < b.name end
        return va > vb
    end)
    return list
end

local SRC = {
    vendor = { "Vendor", { 0.88, 0.66, 0.24 } }, ah = { "AH", { 0.55, 0.75, 0.95 } },
    craft = { "Craft", { 0.65, 0.85, 0.55 } }, unknown = { "?", { 0.93, 0.36, 0.32 } },
}

local function Pill(parent, w)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, 18)
    f.fill = T.Rounded(f, { 1, 1, 1, 0.1 }, 6, "ARTWORK")
    f.text = T.Text(f, 10, { bold = true, justify = "CENTER" })
    f.text:SetPoint("CENTER", 0, 0)
    function f:Set(text, color)
        self.text:SetText(text)
        self.text:SetTextColor(color[1], color[2], color[3])
        self.fill:SetColor({ color[1], color[2], color[3], 0.15 })
    end
    return f
end

local function BuildPanel()
    panel = CreateFrame("Frame", "ImpotPointGouvCraftPanel", UIParent)
    panel:SetSize(PW, PH)
    panel:SetFrameStrata("HIGH")
    panel:EnableMouse(true)
    T.Surface(panel, C.window, 14, { 1, 1, 1, 0.09 })

    local icon = panel:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ns.MEDIA .. Tr("icon.tga")); icon:SetSize(26, 26); icon:SetPoint("TOPLEFT", 14, -12)
    panel.title = T.Text(panel, 15, { bold = true, text = Tr("Craft queue") })
    panel.title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, 1)
    panel.sub = T.Text(panel, 11, { color = C.faint })
    panel.sub:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 8, -1)
    local close = T.CloseButton(panel, function()
        ns.db.settings.craftPanel = false
        panel:Hide()
        CR.UpdateIcon()
    end)
    close:SetPoint("TOPRIGHT", -8, -10)

    -- Onglets Recettes / File
    panel.tabButtons = {}
    local prevTab
    for _, t in ipairs({ { "queue", "Queue" }, { "recipes", "Recipes" } }) do
        local b = T.Button(panel, t[2], 76, 24, function() CR.SetTab(t[1]) end, "pill")
        if prevTab then b:SetPoint("RIGHT", prevTab, "LEFT", -4, 0) else b:SetPoint("TOPRIGHT", -44, -13) end
        prevTab = b
        panel.tabButtons[t[1]] = b
    end

    -- Accès rapide à la fenêtre de désenchantement
    local deBtn = CreateFrame("Button", nil, panel)
    deBtn:SetSize(24, 24)
    deBtn:SetPoint("TOPRIGHT", -44, -13)
    -- Plus d'onglet "Recipes" : les profits sont déjà affichés dans la fenêtre de métier.
    for _, b in pairs(panel.tabButtons) do b:Hide() end
    local deTex = deBtn:CreateTexture(nil, "ARTWORK"); deTex:SetAllPoints()
    deTex:SetTexture("Interface\\Icons\\INV_Enchant_Disenchant"); deTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    deBtn:SetScript("OnClick", function() if ns.Destroy then ns.Destroy.Toggle() end end)
    deBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(Tr("Disenchant window"), 1, 1, 1)
        GameTooltip:AddLine(Tr("Disenchant the greens in your bags, one key press each (/ipg de)."), 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    deBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Visible seulement pour un enchanteur.
    deBtn:SetScript("OnShow", function(self)
        if ns.Destroy and ns.Destroy.KnowsDisenchant and not ns.Destroy.KnowsDisenchant() then self:Hide() end
    end)
    if ns.Destroy and ns.Destroy.KnowsDisenchant and not ns.Destroy.KnowsDisenchant() then deBtn:Hide() end

    panel.sortButtons = {}
    local prev
    for i = #SORTS, 1, -1 do
        local s = SORTS[i]
        local b = T.Button(panel, s[2], 54, 18, function()
            ns.db.settings.craftSort = s[1]; CR.Refresh()
        end, "pill")
        T.SetFont(b.text, 10, true)
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -3, 0) else b:SetPoint("TOPRIGHT", -12, -46) end
        prev = b
        panel.sortButtons[s[1]] = b
    end

    panel.info = T.Text(panel, 11, { color = C.muted })
    panel.info:SetPoint("TOPLEFT", 16, -50)
    panel.info:SetWidth(PW - 210)

    -- Liste
    local list = CreateFrame("Frame", nil, panel)
    T.Surface(list, C.surface, 10)
    list:SetPoint("TOPLEFT", 12, -70)
    list:SetPoint("TOPRIGHT", -12, -70)
    list:SetHeight(VIS * ROW_H + 12)
    panel.list = list
    panel.rows = {}
    for i = 1, VIS do
        local r = CreateFrame("Button", nil, list)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", 6, -6 - (i - 1) * ROW_H)
        r:SetPoint("TOPRIGHT", -14, -6 - (i - 1) * ROW_H)
        r.hl = T.Rounded(r, { 1, 1, 1, 0 }, 5, "BACKGROUND", 1)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(20, 20); r.icon:SetPoint("LEFT", 4, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.diff = T.Dot(r, 6, C.gold); r.diff:SetPoint("LEFT", 30, 0)
        r.name = T.Text(r, 12); r.name:SetPoint("LEFT", 42, 0); r.name:SetWidth(170)
        r.pill = Pill(r, 88); r.pill:SetPoint("LEFT", 218, 0)
        r.profit = T.Text(r, 12, { bold = true, justify = "RIGHT" }); r.profit:SetPoint("RIGHT", -4, 0)
        r:SetScript("OnEnter", function(self)
            if not self.sel then self.hl:SetColor({ 1, 1, 1, 0.04 }) end
            if self.rec and self.rec.pid then
                T.ItemTooltip(self, self.rec.pid)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(Tr("Click: details   ·   Right-click: add to queue"), 0.88, 0.66, 0.24)
                GameTooltip:Show()
            end
        end)
        r:SetScript("OnLeave", function(self)
            if not self.sel then self.hl:SetColor({ 1, 1, 1, 0 }) end
            GameTooltip:Hide()
        end)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r:SetScript("OnClick", function(self, button)
            if not self.rec then return end
            if button == "RightButton" and ns.Queue then ns.Queue.Add(profName, self.rec.name, 1); return end
            selected = self.rec.name
            if api then api.Select(self.rec.index) end
            CR.Draw()
        end)
        r:Hide()
        panel.rows[i] = r
    end
    local track = CreateFrame("Frame", nil, list)
    track:SetPoint("TOPRIGHT", -6, -8); track:SetPoint("BOTTOMRIGHT", -6, 8); track:SetWidth(3)
    T.Rounded(track, { 1, 1, 1, 0.04 }, 1, "BACKGROUND")
    panel.thumb = CreateFrame("Frame", nil, track); panel.thumb:SetWidth(3)
    T.Rounded(panel.thumb, { C.gold[1], C.gold[2], C.gold[3], 0.55 }, 1, "ARTWORK")
    panel.track = track
    panel.offset = 0
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, d)
        panel.offset = math.max(0, math.min(math.max(0, #panel.sorted - VIS), panel.offset - d * 2))
        CR.Draw()
    end)
    panel.listEmpty = T.Text(list, 12, { color = C.faint, justify = "CENTER", wrap = true,
        text = Tr("No readable recipes.\nExpand the profession categories.") })
    panel.listEmpty:SetPoint("CENTER"); panel.listEmpty:SetWidth(PW - 80)

    -- Détail
    local det = CreateFrame("Frame", nil, panel)
    T.Surface(det, C.surface, 10)
    det:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -10)
    det:SetPoint("BOTTOMRIGHT", -12, 12)
    panel.det = det
    det.icon = det:CreateTexture(nil, "ARTWORK"); det.icon:SetSize(26, 26); det.icon:SetPoint("TOPLEFT", 12, -10)
    det.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    det.name = T.Text(det, 13, { bold = true }); det.name:SetPoint("TOPLEFT", det.icon, "TOPRIGHT", 8, 1)
    det.name:SetWidth(PW - 150)
    det.meta = T.Text(det, 11, { color = C.faint }); det.meta:SetPoint("BOTTOMLEFT", det.icon, "BOTTOMRIGHT", 8, -1)
    det.pill = Pill(det, 104); det.pill:SetPoint("TOPRIGHT", -12, -14)
    det.qbtn = T.Button(det, Tr("+ Queue"), 70, 20, function()
        if ns.Queue and selected then ns.Queue.Add(profName, selected, 1) end
    end, "pill")
    det.qbtn:SetPoint("RIGHT", det.pill, "LEFT", -6, 0)
    det.qbtn.tooltip = Tr("Add one to the craft queue (right-click a recipe in the list does the same).")
    det.lines = {}
    for i = 1, 5 do
        local l = CreateFrame("Frame", nil, det)
        l:SetSize(PW - 48, 17)
        l:SetPoint("TOPLEFT", 12, -44 - (i - 1) * 17)
        l.icon = l:CreateTexture(nil, "ARTWORK"); l.icon:SetSize(14, 14); l.icon:SetPoint("LEFT", 0, 0)
        l.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        l.name = T.Text(l, 11); l.name:SetPoint("LEFT", 20, 0); l.name:SetWidth(200)
        l.src = T.Text(l, 10, { bold = true }); l.src:SetPoint("LEFT", 226, 0)
        l.cost = T.Text(l, 11, { justify = "RIGHT" }); l.cost:SetPoint("RIGHT", 0, 0)
        l:EnableMouse(true)
        l:SetScript("OnEnter", function(self)
            if self.itemID then T.ItemTooltip(self, self.itemID); GameTooltip:Show() end
        end)
        l:SetScript("OnLeave", function() GameTooltip:Hide() end)
        det.lines[i] = l
    end
    local div = T.Divider(det); div:SetPoint("TOPLEFT", 12, -133); div:SetPoint("TOPRIGHT", -12, -133)
    det.split = CreateFrame("Frame", nil, det)
    det.split:SetPoint("TOPLEFT", 12, -141); det.split:SetPoint("TOPRIGHT", -12, -141); det.split:SetHeight(4)
    det.splitV = det.split:CreateTexture(nil, "ARTWORK"); det.splitV:SetTexture(T.WHITE)
    det.splitV:SetVertexColor(0.88, 0.66, 0.24, 0.9); det.splitV:SetPoint("TOPLEFT"); det.splitV:SetPoint("BOTTOMLEFT")
    det.splitM = det.split:CreateTexture(nil, "ARTWORK"); det.splitM:SetTexture(T.WHITE)
    det.splitM:SetVertexColor(0.55, 0.75, 0.95, 0.9); det.splitM:SetPoint("TOPRIGHT"); det.splitM:SetPoint("BOTTOMRIGHT")
    det.splitTxt = T.Text(det, 10, { color = C.faint }); det.splitTxt:SetPoint("TOPLEFT", 12, -149)

    local function KV(y, label)
        local k = T.Text(det, 11, { color = C.muted, text = label }); k:SetPoint("TOPLEFT", 12, y)
        local v = T.Text(det, 12, { justify = "RIGHT" }); v:SetPoint("TOPRIGHT", -12, y)
        return v
    end
    det.vCost = KV(-166, "Crafting cost")
    det.vAH = KV(-182, "AH sale (− 5% cut, deposit risk)")
    det.vVendor = KV(-198, "Vendor sale")
    det.vDE = KV(-214, "Disenchanted (≈, mats − 5%)")
    det.vMats = KV(-230, "Mats sold on the AH")
    det.profitLbl = T.Text(det, 12, { bold = true, text = Tr("Profit") }); det.profitLbl:SetPoint("TOPLEFT", 12, -250)
    det.vProfit = T.Text(det, 15, { bold = true, justify = "RIGHT" }); det.vProfit:SetPoint("TOPRIGHT", -12, -248)
    det.note = T.Text(det, 11, { color = C.muted, wrap = true }); det.note:SetPoint("TOPLEFT", 12, -270)
    det.note:SetWidth(PW - 48)
    det.empty = T.Text(det, 12, { color = C.faint, justify = "CENTER", text = Tr("Select a recipe.") })
    det.empty:SetPoint("CENTER")
    panel:Hide()
end

local function Money(v, opts)
    if not v then return "|cff615f5c—|r" end
    opts = opts or {}
    opts.iconSize = opts.iconSize or 10
    return ns.FormatMoney(v, opts)
end

local function DrawDetail()
    local det = panel.det
    local rec
    for _, r in ipairs(recipes) do if r.name == selected then rec = r; break end end
    local shown = rec ~= nil
    for _, region in ipairs({ det.icon, det.name, det.meta, det.pill, det.split, det.splitTxt, det.note,
        det.vCost, det.vAH, det.vVendor, det.vDE, det.vMats, det.vProfit, det.profitLbl }) do region:SetShown(shown) end
    det.empty:SetShown(not shown)
    if not rec then for _, l in ipairs(det.lines) do l:Hide() end; return end
    local ev = evals[rec] or CR.Evaluate(rec)
    det.icon:SetTexture(rec.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    det.name:SetText(rec.name .. (rec.made > 1 and ("  |cff8a877f×" .. rec.made .. "|r") or ""))
    local meta = {}
    if ev.listed then meta[#meta + 1] = ev.listed .. Tr(" listed") end
    if ev.sold7 and ev.sold7 > 0 then meta[#meta + 1] = "sold ×" .. ev.sold7 .. " (7d)" end
    local age = rec.pid and P.Age(rec.pid)
    meta[#meta + 1] = "price " .. P.Ago(age)
    det.meta:SetText(rec.enchant and "enchant" or table.concat(meta, "  ·  "))
    det.pill:Set(ev.verdict or "", ev.vcolor or C.muted)
    for i, l in ipairs(det.lines) do
        local line = ev.lines[i]
        if line then
            l.itemID = line.rg.id
            l.icon:SetTexture(line.rg.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            local have = line.rg.have or 0
            local hc = have >= line.rg.n and "|cff5cd173" or "|cff8a877f"
            l.name:SetText(line.rg.name .. "  " .. hc .. have .. "/" .. line.rg.n .. "|r")
            local s = SRC[line.src] or SRC.unknown
            l.src:SetText(s[1] .. (line.est and " ≈" or ""))
            l.src:SetTextColor(s[2][1], s[2][2], s[2][3])
            l.cost:SetText(Money(line.total))
            l:Show()
        else
            l:Hide()
        end
    end
    local total = ev.vendorPart + ev.marketPart
    local w = det.split:GetWidth()
    if total > 0 then
        local vw = w * ev.vendorPart / total
        det.splitV:SetWidth(math.max(0.01, vw)); det.splitM:SetWidth(math.max(0.01, w - vw))
        det.splitV:SetShown(ev.vendorPart > 0); det.splitM:SetShown(ev.marketPart > 0)
        det.splitTxt:SetText((Tr("|cffe0a83dVendor %d %%|r   ·   |cff8cbff2Market %d %%|r   (fixed part / part that follows the AH)"))
            :format(math.floor(ev.vendorPart / total * 100 + 0.5), math.floor(ev.marketPart / total * 100 + 0.5)))
    else
        det.splitV:Hide(); det.splitM:Hide(); det.splitTxt:SetText("")
    end
    det.vCost:SetText(Money(ev.cost > 0 and ev.cost or nil) .. (ev.unknown > 0 and " |cffed5c52+ ?|r" or "")
        .. (ev.estimated and " |cff615f5c≈|r" or ""))
    det.vAH:SetText(Money(ev.ahNet))
    det.vVendor:SetText(Money(ev.vendorNet))
    det.vMats:SetText(Money(ev.matsAH > 0 and ev.matsAH or nil))
    det.vDE:SetText(Money(ev.deNet))
    if ev.profit then
        det.vProfit:SetText(Money(ev.profit, { sign = true, color = true, iconSize = 13 }) ..
            (ev.margin and ("  |cff8a877f" .. math.floor(ev.margin * 100 + 0.5) .. " %|r") or ""))
    else
        det.vProfit:SetText(Tr("|cff615f5c—|r"))
    end
    local note = ev.note or ""
    if ev.estimated then note = (note ~= "" and note .. " " or "") .. Tr("≈ : estimated vendor price, visit the vendor to learn it.") end
    det.note:SetText(note)
end

function CR.Draw()
    if not panel or not panel:IsShown() then return end
    local list = panel.sorted or {}
    panel.offset = math.min(panel.offset, math.max(0, #list - VIS))
    for i, r in ipairs(panel.rows) do
        local rec = list[panel.offset + i]
        r.rec = rec
        if rec then
            local ev = evals[rec]
            r.icon:SetTexture(rec.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            local dc = DIFF[rec.kind] or C.muted
            r.diff:SetVertexColor(dc[1], dc[2], dc[3], 1)
            r.name:SetText(rec.name)
            r.pill:Set(ev.verdict or "", ev.vcolor or C.muted)
            if ev.profit then
                r.profit:SetText(((ev.channel == "de" and ev.profit > 0) and DE_ICON or "") ..
                    Money(ev.profit, { sign = true, color = true, short = true, iconSize = 10 }))
            elseif rec.enchant and ev.cost > 0 then
                r.profit:SetText(Tr("|cff8a877f") .. Money(ev.cost, { short = true }) .. "|r")
            else
                r.profit:SetText(Tr("|cff615f5c—|r"))
            end
            r.sel = (rec.name == selected)
            r.hl:SetColor(r.sel and { C.gold[1], C.gold[2], C.gold[3], 0.12 } or { 1, 1, 1, 0 })
            r:Show()
        else
            r:Hide()
        end
    end
    panel.listEmpty:SetShown(#list == 0)
    if #list > VIS then
        local h = panel.track:GetHeight()
        local th = math.max(20, h * VIS / #list)
        panel.thumb:SetHeight(th)
        panel.thumb:ClearAllPoints()
        panel.thumb:SetPoint("TOP", panel.track, "TOP", 0, -(h - th) * panel.offset / (#list - VIS))
        panel.track:Show()
    else
        panel.track:Hide()
    end
    for k, b in pairs(panel.sortButtons) do b:SetSelected(k == (ns.db.settings.craftSort or "profit")) end
    DrawDetail()
end

function CR.GetRecipes() return recipes end
function CR.GetEval(rec) return evals[rec] or CR.Evaluate(rec) end
function CR.GetAPI() return api end
function CR.ProfName() return profName end
function CR.Panel() return panel end

function CR.SetTab(tab)
    tab = "queue" -- une seule vue
    ns.db.settings.craftTab = tab
    if not panel then return end
    local q = tab == "queue"
    panel.list:SetShown(not q)
    panel.det:SetShown(not q)
    panel.info:SetShown(not q)
    for _, b in pairs(panel.sortButtons) do b:SetShown(not q) end
    for k, b in pairs(panel.tabButtons) do b:SetSelected(k == tab) end
    if ns.Queue then
        if q then ns.Queue.ShowIn(panel) else ns.Queue.HideView() end
    end
end

local DecorateList -- défini plus bas

local readError
function CR.Refresh()
    if not api then return end
    local ok, err = pcall(ReadRecipes)
    readError = not ok and tostring(err) or nil
    local okS, sorted = pcall(Sorted)
    if not okS then readError = readError or tostring(sorted); sorted = {} end
    if DecorateList then DecorateList() end
    if not panel or not panel:IsShown() then return end
    panel.sorted = sorted
    panel.sub:SetText(profName or "")
    -- Fraîcheur des prix
    local newest, known = nil, 0
    for _, rec in ipairs(recipes) do
        if rec.pid then
            local age = P.Age(rec.pid)
            if age then known = known + 1; if not newest or age < newest then newest = age end end
        end
    end
    local good = 0
    for _, rec in ipairs(recipes) do if evals[rec] and evals[rec].verdict == "Profitable" then good = good + 1 end end
    if readError then
        panel.info:SetText(Tr("|cffed5c52Error reading recipes:|r ") .. readError:gsub("^.-:%d+: ", ""))
    elseif known == 0 then
        panel.info:SetText(Tr("|cffe0a83dNo AH prices yet.|r Open the AH and click \"Scan professions\"."))
    else
        panel.info:SetText((Tr("%d recipes  ·  %d profitable  ·  prices updated %s")):format(#recipes, good, P.Ago(newest)))
    end
    if api and not selected then
        local idx = api.Selected()
        for _, r in ipairs(recipes) do if r.index == idx then selected = r.name end end
    end
    CR.Draw()
    if ns.Queue and ns.db.settings.craftTab == "queue" then ns.Queue.Refresh() end
end

-- ------------------------------------------------------------ profit dans la liste Blizzard
-- On ne connaît pas la structure interne de la fenêtre de métier de Forever : on parcourt ses
-- boutons visibles, on reconnaît ceux dont le texte est un nom de recette, et on pose notre propre
-- étiquette (frame enfant à nous, aucune donnée écrite sur les objets Blizzard).
local labels = {}      -- [bouton Blizzard] = notre frame étiquette
local byName = {}

local function CleanName(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text = text:gsub("%s*%[%d+%]%s*$", ""):gsub("%s*%(%d+%)%s*$", "")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end


local function LabelText(ev)
    if not ev then return nil end
    if ev.profit then
        local txt = ns.FormatMoney(ev.profit, { sign = true, color = true, short = true, iconSize = 10 })
        if ev.channel == "de" and ev.profit > 0 then txt = DE_ICON .. txt end
        return txt
    end
    if ev.verdict == "Enchant" and ev.cost > 0 then
        return "|cff8a877f" .. ns.FormatMoney(ev.cost, { short = true, iconSize = 10 }) .. "|r"
    end
    return "|cff615f5c?|r"
end

local listLimit -- bord droit de la zone "liste" (moitié gauche de la fenêtre)
local function FindRecipeText(button)
    if not button.GetRegions then return nil end
    for _, region in ipairs({ button:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "FontString" and region:IsShown()
            and (not listLimit or not region:GetLeft() or region:GetLeft() < listLimit) then
            local name = CleanName(region:GetText())
            if name and byName[name] then return name, region end
        end
    end
end

local seen = {}
DecorateList = function()
    wipe(byName)
    for _, rec in ipairs(recipes) do byName[rec.name] = rec end
    local root = api and api.Frame()
    for btn, lbl in pairs(labels) do lbl:Hide() end
    if not root or not root:IsShown() or ns.db.settings.inlineProfit == false then return end
    wipe(seen)
    listLimit = root:GetLeft() and (root:GetLeft() + root:GetWidth() * 0.42) or nil
    local function Walk(frame, depth)
        if depth > 9 or seen[frame] then return end
        seen[frame] = true
        if frame.IsForbidden and frame:IsForbidden() then return end
        if frame:IsShown() then
            local name, fs = FindRecipeText(frame)
            if name and frame ~= root then
                local lbl = labels[frame]
                if not lbl then
                    lbl = CreateFrame("Frame", nil, frame)
                    lbl:SetSize(80, 14)
                    lbl.text = T.Text(lbl, 11, { bold = true, justify = "RIGHT" })
                    lbl.text:SetPoint("RIGHT", 0, 0)
                    labels[frame] = lbl
                end
                lbl:ClearAllPoints()
                lbl:SetPoint("RIGHT", frame, "RIGHT", -6, 0)
                lbl:SetFrameLevel((frame:GetFrameLevel() or 1) + 2)
                lbl.text:SetText(LabelText(evals[byName[name]]) or "")
                lbl:Show()
            end
            for _, child in ipairs({ frame:GetChildren() }) do Walk(child, depth + 1) end
        end
    end
    Walk(root, 0)
end

-- Les listes se recyclent en défilant : on repasse régulièrement tant que la fenêtre est ouverte.
local ticker = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(ticker, "Craft") end
local acc = 0
ticker:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc < 0.25 then return end
    acc = 0
    local root = api and api.Frame()
    if root and root:IsShown() and #recipes > 0 then DecorateList() end
end)

-- ------------------------------------------------------------ ancrage
local function VisibleFrame()
    for _, name in ipairs({ "TradeSkillFrame", "ProfessionsFrame", "CraftFrame" }) do
        local f = _G[name]
        if f and f.IsShown and f:IsShown() then return f, name end
    end
end

local function ChooseAPI(event)
    if event == "CRAFT_SHOW" and Craft.Available() then return Craft end
    if GetNumTradeSkills and (GetNumTradeSkills() or 0) > 0 then return Trade end
    if Modern.Available() then
        local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
        if ok and ids and #ids > 0 then return Modern end
    end
    if Trade.Available() then return Trade end
    if Modern.Available() then return Modern end
end

local anchorFrame

local function Attach(which)
    api = which
    if not api then return end
    if not panel then BuildPanel() end
    local f = VisibleFrame()
    anchorFrame = f
    -- Fenêtre réelle à utiliser pour la liste et la fermeture.
    local realFrame = f
    api.Frame = function() return realFrame end
    local icon = CR.SideIcon(f)
    if f and not CR.hooked then CR.hooked = {} end
    if f and not CR.hooked[f] then
        CR.hooked[f] = true
        f:HookScript("OnHide", function()
            if anchorFrame == f then
                if panel then panel:Hide() end
                for _, lbl in pairs(labels) do lbl:Hide() end
            end
        end)
    end
    selected = nil
    panel.offset = 0
    if ns.db.settings.craftPanel == false and icon then
        panel:Hide(); CR.Refresh()
    else
        CR.Show()
    end
    CR.UpdateIcon()
end

-- ------------------------------------------------------------ icône dans la colonne d'onglets
-- La colonne d'onglets de métier est à droite de la fenêtre : on repère ses boutons
-- (bord gauche au-delà du bord droit de la fenêtre) pour se placer au-dessus du "?".
local sideIcons, sideRight = {}, nil

local function FindSideStrip(f)
    local fr = f:GetRight()
    if not fr then return end
    local lowest, right
    local function Walk(o, d)
        if d > 5 or not o:IsShown() then return end
        local kind = o.GetObjectType and o:GetObjectType()
        if o ~= f and o ~= sideIcons[f] and (kind == "Button" or kind == "CheckButton") then
            local l, b, w = o:GetLeft(), o:GetBottom(), o:GetWidth()
            if l and b and w and l >= fr - 14 and w >= 24 and w <= 90 then
                if not lowest or b < lowest:GetBottom() then lowest = o end
                local r = o:GetRight()
                if r and (not right or r > right) then right = r end
            end
        end
        for _, c in ipairs({ o:GetChildren() }) do Walk(c, d + 1) end
    end
    Walk(f, 0)
    return lowest, right and (right - fr) or nil
end

function CR.SideIcon(f)
    if not f then return nil end
    local b = sideIcons[f]
    if not b then
        b = CreateFrame("Button", nil, f)
        b.art = b:CreateTexture(nil, "ARTWORK")
        b.art:SetAllPoints()
        b.art:SetTexture(ns.MEDIA .. Tr("icon.tga"))
        b.glow = b:CreateTexture(nil, "OVERLAY")
        b.glow:SetTexture(ns.MEDIA .. Tr("icon.tga"))
        b.glow:SetAllPoints()
        b.glow:SetBlendMode("ADD")
        b.glow:SetAlpha(0)
        b:SetScript("OnEnter", function(self)
            self.glow:SetAlpha(0.35)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(Tr("|cffe0a83dImpot|rPointGouv"))
            GameTooltip:AddLine(Tr("Click: show / hide the craft advisor"), 1, 1, 1)
            GameTooltip:AddLine(Tr("Right-click: open the overview"), 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function(self) self.glow:SetAlpha(0); GameTooltip:Hide() end)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", function(_, button)
            if button == "RightButton" then ns.UI.Toggle(); return end
            if panel and panel:IsShown() then
                ns.db.settings.craftPanel = false
                panel:Hide()
            else
                ns.db.settings.craftPanel = true
                CR.Show()
            end
            CR.UpdateIcon()
        end)
        b.sel = b:CreateTexture(nil, "OVERLAY", nil, 1)
        b.sel:SetTexture(T.WHITE)
        b.sel:SetVertexColor(0.88, 0.66, 0.24, 1)
        b.sel:SetHeight(3)
        b.sel:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 6, -1)
        b.sel:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", -6, -1)
        sideIcons[f] = b
    end
    local ref, right = FindSideStrip(f)
    sideRight = right
    b:ClearAllPoints()
    if ref then
        local size = math.min(ref:GetWidth(), ref:GetHeight())
        b:SetSize(size, size)
        local nearBottom = (ref:GetBottom() - f:GetBottom()) < f:GetHeight() * 0.25
        if nearBottom then
            b:SetPoint("BOTTOM", ref, "TOP", 0, 10)    -- juste au-dessus du "?"
        else
            b:SetPoint("TOP", ref, "BOTTOM", 0, -10)   -- sous le dernier onglet
        end
    else
        b:SetSize(44, 44)
        b:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", 4, 90)
    end
    b:SetFrameLevel((f:GetFrameLevel() or 1) + 10)
    b:Show()
    return b
end

function CR.UpdateIcon()
    for _, b in pairs(sideIcons) do b.sel:SetShown(panel and panel:IsShown() or false) end
end

function CR.Show()
    if not panel then return end
    panel:ClearAllPoints()
    if anchorFrame then
        -- Position mémorisée (déplacée à la main) sinon : à droite de la colonne d'onglets (≈ 64 px).
        local o = ns.db.settings.craftPanelOffset
        if o then
            panel:SetPoint("TOPLEFT", anchorFrame, "TOPRIGHT", o[1], o[2])
        else
            panel:SetPoint("TOPLEFT", anchorFrame, "TOPRIGHT", (sideRight or 64) + 8, 0)
        end
        panel:SetMovable(true)
        panel:RegisterForDrag("LeftButton")
        panel:SetScript("OnDragStart", panel.StartMoving)
        panel:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            local ax, ay = anchorFrame:GetRight(), anchorFrame:GetTop()
            local px, py = self:GetLeft(), self:GetTop()
            if ax and px then
                local scale = self:GetEffectiveScale() / anchorFrame:GetEffectiveScale()
                ns.db.settings.craftPanelOffset = { math.floor(px * scale - ax + 0.5), math.floor(py * scale - ay + 0.5) }
            end
            self:ClearAllPoints()
            local o2 = ns.db.settings.craftPanelOffset or { (sideRight or 64) + 8, 0 }
            self:SetPoint("TOPLEFT", anchorFrame, "TOPRIGHT", o2[1], o2[2])
        end)
    else
        -- Fenêtre de métier introuvable : panneau flottant, déplaçable.
        panel:SetPoint("RIGHT", UIParent, "RIGHT", -60, 0)
        panel:SetMovable(true)
        panel:RegisterForDrag("LeftButton")
        panel:SetScript("OnDragStart", panel.StartMoving)
        panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    end
    panel:Show()
    CR.Refresh()
    CR.SetTab(ns.db.settings.craftTab or "recipes")
    CR.UpdateIcon()
end

-- Sélection faite dans la fenêtre Blizzard -> mise à jour du détail.
local function HookSelection()
    if TradeSkillFrame_SetSelection and not CR.hookedTrade then
        CR.hookedTrade = true
        hooksecurefunc("TradeSkillFrame_SetSelection", function(i)
            if not api or api.key ~= "trade" or not panel or not panel:IsShown() then return end
            for _, r in ipairs(recipes) do if r.index == i then selected = r.name end end
            CR.Draw()
        end)
    end
    if CraftFrame_SetSelection and not CR.hookedCraft then
        CR.hookedCraft = true
        hooksecurefunc("CraftFrame_SetSelection", function(i)
            if not api or api.key ~= "craft" or not panel or not panel:IsShown() then return end
            for _, r in ipairs(recipes) do if r.index == i then selected = r.name end end
            CR.Draw()
        end)
    end
end

-- ------------------------------------------------------------ diagnostic (/ipg diag)
local eventLog = {}
local function LogEvent(e)
    eventLog[#eventLog + 1] = date("%H:%M:%S") .. " " .. e
    if #eventLog > 12 then table.remove(eventLog, 1) end
end

local function Describe(o)
    if not o then return "nil" end
    local name = o.GetName and o:GetName()
    local kind = o.GetObjectType and o:GetObjectType() or "?"
    local txt = ""
    if o.GetLeft and o:GetLeft() then
        txt = (Tr(" @%d,%d %dx%d")):format(o:GetLeft(), o:GetBottom() or 0, o:GetWidth() or 0, o:GetHeight() or 0)
    end
    return (name or ("<" .. kind .. ">")) .. txt
end

local diagWin
local function ShowDiagText(text)
    if not diagWin then
        diagWin = CreateFrame("Frame", "ImpotPointGouvDiag", UIParent)
        diagWin:SetSize(720, 460)
        diagWin:SetPoint("CENTER")
        diagWin:SetFrameStrata("DIALOG")
        diagWin:EnableMouse(true)
        diagWin:SetMovable(true)
        diagWin:RegisterForDrag("LeftButton")
        diagWin:SetScript("OnDragStart", diagWin.StartMoving)
        diagWin:SetScript("OnDragStop", diagWin.StopMovingOrSizing)
        T.Surface(diagWin, C.window, 12, { 1, 1, 1, 0.12 })
        local title = T.Text(diagWin, 13, { bold = true, text = Tr("ImpotPointGouv diagnostic  ·  Ctrl+A then Ctrl+C to copy") })
        title:SetPoint("TOPLEFT", 14, -12)
        local close = T.CloseButton(diagWin, function() diagWin:Hide() end)
        close:SetPoint("TOPRIGHT", -8, -6)
        local sf = CreateFrame("ScrollFrame", nil, diagWin, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 14, -40)
        sf:SetPoint("BOTTOMRIGHT", -32, 14)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(660)
        eb:SetScript("OnEscapePressed", function() diagWin:Hide() end)
        sf:SetScrollChild(eb)
        diagWin.eb = eb
        tinsert(UISpecialFrames, "ImpotPointGouvDiag")
    end
    diagWin.eb:SetText(text)
    diagWin:Show()
    diagWin.eb:SetFocus()
    diagWin.eb:HighlightText()
end

CR.ShowText = function(text) ShowDiagText(text) end

function CR.Diag()
    local out = {}
    local function Add(s) out[#out + 1] = s end
    Add("Version " .. ns.version .. Tr("  ·  Interface ") .. tostring(select(4, GetBuildInfo())))
    for _, n in ipairs({ "TradeSkillFrame", "ProfessionsFrame", "CraftFrame", "ProfessionsBookFrame" }) do
        local f = _G[n]
        Add(("%s : %s"):format(n, f and (f:IsShown() and "visible" or "exists, hidden") or "missing"))
    end
    -- Toutes les fenêtres globales visibles dont le nom évoque les métiers.
    local found = {}
    for k, v in pairs(_G) do
        if type(k) == "string" and type(v) == "table" and (k:find("Profession") or k:find("TradeSkill") or k:find("Craft"))
            and not k:find("ImpotPointGouv") and v.IsShown and v.GetObjectType then
            local ok, shown = pcall(v.IsShown, v)
            if ok and shown then found[#found + 1] = k end
        end
    end
    table.sort(found)
    Add("Visible profession frames: " .. (#found > 0 and table.concat(found, ", ") or "none"))
    Add("GetNumTradeSkills : " .. (GetNumTradeSkills and tostring(GetNumTradeSkills()) or "missing"))
    Add("GetNumCrafts : " .. (GetNumCrafts and tostring(GetNumCrafts()) or "missing"))
    if C_TradeSkillUI then
        local fns = {}
        for k, v in pairs(C_TradeSkillUI) do if type(v) == "function" then fns[#fns + 1] = k end end
        table.sort(fns)
        Add("C_TradeSkillUI functions (" .. #fns .. "): " .. table.concat(fns, ", "))
        local ok, ids = pcall(function() return C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetAllRecipeIDs() end)
        Add("GetAllRecipeIDs : " .. (ok and ids and #ids or tostring(ids)))
        if ok and ids and ids[1] then
            local rid = ids[1]
            local okI, info = pcall(C_TradeSkillUI.GetRecipeInfo, rid)
            if okI and type(info) == "table" then
                local parts = {}
                for k, v in pairs(info) do if type(v) ~= "table" then parts[#parts + 1] = k .. "=" .. tostring(v) end end
                table.sort(parts)
                Add("GetRecipeInfo(" .. rid .. "): " .. table.concat(parts, " | "))
            else
                Add("GetRecipeInfo(" .. rid .. "): " .. tostring(info))
            end
            if C_TradeSkillUI.GetRecipeSchematic then
                local okS, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, rid, false)
                if okS and type(sch) == "table" then
                    local parts = {}
                    for k, v in pairs(sch) do if type(v) ~= "table" then parts[#parts + 1] = k .. "=" .. tostring(v) end end
                    table.sort(parts)
                    Add("GetRecipeSchematic: " .. table.concat(parts, " | "))
                    for i, slot in ipairs(sch.reagentSlotSchematics or {}) do
                        local r = slot.reagents and slot.reagents[1]
                        Add((Tr("  slot %d: itemID=%s qty=%s type=%s")):format(i, tostring(r and r.itemID),
                            tostring(slot.quantityRequired), tostring(slot.reagentType)))
                    end
                else
                    Add("GetRecipeSchematic: " .. tostring(sch))
                end
            end
            for _, fn in ipairs({ "GetRecipeItemLink", "GetRecipeNumReagents", "GetRecipeReagentInfo",
                "GetRecipeReagentItemLink", "GetRecipeNumItemsProduced", "GetRecipeLink" }) do
                if C_TradeSkillUI[fn] then
                    local okF, a1, a2, a3, a4 = pcall(C_TradeSkillUI[fn], rid, 1)
                    Add(("%s(%d,1): %s %s %s %s"):format(fn, rid, tostring(a1), tostring(a2), tostring(a3), tostring(a4)))
                end
            end
        end
        if C_TradeSkillUI.GetBaseProfessionInfo then
            local okB, b = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
            Add("GetBaseProfessionInfo: " .. (okB and type(b) == "table" and tostring(b.professionName) or tostring(b)))
        end
        if C_TradeSkillUI.GetTradeSkillLine then
            Add("GetTradeSkillLine: " .. tostring((select(1, pcall(C_TradeSkillUI.GetTradeSkillLine))) and select(2, pcall(C_TradeSkillUI.GetTradeSkillLine))))
        end
    else
        Add("C_TradeSkillUI : absent")
    end
    Add("API used: " .. (api and api.key or "none") .. Tr("  ·  recipes read: ") .. #recipes)
    local focus = GetMouseFoci and GetMouseFoci()[1] or (GetMouseFocus and GetMouseFocus())
    local chain = {}
    local f = focus
    while f and #chain < 8 do
        chain[#chain + 1] = Describe(f)
        f = f.GetParent and f:GetParent()
    end
    Add("Under mouse: " .. (#chain > 0 and table.concat(chain, "  <  ") or "nothing"))
    -- Frères du bouton survolé (pour trouver la colonne d'onglets).
    if focus and focus.GetParent and focus:GetParent() then
        local sib = {}
        for _, c in ipairs({ focus:GetParent():GetChildren() }) do
            if c.IsShown and c:IsShown() then sib[#sib + 1] = Describe(c) end
        end
        Add("Siblings of hovered: " .. table.concat(sib, "  ·  "))
    end
    Add("Recent events: " .. (#eventLog > 0 and table.concat(eventLog, ", ") or "none"))
    ShowDiagText(table.concat(out, "\n"))
end

-- ------------------------------------------------------------ événements
local ev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(ev, "Craft") end
for _, e in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_CLOSE", "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_DATA_SOURCE_CHANGED", "CRAFT_SHOW", "CRAFT_UPDATE", "CRAFT_CLOSE", "BAG_UPDATE",
    "GET_ITEM_INFO_RECEIVED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
-- Au plus un rafraîchissement par seconde (les infos d'objets et les sacs arrivent en rafales).
local queued, lastCR = false, 0
local function QueueRefresh()
    if queued then return end
    queued = true
    local wait = math.max(0.2, 1 - (GetTime() - lastCR))
    C_Timer.After(wait, function() queued = false; lastCR = GetTime(); CR.Refresh() end)
end
ev:SetScript("OnEvent", function(_, event, _, success)
    if event == "GET_ITEM_INFO_RECEIVED" and success == false then return end -- objet inexistant
    if event ~= "BAG_UPDATE" and event ~= "GET_ITEM_INFO_RECEIVED" then LogEvent(event) end
    if not ns.db then return end
    if event == "TRADE_SKILL_SHOW" or event == "CRAFT_SHOW" then
        -- Laisser la fenêtre Blizzard se charger et s'afficher avant de s'y ancrer.
        C_Timer.After(0.1, function() HookSelection(); Attach(ChooseAPI(event)) end)
    elseif event == "TRADE_SKILL_CLOSE" or event == "CRAFT_CLOSE" then
        C_Timer.After(0.05, function()
            if not VisibleFrame() then
                if panel then panel:Hide() end
                for _, lbl in pairs(labels) do lbl:Hide() end
                api = nil
            end
        end)
    elseif api then
        QueueRefresh()
    end
end)
ns.On("PRICES_CHANGED", function() if api then QueueRefresh() end end)

-- Profilage (/ipg perf) : fonctions lourdes appelées hors des événements chronométrés.
if ns.Profile then
    CR.Refresh = ns.Profile.Wrap("Craft:Refresh", CR.Refresh)
end
