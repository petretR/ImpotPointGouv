-- ImpotPointGouv : rentabilité des patrons chez le maître de métier.
-- Pour chaque patron : profit par craft (meilleur canal HV / marchand / désenchantement)
-- et nombre de crafts pour rembourser le prix du patron.
local _, ns = ...
local T, P, CR = ns.Theme, ns.Prices, ns.Craft
local TR = {}
ns.Trainer = TR


local function ReverseNames()
    local rev = {}
    for id, name in pairs(ns.db.items) do rev[name] = id end
    return rev
end

-- Composants lus dans l'infobulle du patron. Sur Forever :
--   "Reagents:"  puis  "Bolt of Linen Cloth (12), Fine Thread (2),"  puis  "Minor Healing Potion (2)"
local function Clean(text)
    return (text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|n", " ")
end

local function IdFromName(name, rev)
    if rev[name] then return rev[name] end
    local _, link = ns.GetItemInfo(name)
    local id = P.ItemID(link)
    if id then ns.db.items[id] = name end
    return id
end

local function ReagentsFromTooltip(i, rev)
    if not (C_TooltipInfo and C_TooltipInfo.GetTrainerService) then return nil end
    local ok, data = pcall(C_TooltipInfo.GetTrainerService, i)
    if not ok or not data or not data.lines then return nil end
    local header = Clean(SPELL_REAGENTS or "Reagents:"):gsub("%s+$", "")
    local text
    for k, line in ipairs(data.lines) do
        local lt = Clean(line.leftText)
        local pos = lt:find(header, 1, true)
        if pos then
            text = lt:sub(pos + #header)
            -- Suite sur les lignes suivantes tant que la liste continue (ligne vide ou finissant par une virgule).
            local j = k + 1
            local needMore = text:match("^%s*$") or text:match(",%s*$")
            while needMore and data.lines[j] do
                local nxt = Clean(data.lines[j].leftText)
                if nxt:match("^%s*$") then break end
                text = text .. " " .. nxt
                needMore = nxt:match(",%s*$")
                j = j + 1
            end
            break
        end
    end
    if not text then return nil end
    local list = {}
    for raw in text:gmatch("[^,]+") do
        local part = raw:gsub("^%s+", ""):gsub("%s+$", "")
        local name, n = part:match("^(.-)%s*%((%d+)%)$")
        name = name or part
        n = tonumber(n) or 1
        if name ~= "" then
            local id = IdFromName(name, rev)
            list[#list + 1] = { id = id, name = name, n = n, icon = id and ns.GetItemIcon(id), have = id and ns.GetItemCount(id) or 0 }
        end
    end
    return #list > 0 and list or nil
end

local function Analyse(i, rev)
    local name, _, category = GetTrainerServiceInfo(i)
    if not name or category == "header" then return nil end
    local cost = GetTrainerServiceCost and GetTrainerServiceCost(i) or 0
    local link = GetTrainerServiceItemLink and GetTrainerServiceItemLink(i)
    local pid = P.ItemID(link)
    if not pid then return { name = name, cost = cost } end
    local reagents = ReagentsFromTooltip(i, rev)
    local rec = { name = name, pid = pid, made = 1, reagents = reagents or {}, enchant = false }
    local ev = CR.Evaluate(rec)
    if not reagents then ev.noReagents = true end
    return { name = name, cost = cost, ev = ev }
end

-- ------------------------------------------------------------ infobulle ImpotPointGouv (sous celle de Blizzard)
local C = T.C
local tip

local function Money(v, opts)
    if not v then return "|cff615f5c—|r" end
    opts = opts or {}
    opts.iconSize = opts.iconSize or 11
    return ns.FormatMoney(v, opts)
end

local function BuildTip()
    tip = CreateFrame("Frame", "ImpotPointGouvTrainerTip", UIParent)
    tip:SetFrameStrata("TOOLTIP")
    tip:SetSize(300, 100)
    T.Surface(tip, C.window, 8, { C.gold[1], C.gold[2], C.gold[3], 0.45 })
    tip.lines = {}
    tip:Hide()
end

local function Line(i)
    local l = tip.lines[i]
    if not l then
        l = { left = T.Text(tip, 12), right = T.Text(tip, 12, { justify = "RIGHT" }) }
        l.left:SetPoint("TOPLEFT", 12, -10 - (i - 1) * 17)
        l.right:SetPoint("TOPRIGHT", -12, -10 - (i - 1) * 17)
        tip.lines[i] = l
    end
    return l
end

local function ShowTip(a, anchor)
    if not tip then BuildTip() end
    local ev = a.ev
    local rows = {}
    -- rows: { gauche, droite, couleurGauche, espaceAvant }
    local function Add(left, right, lc, gap) rows[#rows + 1] = { left, right or "", lc, gap } end
    local G, M, W = "|cffe0a83d", "|cff8a877f", "|cffece6d6"
    if not ev then
        Add(G .. "Impot|r" .. W .. "PointGouv|r", "")
        Add(M .. "This pattern doesn't make an item.|r", "")
    else
        -- En-tête : verdict
        local verdict
        if ev.profit and not ev.noReagents then
            local how = ev.channel == "de" and "disenchant" or ev.channel == "vendor" and "sell to vendor" or "sell on AH"
            verdict = ev.profit > 0 and ("|cff5cd173Profitable|r " .. M .. "(" .. how .. ")|r") or "|cffed5c52Not profitable|r"
        else
            verdict = M .. "Missing prices|r"
        end
        Add(G .. "Impot|r" .. W .. "PointGouv|r", verdict)

        -- Composants
        Add(M .. "REAGENTS|r", "", nil, true)
        for _, line in ipairs(ev.lines or {}) do
            local src = line.src == "vendor" and "vendor" or line.src == "ah" and "AH" or line.src == "craft" and "you craft it"
                or "|cffed5c52no price|r"
            Add(("%s ×%d  " .. M .. "%s|r"):format(line.rg.name or "?", line.rg.n or 1, src), Money(line.total))
        end
        Add(W .. "Total cost|r", Money(ev.cost > 0 and ev.cost or nil) .. (ev.unknown > 0 and " |cffed5c52+ ?|r" or ""))

        -- Vente : la meilleure option en or
        Add(M .. "SELLING IT|r", "", nil, true)
        local function Opt(label, value, key, why)
            local best = ev.channel == key and ev.profit
            local l = best and (G .. "» " .. label .. "|r") or label
            Add(l, why and (M .. why .. "|r") or Money(value), nil)
        end
        Opt("On the AH  " .. M .. "(− 5% cut & lost deposits)|r", ev.ahNet, "ah",
            ev.bop and "bound, can't sell" or (ev.whiteGear and "white item, won't sell") or nil)
        Opt("To a vendor", ev.vendorNet, "vendor")
        Opt("Disenchanted  " .. M .. (ev.deObserved and "(your results)" or "(estimate)") .. "|r", ev.deNet, "de",
            (not ev.deNet and ev.whiteGear) and "can't disenchant" or nil)

        -- Résultat
        Add(M .. "RESULT|r", "", nil, true)
        if ev.profit and not ev.noReagents then
            Add(W .. "Profit per craft|r", Money(ev.profit, { sign = true, color = true, iconSize = 12 }))
            if a.cost and a.cost > 0 then
                if ev.profit > 0 then
                    Add("Pattern " .. Money(a.cost), ("|cff5cd173paid back after %d crafts|r"):format(math.ceil(a.cost / ev.profit)))
                else
                    Add("Pattern " .. Money(a.cost), M .. "only for skill-ups|r")
                end
            end
        else
            Add(M .. "Scan the AH to price every reagent.|r", "")
        end
    end
    local width, y = 280, -10
    for i, r in ipairs(rows) do
        local l = Line(i)
        if r[4] then y = y - 6 end
        l.left:ClearAllPoints(); l.right:ClearAllPoints()
        l.left:SetPoint("TOPLEFT", 12, y); l.right:SetPoint("TOPRIGHT", -12, y)
        l.left:SetText(r[1]); l.right:SetText(r[2])
        local c = r[3] or C.text
        l.left:SetTextColor(c[1], c[2], c[3])
        T.SetFont(l.left, r[4] and 10 or 12, r[4] or i == 1)
        l.left:Show(); l.right:Show()
        width = math.max(width, l.left:GetStringWidth() + l.right:GetStringWidth() + 40)
        y = y - (r[4] and 15 or 17)
    end
    for i = #rows + 1, #tip.lines do tip.lines[i].left:Hide(); tip.lines[i].right:Hide() end
    tip:SetSize(math.min(width, 440), -y + 8)
    tip:ClearAllPoints()
    if GameTooltip:IsShown() then
        tip:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 0, -4)
    else
        tip:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
    end
    tip:Show()
end

local function TrainerFrame()
    for _, n in ipairs({ "ClassTrainerFrame", "TrainerFrame" }) do
        local f = _G[n]
        if f and f.IsShown and f:IsShown() then return f end
    end
end

-- Lignes du maître -> patron (recalculé régulièrement : la liste se recycle en défilant).
local rowService = {}
local analysis = {}
local badges = {} -- [ligne] = petite icône "rentable"

local function Badge(row, a)
    local ev = a and a.ev
    local good = ev and ev.profit and ev.profit > 0 and not ev.noReagents
    local b = badges[row]
    if not good then if b then b:Hide() end; return end
    if not b then
        b = CreateFrame("Frame", nil, row)
        b:SetSize(14, 14)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        b.ring = b:CreateTexture(nil, "OVERLAY")
        b.ring:SetPoint("TOPLEFT", -2, 2); b.ring:SetPoint("BOTTOMRIGHT", 2, -2)
        b.ring:SetTexture(T.CIRCLE)
        b.ring:SetVertexColor(0.36, 0.82, 0.45, 0.35)
        b.ring:SetDrawLayer("ARTWORK", -1)
        badges[row] = b
    end
    b:ClearAllPoints()
    b:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -14, 8)
    b:SetFrameLevel((row:GetFrameLevel() or 1) + 3)
    b.icon:SetTexture(ev.channel == "de" and "Interface\\Icons\\INV_Enchant_Disenchant" or "Interface\\Icons\\INV_Misc_Coin_02")
    b:Show()
end

-- Calculs (lecture des infobulles de patrons) : une fois à l'ouverture, refaits si un objet arrive.
local dirty = true
function TR.Invalidate() dirty = true end

local function Analyze()
    if not GetNumTrainerServices or not ns.db then return end
    local rev = ReverseNames()
    wipe(analysis)
    local pending = false
    for i = 1, GetNumTrainerServices() do
        local a = Analyse(i, rev)
        if a then
            analysis[a.name] = a
            if a.ev and a.ev.infoPending then pending = true end
        end
    end
    dirty = pending -- objets pas encore chargés : on recalculera
end

-- Placement des icônes : rapide, appelé en continu (les lignes se recyclent en défilant).
function TR.Decorate()
    local root = TrainerFrame()
    if not root then return end
    if dirty then Analyze() end
    wipe(rowService)
    local seen, matched = {}, {}
    local function Walk(frame, depth)
        if depth > 10 or seen[frame] or not frame:IsShown() then return end
        seen[frame] = true
        if frame ~= root and frame.GetRegions then
            for _, region in ipairs({ frame:GetRegions() }) do
                if region.GetObjectType and region:GetObjectType() == "FontString" and region:IsShown() then
                    local a = analysis[region:GetText() or ""]
                    if a then rowService[frame] = a; matched[frame] = true; Badge(frame, a); break end
                end
            end
        end
        for _, c in ipairs({ frame:GetChildren() }) do Walk(c, depth + 1) end
    end
    Walk(root, 0)
    for row, b in pairs(badges) do if not matched[row] then b:Hide() end end
end

-- Survol : notre infobulle sous celle de Blizzard.
local ticker = CreateFrame("Frame")
local acc, rescan, current = 0, 0, nil
ticker:SetScript("OnUpdate", function(_, elapsed)
    acc, rescan = acc + elapsed, rescan + elapsed
    if acc < 0.05 then return end
    acc = 0
    if not TrainerFrame() then
        if tip and tip:IsShown() then tip:Hide() end
        current = nil
        return
    end
    if rescan > 0.1 then rescan = 0; TR.Decorate() end
    local hovered
    for row, a in pairs(rowService) do
        if row:IsVisible() and row:IsMouseOver() then hovered = { row, a }; break end
    end
    if hovered then
        if current ~= hovered[2] or not tip or not tip:IsShown() then
            current = hovered[2]
            ShowTip(hovered[2], hovered[1])
        elseif tip and GameTooltip:IsShown() then
            tip:ClearAllPoints()
            tip:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 0, -4)
        end
    elseif tip and tip:IsShown() then
        tip:Hide()
        current = nil
    end
end)

local ev = CreateFrame("Frame")
for _, e in ipairs({ "TRAINER_SHOW", "TRAINER_UPDATE", "TRAINER_CLOSED", "GET_ITEM_INFO_RECEIVED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event)
    if event == "TRAINER_CLOSED" then
        if tip then tip:Hide() end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if TrainerFrame() then dirty = true end
    else
        dirty = true
        C_Timer.After(0.2, TR.Decorate)
    end
end)
ns.On("PRICES_CHANGED", function() dirty = true end)
