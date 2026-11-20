-- ImpotPointGouv : fiche prix d'un objet. Courbe du prix le plus bas à l'HV, bande du prix habituel,
-- prix marchand en pointillés, et quatre chiffres clés pour juger le prix et ses fluctuations.
-- Ouverture : clic sur un objet dans Lists, Market ou Stock, ou /ipg price [objet].
local _, ns = ...
local Tr = ns.L
local T, P = ns.Theme, ns.Prices
local C = T.C
local PC = {}
ns.PriceCard = PC

local W, H = 620, 430
local frame

-- ------------------------------------------------------------ données
-- Points { t, prix, quantité } : un par scan pour les objets suivis, sinon le plus bas de chaque jour (30 jours).
function PC.Series(id)
    local e = P.Entry(id)
    if not e then return {} end
    local pts, hasDay = {}, {}
    for _, p in ipairs(e.h or {}) do
        if (p[2] or 0) > 0 then
            pts[#pts + 1] = { p[1], p[2], p[3] or 0 }
            hasDay[math.floor(p[1] / 86400)] = true
        end
    end
    for _, d in ipairs(e.d or {}) do
        if not hasDay[d[1]] and (d[2] or 0) > 0 then pts[#pts + 1] = { d[1] * 86400 + 43200, d[2], d[3] or 0 } end
    end
    table.sort(pts, function(a, b) return a[1] < b[1] end)
    -- Le prix actuel termine la courbe.
    if e.cur and e.t and (#pts == 0 or e.t > pts[#pts][1] + 60) then pts[#pts + 1] = { e.t, e.cur, e.qty or 0 } end
    return pts
end

-- Prix au plus près d'un instant donné (dernier point avant, sinon le premier).
local function PriceAt(pts, t)
    local v
    for _, p in ipairs(pts) do
        if p[1] <= t then v = p[2] else break end
    end
    return v or (pts[1] and pts[1][2])
end

local function Pct(a, b)
    if not a or not b or b <= 0 then return nil end
    return (a / b - 1) * 100
end

local function PctText(v)
    if not v then return "|cff615f5c—|r" end
    local col = v > 0.5 and "|cff5cd173" or v < -0.5 and "|cffed5c52" or "|cffece6d6"
    return ("%s%s%d%%|r"):format(col, v > 0 and "+" or (v < 0 and "−" or ""), math.floor(math.abs(v) + 0.5))
end

local function Scarcity(qty)
    if not qty or qty == 0 then return Tr("Not listed"), C.neg end
    if qty < 25 then return Tr("Scarce"), { 0.36, 0.82, 0.45 } end
    if qty < 250 then return Tr("Limited"), C.gold end
    return Tr("Plentiful"), C.muted
end

-- ------------------------------------------------------------ fenêtre
local function Tile(parent)
    local f = CreateFrame("Frame", nil, parent)
    T.Surface(f, C.surface, 8)
    f.label = T.Text(f, 10, { bold = true, color = C.faint, justify = "CENTER" }); f.label:SetPoint("TOP", 0, -10)
    f.value = T.Text(f, 18, { bold = true, justify = "CENTER" }); f.value:SetPoint("TOP", 0, -28)
    return f
end

local function Build()
    frame = CreateFrame("Frame", "ImpotPointGouvPriceCard", UIParent)
    frame:SetSize(W, H)
    frame:SetPoint("CENTER", 0, 40)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetToplevel(true)
    T.Surface(frame, C.window, 14, { 1, 1, 1, 0.09 })
    tinsert(UISpecialFrames, "ImpotPointGouvPriceCard")

    -- En-tête : icône, nom, caractéristiques.
    frame.icon = frame:CreateTexture(nil, "ARTWORK"); frame.icon:SetSize(46, 46); frame.icon:SetPoint("TOPLEFT", 20, -18)
    frame.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    frame.name = T.Text(frame, 22, { bold = true }); frame.name:SetPoint("TOPLEFT", frame.icon, "TOPRIGHT", 14, -2)
    frame.name:SetWidth(W - 160); frame.name:SetWordWrap(false)
    frame.meta = T.Text(frame, 12, { color = C.muted }); frame.meta:SetPoint("BOTTOMLEFT", frame.icon, "BOTTOMRIGHT", 14, 2)
    frame.meta:SetWidth(W - 110); frame.meta:SetWordWrap(false)
    local close = T.CloseButton(frame, function() frame:Hide() end); close:SetPoint("TOPRIGHT", -10, -10)

    -- Quatre chiffres clés.
    frame.tiles = {}
    local gap, tw = 8, (W - 40 - 8 * 3) / 4
    for i = 1, 4 do
        local t = Tile(frame)
        t:SetSize(tw, 60)
        t:SetPoint("TOPLEFT", 20 + (i - 1) * (tw + gap), -82)
        frame.tiles[i] = t
    end

    -- Période.
    frame.range = ns.db.settings.priceCardRange or 30
    frame.rangeBtns = {}
    local prev
    for _, d in ipairs({ { 30, "30 days" }, { 7, "7 days" }, { 2, "48 h" } }) do
        local b = T.Button(frame, Tr(d[2]), 64, 22, function()
            frame.range = d[1]; ns.db.settings.priceCardRange = d[1]; PC.Draw()
        end, "pill")
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -4, 0) else b:SetPoint("TOPRIGHT", -20, -152) end
        prev = b
        frame.rangeBtns[d[1]] = b
    end
    frame.rangeTitle = T.Text(frame, 11, { bold = true, color = C.faint }); frame.rangeTitle:SetPoint("TOPLEFT", 22, -157)

    -- Courbe.
    local box = CreateFrame("Frame", nil, frame)
    T.Surface(box, C.surface, 10)
    box:SetPoint("TOPLEFT", 20, -180); box:SetPoint("BOTTOMRIGHT", -20, 56)
    frame.chart = ns.Chart.Create(box)
    frame.chart:SetPoint("TOPLEFT", 4, -8); frame.chart:SetPoint("BOTTOMRIGHT", -6, 2)
    frame.chart.tooltipExtra = function(tip, i, p)
        local pt = frame.pts and frame.pts[i]
        if pt and pt[3] then tip:AddLine((Tr("%d listed")):format(pt[3]), 0.6, 0.6, 0.6) end
    end

    -- Lecture des fluctuations.
    frame.stats = T.Text(frame, 12, { color = C.muted }); frame.stats:SetPoint("BOTTOMLEFT", 22, 32)
    frame.stats:SetWidth(W - 44); frame.stats:SetWordWrap(false)
    frame.foot = T.Text(frame, 10, { color = C.faint }); frame.foot:SetPoint("BOTTOMLEFT", 22, 14)
    frame.foot:SetWidth(W - 44); frame.foot:SetWordWrap(false)
    frame:Hide()
end

function PC.Draw()
    if not frame or not frame:IsShown() or not frame.id then return end
    local id = frame.id
    for k, b in pairs(frame.rangeBtns) do b:SetSelected(k == frame.range) end
    local name, _, quality, ilvl, _, itemType, subType = ns.GetItemInfo(id)
    if not name and C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    frame.icon:SetTexture(ns.GetItemIcon(id) or "Interface\\Icons\\INV_Misc_QuestionMark")
    local qc = ITEM_QUALITY_COLORS and quality and ITEM_QUALITY_COLORS[quality]
    frame.name:SetText(P.Name(id))
    if qc then frame.name:SetTextColor(qc.r, qc.g, qc.b) else frame.name:SetTextColor(unpack(C.text)) end

    local e = P.Entry(id) or {}
    local st = P.Stats(id) or {}
    local vs = P.VendorSell(id)
    local all = PC.Series(id)
    local cur = e.cur

    -- Caractéristiques : rareté à l'HV, niveau, type, prix marchand.
    local sc, scCol = Scarcity(e.qty)
    local parts = { ("|cff%02x%02x%02x%s|r"):format(math.floor(scCol[1] * 255), math.floor(scCol[2] * 255), math.floor(scCol[3] * 255), sc) }
    if ilvl and ilvl > 1 then parts[#parts + 1] = (Tr("Item level %d")):format(ilvl) end
    if subType and subType ~= "" then parts[#parts + 1] = subType end
    if itemType and itemType ~= "" and itemType ~= subType then parts[#parts + 1] = itemType end
    if vs then parts[#parts + 1] = Tr("Vendor price: ") .. ns.FormatMoney(vs, { iconSize = 11 }) end
    frame.meta:SetText(table.concat(parts, "  ·  "))

    -- Chiffres clés.
    local t = frame.tiles
    t[1].label:SetText(Tr("PRICE NOW"))
    t[1].value:SetText(cur and ns.FormatMoney(cur, { iconSize = 15, short = true }) or "|cff615f5c—|r")
    if vs and cur then
        t[2].label:SetText(Tr("VS VENDOR PRICE"))
        local x = cur / vs
        t[2].value:SetText((x < 1.05 and "|cffed5c52" or "|cffece6d6") .. ("%.1f×"):format(x) .. "|r")
    else
        t[2].label:SetText(Tr("VS USUAL PRICE"))
        t[2].value:SetText(PctText(Pct(cur, st.med)))
    end
    t[3].label:SetText(Tr("SINCE FIRST SCAN"))
    t[3].value:SetText(PctText(Pct(cur, all[1] and all[1][2])))
    t[4].label:SetText(Tr("LAST 4 DAYS"))
    t[4].value:SetText(PctText(Pct(cur, PriceAt(all, time() - 4 * 86400))))

    -- Courbe sur la période choisie.
    local from = time() - frame.range * 86400
    local pts, raw = {}, {}
    for _, p in ipairs(all) do
        if p[1] >= from then pts[#pts + 1] = { p[1], p[2] }; raw[#raw + 1] = p end
    end
    frame.pts = raw
    frame.rangeTitle:SetText(#pts >= 2 and (Tr("LOWEST PRICE AT THE AH  ·  %d points")):format(#pts) or "")
    local refs = {}
    if vs then refs[#refs + 1] = { v = vs, label = Tr("vendor price"), color = { 0.45, 0.68, 0.95 }, alpha = 0.55 } end
    if st.med then refs[#refs + 1] = { v = st.med, label = Tr("usual"), color = { 0.93, 0.90, 0.84 }, alpha = 0.3 } end
    frame.chart:SetData(pts, {
        refs = refs,
        band = st.low and st.high and { st.low, st.high },
        lastLabel = cur and ns.FormatMoney(cur, { iconSize = 11, short = true }),
        emptyText = Tr("Not enough scans yet for a curve.\nScan the AH on a few different days."),
    })

    -- Fluctuations : prix habituel, fourchette, volatilité, ventes.
    local s = {}
    if st.med then s[#s + 1] = Tr("Usual ") .. ns.FormatMoney(st.med, { iconSize = 11, short = true }) end
    if st.low and st.high then
        s[#s + 1] = Tr("usual range ") .. ns.FormatMoney(st.low, { iconSize = 11, short = true }) .. " – " ..
            ns.FormatMoney(st.high, { iconSize = 11, short = true })
    end
    if st.cv and st.n and st.n >= 3 then
        local v = st.cv
        local word = v < 0.10 and Tr("stable") or v < 0.25 and Tr("moves a little") or v < 0.5 and Tr("volatile") or Tr("very volatile")
        s[#s + 1] = (Tr("volatility %d%% (%s)")):format(math.floor(v * 100 + 0.5), word)
    end
    if st.sales then s[#s + 1] = (Tr("~%s sold/day")):format(st.sales >= 10 and tostring(math.floor(st.sales + 0.5)) or ("%.1f"):format(st.sales)) end
    local v = ns.Lists and ns.Lists.Verdict and ns.Lists.Verdict({ id = id, kind = "mat", uses = 1, roles = {} }, P.Stats(id))
    if v == "buy" then s[#s + 1] = "|cff5cd173" .. Tr("good time to buy") .. "|r"
    elseif v == "sell" then s[#s + 1] = "|cffe0a83d" .. Tr("good time to sell") .. "|r" end
    frame.stats:SetText(#s > 0 and table.concat(s, "  ·  ") or Tr("Scan the AH a few times to read this item's fluctuations."))
    local watched = ns.Lists and ns.Lists.IsWatched and ns.Lists.IsWatched(id)
    frame.foot:SetText((e.t and (Tr("Last seen %s")):format(P.Ago(time() - e.t)) or Tr("Never seen at the AH")) .. "  ·  " ..
        (watched and Tr("one point per scan (item in your lists)") or Tr("one point per day (add it to a list for one point per scan)")) ..
        "  ·  " .. Tr("WoW Forever auction house"))
end

function PC.Show(id)
    if not id then return end
    if not frame then Build() end
    frame.id = id
    frame:Show()
    frame:Raise()
    PC.Draw()
end

-- Recherche par nom pour /ipg price.
function PC.Find(text)
    if not text or text == "" then return nil end
    local id = tonumber(text) or (P.ItemID and P.ItemID(text))
    if id then return id end
    local q = text:lower()
    local exact, partial
    for iid, n in pairs(ns.db.items or {}) do
        if type(n) == "string" then
            local ln = n:lower()
            if ln == q then exact = iid; break end
            if not partial and ln:find(q, 1, true) then partial = iid end
        end
    end
    return exact or partial
end

-- Noms et icônes qui arrivent après coup.
local ev = CreateFrame("Frame")
pcall(ev.RegisterEvent, ev, "GET_ITEM_INFO_RECEIVED")
ev:SetScript("OnEvent", function(_, _, id)
    if frame and frame:IsShown() and id == frame.id then PC.Draw() end
end)
