-- ImpotPointGouv : historique de marché par objet (fenêtre "Price history").
-- * Enregistrement : pour chaque objet des listes, un point par scan (7 jours) et un résumé par jour (2 ans).
--   Point = prix le plus bas (sans les annonces appâts), prix du marché (moyenne des 15 à 30 % les moins chers,
--   à la TSM, sans valeurs aberrantes), quantité en vente, unités parties et unités ajoutées depuis le scan précédent.
-- * Fenêtre : une seule, réutilisée ; deux courbes (bas / marché), un point par scan, barres parties / ajoutées.
local _, ns = ...
local Tr = ns.L
local P = ns.Prices
local H = {}
ns.History = H

local KEEP_SCANS = 7 * 86400   -- points par scan gardés
local MAX_SCANS = 400          -- par objet
local KEEP_DAYS = 730          -- résumés par jour gardés
local MERGE = 120              -- deux enregistrements à moins de 2 min = le même scan
local DIFF_MAX_GAP = 48 * 3600 -- au-delà, on ne compare plus deux scans (parties / ajoutées inconnues)
local LADDER_LEVELS = 60       -- paliers de prix gardés pour comparer au scan suivant

local function Realm() return ns.Realm() end
local function Root()
    ns.db.hist = ns.db.hist or {}
    local r = Realm()
    ns.db.hist[r] = ns.db.hist[r] or {}
    return ns.db.hist[r]
end

-- ------------------------------------------------------------ analyse d'un scan
-- ladder : { [prix unitaire] = quantité } -> paliers triés { {prix, qté}, ... }
local function Levels(ladder)
    local lv = {}
    for p, q in pairs(ladder or {}) do if p and p > 0 and q and q > 0 then lv[#lv + 1] = { p, q } end end
    table.sort(lv, function(a, b) return a[1] < b[1] end)
    return lv
end

-- Prix au quantile f (0..1) des unités de lv, à partir du palier first.
local function Quantile(lv, f, first)
    local total = 0
    for i = first, #lv do total = total + lv[i][2] end
    local want, acc = total * f, 0
    for i = first, #lv do
        acc = acc + lv[i][2]
        if acc >= want then return lv[i][1] end
    end
    return lv[#lv] and lv[#lv][1]
end

-- Renvoie le prix le plus bas (sans appâts) et le prix du marché, d'après les paliers triés.
-- Appât : un palier de 2 unités au plus (ou < 5 % du total) à moins de 60 % du prix de référence ;
-- on en écarte trois au plus. Marché : au moins 15 % des unités, jusqu'à 30 % tant que le palier suivant
-- ne saute pas de plus de 20 % ; puis on retire ce qui s'écarte de plus de 1,5 écart-type et on fait la moyenne.
function H.Analyze(lv)
    if #lv == 0 then return nil, nil end
    local first, total = 1, 0
    for _, l in ipairs(lv) do total = total + l[2] end
    for _ = 1, 3 do
        local l = lv[first]
        if not l or first >= #lv then break end
        local rest = total - l[2]
        local ref = Quantile(lv, 0.15, first + 1)
        if (l[2] <= 2 or l[2] < total * 0.05) and ref and l[1] < ref * 0.6 and rest > 0 then
            first, total = first + 1, rest
        else
            break
        end
    end
    local low = lv[first][1]
    -- tranche des moins chers
    local minU, maxU = total * 0.15, total * 0.30
    local slice, taken, prev = {}, 0, nil
    for i = first, #lv do
        local p, q = lv[i][1], lv[i][2]
        if taken >= minU and prev and p > prev * 1.2 then break end
        local take = math.min(q, math.max(0, maxU - taken))
        if taken < minU then take = math.max(take, math.min(q, minU - taken)) end
        if take <= 0 then break end
        slice[#slice + 1] = { p, take }
        taken, prev = taken + take, p
        if taken >= maxU then break end
    end
    if taken <= 0 then return low, low end
    local sum, n = 0, 0
    for _, s in ipairs(slice) do sum, n = sum + s[1] * s[2], n + s[2] end
    local mean = sum / n
    local var = 0
    for _, s in ipairs(slice) do var = var + s[2] * (s[1] - mean) ^ 2 end
    local sd = math.sqrt(var / n)
    if sd > 0 then
        local s2, n2 = 0, 0
        for _, s in ipairs(slice) do
            if math.abs(s[1] - mean) <= 1.5 * sd then s2, n2 = s2 + s[1] * s[2], n2 + s[2] end
        end
        if n2 > 0 then mean = s2 / n2 end
    end
    return low, math.floor(mean + 0.5)
end

-- Paliers <-> texte compact "prix:qté,prix:qté" (les LADDER_LEVELS moins chers).
local function PackLadder(lv)
    local parts = {}
    for i = 1, math.min(#lv, LADDER_LEVELS) do parts[i] = lv[i][1] .. ":" .. lv[i][2] end
    return table.concat(parts, ",")
end
local function UnpackLadder(s)
    local m = {}
    for p, q in (s or ""):gmatch("(%d+):(%d+)") do m[tonumber(p)] = tonumber(q) end
    return m
end

-- Unités parties / ajoutées entre deux scans, sur la plage de prix que les deux ont vue.
local function Diff(prev, prevHi, now, nowHi)
    local hi = math.min(prevHi or 0, nowHi or 0)
    local gone, new = 0, 0
    for p, q in pairs(prev) do
        if p <= hi then
            local d = (now[p] or 0) - q
            if d < 0 then gone = gone - d else new = new + d end
        end
    end
    for p, q in pairs(now) do
        if p <= hi and not prev[p] then new = new + q end
    end
    return gone, new
end

-- ------------------------------------------------------------ stockage
-- Point par scan : "t,bas,marché,qté,parties,ajoutées" ; résumé du jour : "jour,bas,Σmarché,n marché,qté,parties,ajoutées,scans".
local function Num(v) return v and tostring(math.floor(v + 0.5)) or "" end
local function Split(s)
    local out, i = {}, 0
    for f in (s .. ","):gmatch("([^,]*),") do i = i + 1; out[i] = tonumber(f) end
    return out
end
H._Split = Split

-- Reprend l'historique déjà connu (points par scan et prix du jour) la première fois.
local function Import(id, h)
    local e = P.Entry(id)
    if not e then return end
    local now = time()
    for _, pt in ipairs(e.h or {}) do
        if now - pt[1] <= KEEP_SCANS then
            h.s[#h.s + 1] = table.concat({ Num(pt[1]), Num(pt[2] ~= 0 and pt[2] or nil), "", Num(pt[3]), "", "" }, ",")
        end
    end
    for _, pt in ipairs(e.d or {}) do
        h.d[#h.d + 1] = table.concat({ Num(pt[1]), Num(pt[2]), "", "0", Num(pt[3]), "", "", "1" }, ",")
    end
end

-- merged : même scan déjà compté (pas de scan ni de prix du marché en plus, seulement les écarts).
local function AddDaily(h, t, low, mkt, qty, gone, new, merged)
    local day = math.floor(t / 86400)
    local last = h.d[#h.d] and Split(h.d[#h.d])
    if last and last[1] == day then
        local lo = last[2]
        if low and (not lo or low < lo) then lo = low end
        local ms, mn = last[3] or 0, last[4] or 0
        if mkt and not merged then ms, mn = ms + mkt, mn + 1 end
        local g = (gone or last[6]) and ((last[6] or 0) + (gone or 0)) or nil
        local a = (new or last[7]) and ((last[7] or 0) + (new or 0)) or nil
        h.d[#h.d] = table.concat({ Num(day), Num(lo), mn > 0 and Num(ms) or "", Num(mn), Num(qty or last[5]), Num(g), Num(a),
            Num((last[8] or 0) + (merged and 0 or 1)) }, ",")
    else
        h.d[#h.d + 1] = table.concat({ Num(day), Num(low), Num(mkt), mkt and "1" or "0", Num(qty), Num(gone), Num(new), "1" }, ",")
        local cut = day - KEEP_DAYS
        while h.d[1] and (Split(h.d[1])[1] or 0) < cut do table.remove(h.d, 1) end
    end
end

-- Appelé par Prices.Record pour un objet suivi après une recherche complète.
-- ladder : paliers de prix vus (nil si le scan n'en donne pas, ex. recherche "browse" : bas et quantité seulement).
function H.Note(id, low, qty, ladder)
    if not id then return end
    local root = Root()
    local h = root[id]
    if not h then
        h = { s = {}, d = {} }
        root[id] = h
        Import(id, h)
    end
    local now = time()
    local mkt, gone, new
    if ladder then
        local lv = Levels(ladder)
        local lo
        lo, mkt = H.Analyze(lv)
        low = lo -- nil s'il n'y a plus rien en vente
        local nowHi = #lv == 0 and math.huge or lv[math.min(#lv, LADDER_LEVELS)][1]
        if h.lad and h.lt and now - h.lt <= DIFF_MAX_GAP then
            gone, new = Diff(UnpackLadder(h.lad), (h.lhi == -1) and math.huge or h.lhi, ladder, nowHi)
        end
        -- lhi = plus haut prix vu (-1 : rien en vente, tout palier futur compte comme ajouté)
        h.lad, h.lhi, h.lt = PackLadder(lv), nowHi ~= math.huge and nowHi or -1, now
    end
    local last = h.s[#h.s] and Split(h.s[#h.s])
    local merged = last and last[1] and now >= last[1] and now - last[1] < MERGE
    if merged then
        -- même scan vu par deux chemins (scan complet puis recherche) : on garde le plus récent, on cumule les écarts
        local g = (gone or last[5]) and ((last[5] or 0) + (gone or 0)) or nil
        local a = (new or last[6]) and ((last[6] or 0) + (new or 0)) or nil
        h.s[#h.s] = table.concat({ Num(last[1]), Num(low), Num(mkt or last[3]), Num(qty), Num(g), Num(a) }, ",")
    else
        h.s[#h.s + 1] = table.concat({ Num(now), Num(low), Num(mkt), Num(qty), Num(gone), Num(new) }, ",")
        while h.s[1] and (#h.s > MAX_SCANS or now - (Split(h.s[1])[1] or 0) > KEEP_SCANS) do table.remove(h.s, 1) end
    end
    AddDaily(h, now, low, mkt, qty, gone, new, merged)
    if H.frame and H.frame:IsShown() and H.id == id then H.dirty = true end
end

-- Pas encore d'historique : ce que les prix gardent déjà (points par scan des listes, plus bas du jour).
local function FromPrices(id, span)
    local e = P.Entry(id)
    local out = {}
    if not e then return out end
    local now = time()
    if span and span <= KEEP_SCANS then
        for _, pt in ipairs(e.h or {}) do
            if now - pt[1] <= span then
                out[#out + 1] = { t = pt[1], low = pt[2] ~= 0 and pt[2] or nil, qty = pt[3] }
            end
        end
    end
    if #out == 0 then
        local from = span and math.floor((now - span) / 86400) or -math.huge
        for _, pt in ipairs(e.d or {}) do
            if pt[1] >= from then out[#out + 1] = { t = pt[1] * 86400 + 43200, low = pt[2], qty = pt[3], daily = true } end
        end
    end
    return out
end

-- Points d'une période : { t, low, mkt, qty, gone, new } ; par scan jusqu'à 7 jours, par jour au-delà.
function H.Series(id, span)
    local h = Root()[id]
    if not h then return FromPrices(id, span) end
    local out = {}
    local now = time()
    local function Daily(before)
        local from = span and math.floor((now - span) / 86400) or -math.huge
        for _, s in ipairs(h.d) do
            local f = Split(s)
            local t = f[1] and f[1] * 86400 + 43200
            if f[1] and f[1] >= from and (not before or t < before) and (not span or now - t <= span) then
                out[#out + 1] = { t = t, low = f[2], mkt = (f[4] or 0) > 0 and f[3] and f[3] / f[4] or nil,
                    qty = f[5], gone = f[6], new = f[7], scans = f[8], daily = true }
            end
        end
    end
    if span and span <= KEEP_SCANS then
        -- Points par scan ; avant le premier, les résumés du jour (objet suivi depuis peu).
        local first = h.s[1] and Split(h.s[1])[1]
        Daily(first or now + 1)
        for _, s in ipairs(h.s) do
            local f = Split(s)
            if f[1] and now - f[1] <= span then
                out[#out + 1] = { t = f[1], low = f[2], mkt = f[3], qty = f[4], gone = f[5], new = f[6] }
            end
        end
    else
        Daily(nil)
    end
    return out
end

-- Résumé pour l'en-tête : dernier point, point d'il y a 24 h, scans aujourd'hui.
function H.Summary(id)
    local h = Root()[id]
    if not h then
        -- d'après les plus bas du jour gardés par les prix
        local e = P.Entry(id)
        if not e or not e.d or #e.d == 0 then return nil end
        local today = math.floor(time() / 86400)
        local ago
        for _, pt in ipairs(e.d) do if pt[1] < today then ago = pt[2] end end
        return { t = e.t, low = e.cur, ago = ago, today = 0 }
    end
    local now, last, ago, today = time(), nil, nil, 0
    local day = math.floor(now / 86400)
    for _, s in ipairs(h.s) do
        local f = Split(s)
        if f[1] then
            if f[2] then last = f end
            if f[2] and f[1] <= now - 86400 then ago = f end
            if math.floor(f[1] / 86400) == day then today = today + 1 end
        end
    end
    if not ago then
        for _, s in ipairs(h.d) do
            local f = Split(s)
            if f[1] and f[1] < day and f[2] then ago = { f[1] * 86400 + 43200, f[2] } end
        end
    end
    return { t = last and last[1], low = last and last[2], mkt = last and last[3], qty = last and last[4],
        ago = ago and ago[2], today = today }
end

-- ------------------------------------------------------------ fenêtre
local T = ns.Theme
local C = T.C
local BLUE = { 0.45, 0.68, 0.95, 1 }
local PINK = { 0.83, 0.33, 0.49, 1 }
local RANGES = {
    { "1d", "1 day", 86400 }, { "1w", "1 week", 7 * 86400 }, { "1m", "1 month", 30 * 86400 },
    { "6m", "6 months", 182 * 86400 }, { "1y", "1 year", 365 * 86400 }, { "all", "All", nil },
}

local function NiceStep(range, ticks)
    if range <= 0 then return 1 end
    local raw = range / ticks
    local mag = 10 ^ math.floor(math.log10(raw))
    local norm = raw / mag
    return (norm < 1.5 and 1 or norm < 3 and 2 or norm < 7 and 5 or 10) * mag
end
local function Pool(list, i, create)
    local o = list[i]
    if not o then o = create(); list[i] = o end
    o:Show()
    return o
end
local function HideFrom(list, n) for i = n, #list do list[i]:Hide() end end

-- Repris de la fiche prix (v0.24.0) : écarts en %, rareté à l'HV, prix à un instant donné.
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
local function LowAt(pts, t)
    local v
    for _, p in ipairs(pts) do
        if p.low then
            if p.t <= t then v = p.low else break end
        end
    end
    if v then return v end
    for _, p in ipairs(pts) do if p.low then return p.low end end
end
local function Tile(parent)
    local t = CreateFrame("Frame", nil, parent)
    T.Surface(t, C.surface, 8)
    t.label = T.Text(t, 9, { bold = true, color = C.faint, justify = "CENTER" }); t.label:SetPoint("TOP", 0, -8)
    t.value = T.Text(t, 15, { bold = true, justify = "CENTER" }); t.value:SetPoint("TOP", 0, -23)
    return t
end

local function Build()
    local f = CreateFrame("Frame", "ImpotPointGouvHistory", UIParent)
    f:SetSize(700, 460)
    f:SetPoint("CENTER", 120, 40)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    T.Surface(f, C.window, 14, { 1, 1, 1, 0.09 })
    tinsert(UISpecialFrames, "ImpotPointGouvHistory")
    local close = T.CloseButton(f, function() f:Hide() end)
    close:SetPoint("TOPRIGHT", -10, -10)

    -- En-tête
    f.icon = f:CreateTexture(nil, "ARTWORK"); f.icon:SetSize(40, 40); f.icon:SetPoint("TOPLEFT", 18, -18)
    f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.iconHit = CreateFrame("Frame", nil, f); f.iconHit:SetAllPoints(f.icon)
    f.iconHit:SetScript("OnEnter", function(self) if H.id then T.ItemTooltip(self, H.id) end end)
    f.iconHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.name = T.Text(f, 14, { bold = true }); f.name:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 12, 1)
    f.name:SetWidth(230); f.name:SetWordWrap(false)
    f.price = T.Text(f, 22, { bold = true }); f.price:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -4)
    f.change = T.Text(f, 12); f.change:SetPoint("TOPLEFT", f.price, "BOTTOMLEFT", 0, -3)
    f.last = T.Text(f, 11, { color = C.faint }); f.last:SetPoint("TOPLEFT", f.change, "BOTTOMLEFT", 0, -3)

    -- Chiffres clés (repris de la fiche prix) : écart au prix marchand ou habituel, 4 jours, 1er scan, offre.
    f.tiles = {}
    for i = 1, 4 do
        local t = Tile(f)
        t:SetSize(92, 46)
        t:SetPoint("TOPRIGHT", -40 - (4 - i) * 98, -18)
        f.tiles[i] = t
    end

    -- Légende
    local leg, prevL = {}, nil
    for _, it in ipairs({ { Tr("Lowest listing"), C.gold, "line" }, { Tr("Market price"), BLUE, "line" },
        { Tr("Units gone"), C.pos, "bar" }, { Tr("Units listed"), PINK, "bar" } }) do
        local sw = f:CreateTexture(nil, "ARTWORK"); sw:SetTexture(T.WHITE)
        sw:SetVertexColor(it[2][1], it[2][2], it[2][3], 1)
        if it[3] == "line" then sw:SetSize(14, 2) else sw:SetSize(8, 8) end
        if prevL then sw:SetPoint("LEFT", prevL, "RIGHT", 14, 0) else sw:SetPoint("TOPLEFT", 18, -116) end
        local tx = T.Text(f, 11, { color = C.muted, text = it[1] }); tx:SetPoint("LEFT", sw, "RIGHT", 5, 0)
        leg[#leg + 1] = sw
        prevL = tx
    end

    -- Zone du graphique : prix en haut, barres en bas.
    local plot = CreateFrame("Frame", nil, f)
    plot:SetPoint("TOPLEFT", 18, -134)
    plot:SetPoint("BOTTOMRIGHT", -70, 140)
    f.plot = plot
    local bars = CreateFrame("Frame", nil, f)
    bars:SetPoint("TOPLEFT", plot, "BOTTOMLEFT", 0, -6)
    bars:SetPoint("TOPRIGHT", plot, "BOTTOMRIGHT", 0, -6)
    bars:SetHeight(52)
    f.barsFrame = bars
    local base = bars:CreateTexture(nil, "BACKGROUND"); base:SetTexture(T.WHITE); base:SetVertexColor(1, 1, 1, 0.07)
    base:SetHeight(1); base:SetPoint("BOTTOMLEFT"); base:SetPoint("BOTTOMRIGHT")
    f.lines, f.dots, f.bars, f.grids, f.ylabels, f.xlabels = {}, {}, {}, {}, {}, {}
    f.refTex, f.refLabels = {}, {}
    -- Lecture des fluctuations : prix habituel, fourchette, volatilité, ventes, verdict.
    f.stats = T.Text(f, 12, { color = C.muted }); f.stats:SetPoint("BOTTOMLEFT", 20, 50)
    f.stats:SetWidth(660); f.stats:SetWordWrap(false)
    f.empty = T.Text(f, 13, { color = C.muted, justify = "CENTER", wrap = true })
    f.empty:SetPoint("CENTER", plot, "CENTER"); f.empty:SetWidth(420)
    f.tag = CreateFrame("Frame", nil, f); f.tag:SetSize(56, 16)
    f.tagBg = T.Rounded(f.tag, C.gold, 4, "BACKGROUND")
    f.tagTx = T.Text(f.tag, 10, { bold = true, justify = "CENTER", color = { 0.08, 0.07, 0.05, 1 } })
    f.tagTx:SetPoint("CENTER")

    -- Survol : ligne verticale + infobulle du scan le plus proche.
    local hover = CreateFrame("Frame", nil, f)
    hover:SetPoint("TOPLEFT", plot, "TOPLEFT"); hover:SetPoint("BOTTOMRIGHT", bars, "BOTTOMRIGHT")
    hover:EnableMouse(true)
    f.cross = hover:CreateTexture(nil, "OVERLAY"); f.cross:SetTexture(T.WHITE); f.cross:SetVertexColor(1, 1, 1, 0.18)
    f.cross:SetWidth(1); f.cross:Hide()
    hover:SetScript("OnEnter", function() f.hovering = true end)
    hover:SetScript("OnLeave", function() f.hovering = false; f.hoverI = nil; f.cross:Hide(); GameTooltip:Hide() end)
    hover:SetScript("OnUpdate", function()
        if H.dirty then H.dirty = false; H.Refresh() end
        if not f.hovering or not f.coords or #f.coords == 0 then return end
        local x = GetCursorPosition() / plot:GetEffectiveScale() - plot:GetLeft()
        local bi, bd = 1, math.huge
        for i, c in ipairs(f.coords) do
            local d = math.abs(c.x - x)
            if d < bd then bi, bd = i, d end
        end
        if bi == f.hoverI and GameTooltip:IsOwned(hover) then return end
        f.hoverI = bi
        local c = f.coords[bi]
        local pt = c.p
        f.cross:ClearAllPoints()
        f.cross:SetPoint("TOP", plot, "TOPLEFT", c.x, 0); f.cross:SetPoint("BOTTOM", bars, "BOTTOMLEFT", c.x, 0)
        f.cross:Show()
        GameTooltip:SetOwner(hover, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        local right = c.x > plot:GetWidth() * 0.6
        GameTooltip:SetPoint(right and "TOPRIGHT" or "TOPLEFT", plot, "TOPLEFT", c.x + (right and -12 or 12), -6)
        GameTooltip:AddLine(date(pt.daily and "%d/%m/%Y" or "%d/%m %H:%M", pt.t), 0.75, 0.72, 0.66)
        local function M(v) return v and ns.FormatMoney(v, { iconSize = 11 }) or "—" end
        GameTooltip:AddDoubleLine(Tr("Lowest listing"), M(pt.low), C.gold[1], C.gold[2], C.gold[3], 1, 1, 1)
        GameTooltip:AddDoubleLine(Tr("Market price"), M(pt.mkt), BLUE[1], BLUE[2], BLUE[3], 1, 1, 1)
        GameTooltip:AddDoubleLine(Tr("Listed"), pt.qty and tostring(pt.qty) or "—", 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddDoubleLine(Tr("Units gone"), pt.gone and tostring(pt.gone) or "—", C.pos[1], C.pos[2], C.pos[3], 1, 1, 1)
        GameTooltip:AddDoubleLine(Tr("Units listed"), pt.new and tostring(pt.new) or "—", PINK[1], PINK[2], PINK[3], 1, 1, 1)
        if pt.daily and pt.scans then GameTooltip:AddLine((Tr("%d scans that day")):format(pt.scans), 0.6, 0.6, 0.6) end
        GameTooltip:Show()
    end)

    -- Périodes
    f.rangeBtns = {}
    local prev
    for _, r in ipairs(RANGES) do
        local b = T.Button(f, Tr(r[2]), 104, 26, function()
            ns.db.settings.histRange = r[1]
            H.Refresh()
        end, "pill")
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 6, 0) else b:SetPoint("BOTTOMLEFT", 18, 16) end
        prev = b
        f.rangeBtns[r[1]] = b
    end
    f:Hide()
    return f
end

local function Money(v) return ns.FormatMoney(v, { iconSize = 14 }) end

local function Draw(f, pts, refs, band)
    local plot, barsF = f.plot, f.barsFrame
    local W, Hh, BH = plot:GetWidth(), plot:GetHeight(), barsF:GetHeight()
    f.coords = {}
    local any = false
    local vmin, vmax, bmax = math.huge, -math.huge, 0
    for _, p in ipairs(pts) do
        for _, v in ipairs({ p.low, p.mkt }) do
            if v then any = true; vmin = math.min(vmin, v); vmax = math.max(vmax, v) end
        end
        bmax = math.max(bmax, p.gone or 0, p.new or 0)
    end
    if not any or W <= 0 then
        HideFrom(f.lines, 1); HideFrom(f.dots, 1); HideFrom(f.bars, 1); HideFrom(f.grids, 1)
        HideFrom(f.ylabels, 1); HideFrom(f.xlabels, 1); f.tag:Hide()
        HideFrom(f.refTex, 1); HideFrom(f.refLabels, 1)
        f.empty:SetText(Tr("No scans for this item in this period. Scan its list (or do a full scan) at the AH."))
        f.empty:Show()
        return
    end
    f.empty:Hide()
    -- Lignes de référence (prix marchand, habituel) : seulement si elles restent proches de la courbe.
    for _, ref in ipairs(refs or {}) do
        if ref.v and ref.v > 0 and ref.v <= vmax * 1.6 then vmin = math.min(vmin, ref.v); vmax = math.max(vmax, ref.v) end
    end
    if vmax == vmin then vmax, vmin = vmax * 1.05 + 1, math.max(0, vmin * 0.95 - 1) end
    local step = NiceStep(vmax - vmin, 4)
    local lo, hi = math.floor(vmin / step) * step, math.ceil(vmax / step) * step
    if hi == lo then hi = lo + step end
    local function Y(v) return (v - lo) / (hi - lo) * (Hh - 10) + 5 end
    local t0, t1 = pts[1].t, pts[#pts].t
    if t1 == t0 then t0, t1 = t0 - 1800, t1 + 1800 end
    local function X(t) return 6 + (t - t0) / (t1 - t0) * (W - 12) end

    -- Grille + prix à droite
    local gi = 0
    for v = lo, hi + step * 0.5, step do
        gi = gi + 1
        local g = Pool(f.grids, gi, function()
            local tx = plot:CreateTexture(nil, "BACKGROUND"); tx:SetTexture(T.WHITE); tx:SetHeight(1); return tx
        end)
        g:SetVertexColor(1, 1, 1, 0.04)
        g:ClearAllPoints(); g:SetPoint("LEFT", plot, "BOTTOMLEFT", 0, Y(v)); g:SetPoint("RIGHT", plot, "BOTTOMRIGHT", 0, Y(v))
        local l = Pool(f.ylabels, gi, function() return T.Text(f, 10, { color = C.faint }) end)
        l:ClearAllPoints(); l:SetPoint("LEFT", plot, "BOTTOMRIGHT", 8, Y(v)); l:SetText(ns.FormatMoneyAxis(v))
    end
    HideFrom(f.grids, gi + 1); HideFrom(f.ylabels, gi + 1)
    -- Dates en bas (5)
    local fmt = (t1 - t0) <= 86400 * 1.5 and "%H:%M" or "%d/%m"
    for i = 1, 5 do
        local t = t0 + (t1 - t0) * (i - 1) / 4
        local l = Pool(f.xlabels, i, function() return T.Text(f, 10, { color = C.faint, justify = "CENTER" }) end)
        l:ClearAllPoints()
        l:SetPoint(i == 1 and "TOPLEFT" or i == 5 and "TOPRIGHT" or "TOP", barsF, "BOTTOMLEFT", X(t), -5)
        l:SetText(date(fmt, math.floor(t)))
    end

    -- Bande du prix habituel (bas–haut) et lignes de référence en pointillés (repris de la fiche prix).
    local ri = 0
    local function Tex(layer, sub)
        ri = ri + 1
        return Pool(f.refTex, ri, function() local tx = plot:CreateTexture(nil, layer, nil, sub); tx:SetTexture(T.WHITE); return tx end)
    end
    if band and band[1] and band[2] and band[2] > band[1] then
        local y1, y2 = math.max(0, Y(band[1])), math.min(Hh, Y(band[2]))
        if y2 > y1 then
            local b = Tex("BACKGROUND", 2)
            b:ClearAllPoints(); b:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y1); b:SetSize(W, y2 - y1)
            b:SetVertexColor(1, 1, 1, 0.035)
        end
    end
    local rl = 0
    for _, ref in ipairs(refs or {}) do
        local y = ref.v and Y(ref.v)
        if y and y >= 0 and y <= Hh then
            local col = ref.color
            for x = 0, W, 9 do
                local d = Tex("ARTWORK", 0)
                d:ClearAllPoints(); d:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x, y); d:SetSize(5, 1)
                d:SetVertexColor(col[1], col[2], col[3], ref.alpha)
            end
            rl = rl + 1
            local lbl = Pool(f.refLabels, rl, function() return T.Text(f, 10, { color = C.faint }) end)
            lbl:ClearAllPoints(); lbl:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 4, y + 2)
            lbl:SetText(ref.label); lbl:SetTextColor(col[1], col[2], col[3], 0.8)
        end
    end
    HideFrom(f.refTex, ri + 1); HideFrom(f.refLabels, rl + 1)

    -- Courbes : un point par scan, reliés au scan suivant quand les deux ont une valeur.
    local li, di = 0, 0
    local dotSize = #pts > 200 and 3 or #pts > 80 and 4 or 5
    local function Series(key, col)
        local prevX, prevY
        for _, p in ipairs(pts) do
            local v = p[key]
            if v then
                local x, y = X(p.t), Y(v)
                if prevX then
                    li = li + 1
                    local l = Pool(f.lines, li, function()
                        local ln = plot:CreateLine(nil, "ARTWORK"); ln:SetTexture(T.WHITE); return ln
                    end)
                    l:SetThickness(1.6); l:SetVertexColor(col[1], col[2], col[3], 0.75)
                    l:SetStartPoint("BOTTOMLEFT", plot, prevX, prevY); l:SetEndPoint("BOTTOMLEFT", plot, x, y)
                end
                di = di + 1
                local d = Pool(f.dots, di, function()
                    local t = plot:CreateTexture(nil, "OVERLAY"); t:SetTexture(T.CIRCLE); return t
                end)
                d:SetSize(dotSize, dotSize); d:SetVertexColor(col[1], col[2], col[3], 1)
                d:ClearAllPoints(); d:SetPoint("CENTER", plot, "BOTTOMLEFT", x, y)
                prevX, prevY = x, y
            else
                prevX, prevY = nil, nil
            end
        end
    end
    Series("mkt", BLUE)
    Series("low", C.gold)
    HideFrom(f.lines, li + 1); HideFrom(f.dots, di + 1)

    -- Barres : parties (vert) et ajoutées (rose), côte à côte sous chaque scan.
    local bi = 0
    local minGap = math.huge
    for i = 2, #pts do minGap = math.min(minGap, X(pts[i].t) - X(pts[i - 1].t)) end
    local bw = math.max(1, math.min(6, (minGap == math.huge and 12 or minGap) * 0.4))
    for _, p in ipairs(pts) do
        local x = X(p.t)
        for k, v in ipairs({ p.gone, p.new }) do
            if v and v > 0 and bmax > 0 then
                bi = bi + 1
                local b = Pool(f.bars, bi, function()
                    local t = barsF:CreateTexture(nil, "ARTWORK"); t:SetTexture(T.WHITE); return t
                end)
                local col = k == 1 and C.pos or PINK
                b:SetVertexColor(col[1], col[2], col[3], 0.85)
                b:ClearAllPoints()
                b:SetPoint("BOTTOMLEFT", barsF, "BOTTOMLEFT", k == 1 and (x - bw) or x, 1)
                b:SetSize(bw, math.max(1, v / bmax * (BH - 4)))
            end
        end
        f.coords[#f.coords + 1] = { x = x, p = p }
    end
    HideFrom(f.bars, bi + 1)

    -- Étiquette du dernier prix le plus bas, sur l'axe.
    local lastLow
    for i = #pts, 1, -1 do if pts[i].low then lastLow = pts[i].low; break end end
    if lastLow then
        f.tag:ClearAllPoints(); f.tag:SetPoint("LEFT", plot, "BOTTOMRIGHT", 4, Y(lastLow))
        f.tagTx:SetText(ns.FormatMoneyAxis(lastLow)); f.tag:SetWidth((f.tagTx:GetStringWidth() or 40) + 10)
        f.tag:Show()
    else
        f.tag:Hide()
    end
end

function H.Refresh()
    local f = H.frame
    if not f or not H.id then return end
    local id = H.id
    local name, _, quality = ns.GetItemInfo(id)
    name = name or P.Name(id)
    local qc = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    f.name:SetText(qc and (qc.hex .. name .. "|r") or name)
    f.icon:SetTexture(ns.GetItemIcon(id) or "Interface\\Icons\\INV_Misc_QuestionMark")
    local sm = H.Summary(id)
    local e = P.Entry(id)
    local cur = (sm and sm.low) or (e and e.cur)
    f.price:SetText(cur and Money(cur) or "|cff615f5c—|r")
    if cur and sm and sm.ago and sm.ago > 0 then
        local d = cur - sm.ago
        local pct = d / sm.ago * 100
        local col = d < 0 and "|cffed5c52" or d > 0 and "|cff5cd173" or "|cff94918b"
        f.change:SetText(col .. ns.FormatMoney(d, { iconSize = 11, sign = true }) .. ("  %s%.1f%% 1D"):format(d < 0 and "↓" or d > 0 and "↑" or "", math.abs(pct)) .. "|r")
    else
        f.change:SetText("|cff94918b" .. Tr("No price 24 h ago yet") .. "|r")
    end
    local lastT = (sm and sm.t) or (e and e.t)
    f.last:SetText((Tr("Last scan %s · %d scans today")):format(lastT and P.Ago(time() - lastT) or Tr("never"), sm and sm.today or 0))
    local key = ns.db.settings.histRange or "1w"
    local span
    for _, r in ipairs(RANGES) do
        f.rangeBtns[r[1]]:SetSelected(r[1] == key)
        if r[1] == key then span = r[3] end
    end
    local st = P.Stats(id) or {}
    local vs = P.VendorSell(id)
    local all = H.Series(id, nil)
    -- Chiffres clés.
    local tl = f.tiles
    if vs and cur then
        tl[1].label:SetText(Tr("VS VENDOR PRICE"))
        local x = cur / vs
        tl[1].value:SetText((x < 1.05 and "|cffed5c52" or "|cffece6d6") .. ("%.1f×"):format(x) .. "|r")
    else
        tl[1].label:SetText(Tr("VS USUAL PRICE"))
        tl[1].value:SetText(PctText(Pct(cur, st.med)))
    end
    tl[2].label:SetText(Tr("LAST 4 DAYS"))
    tl[2].value:SetText(PctText(Pct(cur, LowAt(all, time() - 4 * 86400))))
    tl[3].label:SetText(Tr("SINCE FIRST SCAN"))
    tl[3].value:SetText(PctText(Pct(cur, LowAt(all, 0))))
    local sc, scCol = Scarcity((sm and sm.qty) or (e and e.qty))
    tl[4].label:SetText(Tr("AH SUPPLY"))
    tl[4].value:SetText(sc); tl[4].value:SetTextColor(scCol[1], scCol[2], scCol[3])
    -- Fluctuations.
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
    if vs then s[#s + 1] = Tr("Vendor price: ") .. ns.FormatMoney(vs, { iconSize = 11, short = true }) end
    local v = ns.Lists and ns.Lists.Verdict and ns.Lists.Verdict({ id = id, kind = "mat", uses = 1, roles = {} }, P.Stats(id))
    if v == "buy" then s[#s + 1] = "|cff5cd173" .. Tr("good time to buy") .. "|r"
    elseif v == "sell" then s[#s + 1] = "|cffe0a83d" .. Tr("good time to sell") .. "|r" end
    f.stats:SetText(#s > 0 and table.concat(s, "  ·  ") or Tr("Scan the AH a few times to read this item's fluctuations."))
    local refs = {}
    if vs then refs[#refs + 1] = { v = vs, label = Tr("vendor price"), color = { 0.45, 0.68, 0.95 }, alpha = 0.55 } end
    if st.med then refs[#refs + 1] = { v = st.med, label = Tr("usual"), color = { 0.93, 0.90, 0.84 }, alpha = 0.3 } end
    Draw(f, H.Series(id, span), refs, st.low and st.high and { st.low, st.high })
end

-- Ouvre la fenêtre sur un objet (ou change d'objet si elle est déjà ouverte).
function H.Show(id)
    if not id then return end
    H.frame = H.frame or Build()
    H.id = id
    if not ns.GetItemInfo(id) and C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    H.frame:Show()
    H.frame:Raise()
    H.Refresh()
end

-- /ipg item <lien | id | nom>
function H.Command(arg)
    arg = arg or ""
    local id = tonumber(arg) or tonumber(arg:match("item:(%d+)"))
    if not id and arg ~= "" then
        local want, partial = arg:lower(), nil
        for iid, n in pairs(ns.db.items or {}) do
            if type(n) == "string" then
                local ln = n:lower()
                if ln == want then id = iid; break end
                if not partial and ln:find(want, 1, true) then partial = iid end
            end
        end
        id = id or partial
    end
    if id then H.Show(id) else ns.Print(Tr("usage: /ipg item <item link, id or name>")) end
end

ns.On("PRICES_CHANGED", function() if H.frame and H.frame:IsShown() then H.dirty = true end end)
-- Suivi automatique des objets ouverts (essayé puis retiré) : on efface ce qu'il a pu laisser.
ns.On("DB_READY", function() if ns.db then ns.db.histTrack = nil end end)

-- Profilage (/ipg perf) : fonctions lourdes appelées hors des événements chronométrés.
if ns.Profile then
    H.Note = ns.Profile.Wrap("History:Note", H.Note)
end
