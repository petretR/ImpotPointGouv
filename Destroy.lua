-- ImpotPointGouv : fenêtre de désenchantement (comme "Destroying" de TSM).
-- Liste les verts/bleus des sacs ; un bouton sécurisé (et son raccourci) désenchante l'objet suivant.
-- Le jeu exige un appui de touche par sort : impossible de tout désenchanter en un seul clic.
local _, ns = ...
local Tr = ns.L
local T, P = ns.Theme, ns.Prices
local C = T.C
local D = {}
ns.Destroy = D

local DE_SPELL = 13262
local ROWS, ROW_H = 9, 30
local frame, button
local items = {}

BINDING_HEADER_IMPOTPOINTGOUV = "ImpotPointGouv"
_G["BINDING_NAME_CLICK ImpotPointGouvDestroyButton:LeftButton"] = "Disenchant next item"

local function SpellName()
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(DE_SPELL) end
    if GetSpellInfo then return (GetSpellInfo(DE_SPELL)) end
end

local function KnowsDisenchant()
    if IsPlayerSpell then return IsPlayerSpell(DE_SPELL) end
    return SpellName() ~= nil
end

local function Ignored(id) return ns.db.settings.deIgnore and ns.db.settings.deIgnore[id] end
-- Choix manuel par emplacement (boutons DE / Sell) : true = désenchanter quand même, false = garder pour vendre.
local forced = {}
local function SlotKey(bag, slot) return bag .. ":" .. slot end

local function Container(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then return info.itemID, info.hyperlink, info.isBound end
    end
end

-- ------------------------------------------------------------ inventaire
-- Emplacements des objets de vos ensembles d'équipement (gestionnaire d'équipement) : jamais proposés.
-- Renvoie { ["sac:case"] = { { name, icon }, ... } } pour les objets rangés dans les sacs.
local function SetSlots()
    local used = {}
    if not (C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs) then return used end
    -- Par objet : les ID d'objets de chaque ensemble (fonctionne quelle que soit la version du client).
    local byItem = {}
    for _, setID in ipairs(C_EquipmentSet.GetEquipmentSetIDs() or {}) do
        local name, icon = C_EquipmentSet.GetEquipmentSetInfo(setID)
        local ok, ids = pcall(C_EquipmentSet.GetItemIDs, setID)
        if ok and type(ids) == "table" then
            for _, itemID in pairs(ids) do
                if type(itemID) == "number" and itemID > 0 then
                    byItem[itemID] = byItem[itemID] or {}
                    table.insert(byItem[itemID], { name = name or "?", icon = icon })
                end
            end
        end
    end
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + 1)
    for bag = 0, last do
        for slot = 1, ((C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag)) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and byItem[info.itemID] then used[bag .. ":" .. slot] = byItem[info.itemID] end
        end
    end
    return used
end
D.SetSlots = SetSlots

function D.KnowsDisenchant() return KnowsDisenchant() end

function D.Scan()
    wipe(items)
    if not KnowsDisenchant() then return items end
    local inSet = SetSlots()
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + 1)
    for bag = 0, last do
        local n = (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag)) or 0
        for slot = 1, n do
            local id, link, bound = Container(bag, slot)
            if id and not inSet[bag .. ":" .. slot] then
                local name, _, quality, ilvl, _, _, _, _, equipLoc, icon, _, classID = ns.GetItemInfo(link or id)
                if quality and quality >= 2 and quality <= 4 and (classID == 2 or classID == 4)
                    and equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_BAG" then
                    local de = P.DisenchantValue(id)
                    local ahNet = (not bound) and ns.Craft.AHNet(id, name) or nil
                    local it = {
                        bag = bag, slot = slot, id = id, link = link, name = name, quality = quality,
                        ilvl = ilvl, icon = icon, bound = bound, de = de, ah = ahNet,
                    }
                    -- À désenchanter : pas ignoré, et le désenchantement rapporte au moins autant que l'HV.
                    it.best = (not ahNet or not de or de >= ahNet) and "de" or "sell"
                    local f = forced[SlotKey(bag, slot)]
                    if f ~= nil then it.go = f
                    else it.go = not Ignored(id) and it.best == "de" end
                    it.forced = f
                    items[#items + 1] = it
                end
            end
        end
    end
    table.sort(items, function(a, b)
        if a.go ~= b.go then return a.go end
        return (a.de or 0) > (b.de or 0)
    end)
    return items
end

local function NextItem()
    for _, it in ipairs(items) do if it.go then return it end end
end

-- Pour le raccourci "Next action" : prochain objet à désenchanter (scan des sacs à la volée).
function D.NextTarget()
    if not KnowsDisenchant() then return nil end
    D.Scan()
    return NextItem(), SpellName()
end

-- Met le bouton sécurisé sur l'objet suivant (impossible en combat).
local armed -- objet sur lequel le bouton est réglé
function D.Arm()
    if not button or InCombatLockdown() then return end
    local it = NextItem()
    armed = it
    local spell = SpellName()
    if it and spell then
        button:SetAttribute("type", "macro")
        button:SetAttribute("macrotext", (Tr("/cast %s\n/use %d %d")):format(spell, it.bag, it.slot))
    else
        button:SetAttribute("type", nil)
        button:SetAttribute("macrotext", nil)
    end
    if frame then
        frame.go.text:SetText(it and ("Disenchant:  " .. (it.name or "?")) or "Nothing to disenchant")
        frame.go:SetDisabled(not it)
    end
end

-- ------------------------------------------------------------ interface
local function Build()
    frame = CreateFrame("Frame", "ImpotPointGouvDestroyFrame", UIParent)
    frame:SetSize(420, 70 + ROWS * ROW_H + 90)
    frame:SetPoint("CENTER", 300, 0)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    T.Surface(frame, C.window, 14, { 1, 1, 1, 0.09 })
    tinsert(UISpecialFrames, "ImpotPointGouvDestroyFrame")
    frame:SetToplevel(true)

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Enchant_Disenchant"); icon:SetSize(26, 26); icon:SetPoint("TOPLEFT", 14, -12)
    local title = T.Text(frame, 15, { bold = true, text = Tr("Disenchant") }); title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, 1)
    frame.sub = T.Text(frame, 11, { color = C.faint }); frame.sub:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 8, -1)
    local close = T.CloseButton(frame, function() frame:Hide() end); close:SetPoint("TOPRIGHT", -8, -10)

    local list = CreateFrame("Frame", nil, frame)
    T.Surface(list, C.surface, 10)
    list:SetPoint("TOPLEFT", 12, -50); list:SetPoint("TOPRIGHT", -12, -50)
    list:SetHeight(ROWS * ROW_H + 28)
    local h1 = T.Text(list, 10, { bold = true, color = C.faint, text = Tr("Disenchant"), justify = "RIGHT" })
    h1:SetPoint("TOPRIGHT", -176, -8)
    local h2 = T.Text(list, 10, { bold = true, color = C.faint, text = Tr("AH"), justify = "RIGHT" })
    h2:SetPoint("TOPRIGHT", -116, -8)
    local h3 = T.Text(list, 10, { bold = true, color = C.faint, text = Tr("Do"), justify = "CENTER" })
    h3:SetPoint("TOPRIGHT", -58, -8)
    frame.rows = {}
    local function Choose(r, go)
        local it = r.item
        if not it then return end
        local k = SlotKey(it.bag, it.slot)
        -- Recliquer sur le choix déjà forcé revient à la recommandation.
        if it.forced == go then forced[k] = nil else forced[k] = go end
        D.Refresh()
    end
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, list)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", 6, -22 - (i - 1) * ROW_H); r:SetPoint("TOPRIGHT", -6, -22 - (i - 1) * ROW_H)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(22, 22); r.icon:SetPoint("LEFT", 4, 0)
        r.name = T.Text(r, 12); r.name:SetPoint("LEFT", 32, 0); r.name:SetWidth(128)
        r.de = T.Text(r, 11, { justify = "RIGHT" }); r.de:SetPoint("RIGHT", -170, 0)
        r.ah = T.Text(r, 11, { justify = "RIGHT" }); r.ah:SetPoint("RIGHT", -110, 0)
        -- Choix visible : [DE | Sell], et une croix pour ne plus jamais proposer cet objet.
        r.skip = T.Button(r, "×", 20, 18, function()
            local it = r.item
            if not it then return end
            ns.db.settings.deIgnore = ns.db.settings.deIgnore or {}
            ns.db.settings.deIgnore[it.id] = not ns.db.settings.deIgnore[it.id] or nil
            forced[SlotKey(it.bag, it.slot)] = nil
            D.Refresh()
        end)
        r.skip:SetPoint("RIGHT", -2, 0)
        r.sellB = T.Button(r, Tr("Sell"), 36, 18, function() Choose(r, false) end)
        r.sellB:SetPoint("RIGHT", r.skip, "LEFT", -6, 0)
        r.deB = T.Button(r, Tr("DE"), 36, 18, function() Choose(r, true) end)
        r.deB:SetPoint("RIGHT", r.sellB, "LEFT", -2, 0)
        r:SetScript("OnEnter", function(self)
            if not self.item then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if GameTooltip.SetBagItem then GameTooltip:SetBagItem(self.item.bag, self.item.slot) end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        frame.rows[i] = r
    end
    frame.empty = T.Text(list, 12, { color = C.faint, justify = "CENTER", text = Tr("No green or blue gear in your bags.") })
    frame.empty:SetPoint("CENTER")
    frame.offset = 0
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, d)
        frame.offset = math.max(0, math.min(math.max(0, #items - ROWS), frame.offset - d))
        D.Draw()
    end)

    frame.total = T.Text(frame, 12, { color = C.muted })
    frame.total:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 4, -10)

    -- Bouton sécurisé : c'est lui qui lance le sort (clic ou raccourci).
    button = CreateFrame("Button", "ImpotPointGouvDestroyButton", frame, "SecureActionButtonTemplate")
    button:RegisterForClicks("AnyUp", "AnyDown")
    button:SetPoint("BOTTOMLEFT", 12, 12); button:SetPoint("BOTTOMRIGHT", -12, 12); button:SetHeight(38)
    -- Habillage visuel (non sécurisé) posé sur le bouton.
    frame.go = T.Button(frame, Tr("Disenchant"), 10, 38, nil, "primary")
    frame.go:SetAllPoints(button)
    frame.go:EnableMouse(false)
    frame.go:SetFrameLevel((button:GetFrameLevel() or 1) + 1)
    button:HookScript("OnEnter", function()
        GameTooltip:SetOwner(button, "ANCHOR_TOP")
        local key = GetBindingKey and GetBindingKey("CLICK ImpotPointGouvDestroyButton:LeftButton")
        GameTooltip:AddLine(Tr("Click (or press your key) to disenchant the next item."), 1, 1, 1, true)
        GameTooltip:AddLine(key and ("Key: " .. key) or "Set a key: Options > Keybindings > AddOns > ImpotPointGouv.",
            0.88, 0.66, 0.24, true)
        GameTooltip:Show()
    end)
    button:HookScript("OnLeave", function() GameTooltip:Hide() end)
    frame:SetScript("OnShow", function() D.Refresh(); if ns.Next then ns.Next.Arm() end end)
    frame:SetScript("OnHide", function() if ns.Next then ns.Next.Arm() end end)
    frame:Hide()
end

local function Money(v, opts)
    if not v then return "|cff615f5c—|r" end
    opts = opts or {}; opts.iconSize = 10; opts.short = true
    return ns.FormatMoney(v, opts)
end

function D.Draw()
    if not frame or not frame:IsShown() then return end
    frame.offset = math.min(frame.offset, math.max(0, #items - ROWS))
    local total, count = 0, 0
    for _, it in ipairs(items) do if it.go then total = total + (it.de or 0); count = count + 1 end end
    for i, r in ipairs(frame.rows) do
        local it = items[frame.offset + i]
        r.item = it
        if it then
            r.icon:SetTexture(it.icon)
            local qc = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[it.quality]
            local name = it.name or "?"
            r.name:SetText(name)
            if qc then r.name:SetTextColor(qc.r, qc.g, qc.b) end
            r.de:SetText(Money(it.de, { color = false }))
            r.ah:SetText(it.bound and "|cff615f5cbound|r" or Money(it.ah))
            local ign = Ignored(it.id)
            local rec = (not ign and it.best == "de") and "DE" or "Sell"
            r.deB:SetSelected(it.go); r.sellB:SetSelected(not it.go)
            r.deB.tooltip = Tr("Disenchant this one") .. (rec == "DE" and " (recommended)" or "")
            r.sellB.tooltip = Tr("Keep this one to sell") .. (rec == "Sell" and " (recommended)" or "")
            r.skip:SetSelected(ign and true or false)
            r.skip.tooltip = ign and "Always kept: click to let the addon suggest it again"
                or "Never suggest disenchanting this item"
            if ign then r.name:SetText(name .. Tr("  |cff615f5c(always kept)|r")) end
            r:SetAlpha(it.go and 1 or 0.6)
            r:Show()
        else
            r:Hide()
        end
    end
    frame.empty:SetShown(#items == 0)
    local sell = #items - count
    frame.total:SetText((Tr("%d to disenchant (≈ %s)   ·   %d to sell")):format(count, Money(total), sell))
    frame.sub:SetText(KnowsDisenchant() and "" or "|cffed5c52This character doesn't know Enchanting|r")
end

function D.Refresh()
    if not frame then return end
    D.Scan()
    D.Draw()
    D.Arm()
end

function D.IsShown() return frame ~= nil and frame:IsShown() end

function D.Toggle()
    if not KnowsDisenchant() then
        ns.Print(Tr("this character doesn't know Enchanting: nothing to disenchant here."))
        if frame then frame:Hide() end
        return
    end
    if not frame then Build() end
    frame:SetShown(not frame:IsShown())
    if frame:IsShown() then frame:Raise() end
end

-- ------------------------------------------------------------ événements
-- Journal des désenchantements réels : objet d'origine -> composants obtenus.
local lastDE
local function RecordLoot()
    if not lastDE or GetTime() - lastDE.t > 6 or not GetNumLootItems then return end
    local out = {}
    for i = 1, GetNumLootItems() do
        local id = P.ItemID(GetLootSlotLink and GetLootSlotLink(i))
        local _, _, qty = GetLootSlotInfo(i)
        if id then out[#out + 1] = { id, qty or 1 }; ns.db.items[id] = ns.db.items[id] or (ns.GetItemInfo(id)) end
    end
    if #out > 0 then
        ns.db.deLog = ns.db.deLog or {}
        local src = lastDE.item
        table.insert(ns.db.deLog, { t = time(), id = src and src.id, name = src and src.name, ilvl = src and src.ilvl,
            q = src and src.quality, out = out })
        while #ns.db.deLog > 2000 do table.remove(ns.db.deLog, 1) end
        ns.Fire("DE_LOGGED")
    end
    lastDE = nil
end

local ev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(ev, "Destroy") end
for _, e in ipairs({ "BAG_UPDATE_DELAYED", "PLAYER_REGEN_ENABLED", "UNIT_SPELLCAST_SUCCEEDED", "LOOT_CLOSED",
    "LOOT_READY", "LOOT_OPENED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if not ns.db then return end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if unit ~= "player" then return end
        if spellID == DE_SPELL then lastDE = { t = GetTime(), item = armed } end
    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
        RecordLoot()
        return
    end
    if not frame or not frame:IsShown() then return end
    C_Timer.After(0.2, D.Refresh)
end)
