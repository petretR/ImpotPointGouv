-- ImpotPointGouv: market history per item ("Price history" window).
-- * Data: PriceStore.lua (per-scan points for tracked items, daily then weekly records for every item).
-- * Window: a single one, reused; two curves (low / market), one point per scan or per day,
--   gone / added bars (estimated sold per day on daily and weekly points).
local _, ns = ...
local Tr = ns.L
local P = ns.Prices
local H = {}
ns.History = H

local Store = ns.Store
local D, W = Store.D, Store.W

-- Kept for other modules: market price of a ladder (see PriceStore.lua).
H.Analyze = Store.Analyze

-- Called by Prices.Record: redraw the window if it shows this item.
function H.Touched(id)
    if H.frame and H.frame:IsShown() and H.id == id then H.dirty = true end
end

local function DailyPoint(d)
    return { t = d[1] * 86400 + 43200, low = d[D.low], high = d[D.high], usual = d[D.usual], mkt = d[D.mkt],
        qty = d[D.qty], gone = d[D.gone] or d[D.sold], new = d[D.new], sold = d[D.sold], depth = d[D.depth],
        scans = d[D.scans], daily = true }
end
local function WeeklyPoint(w)
    local start = Store.WeekStart(w[1])
    local sold = w[W.sold] and w[W.soldDays] and w[W.soldDays] > 0 and w[W.sold] / w[W.soldDays] or nil
    return { t = (start + 3.5) * 86400, low = w[W.low], usual = w[W.usual], qty = w[W.qty],
        gone = sold, sold = sold, depth = w[W.depth], daily = true, weekly = true }
end

-- Points of a period: { t, low, mkt, qty, gone, new, ... }; per scan up to 7 days (tracked items),
-- per day before, per week before the daily records.
function H.Series(id, span)
    local e = P.Entry(id)
    local out = {}
    if not e then return out end
    local now = time()
    local from = span and (now - span) or nil
    local pts = (span and span <= Store.KEEP_SCANS) and Store.Points(e, from) or {}
    local firstPt = pts[1] and pts[1][1] or math.huge
    local days = Store.Days(e, from and math.floor(from / 86400) or nil, true)
    local firstDay = days[1] and days[1][1] * 86400 or math.huge
    for _, w in ipairs(Store.Weeks(e)) do
        local p = WeeklyPoint(w)
        if (not from or p.t >= from) and Store.WeekStart(w[1] + 1) * 86400 <= firstDay then out[#out + 1] = p end
    end
    for _, d in ipairs(days) do
        local p = DailyPoint(d)
        -- the day of the first scan point and later: shown per scan
        if d[1] * 86400 + 86400 <= firstPt and (not from or p.t >= from) then out[#out + 1] = p end
    end
    for _, pt in ipairs(pts) do
        out[#out + 1] = { t = pt[1], low = pt[2], mkt = pt[3], qty = pt[4], gone = pt[5], new = pt[6], depth = pt[7] }
    end
    -- Untracked item on a short range: today's scans, one point each.
    if #pts == 0 and span and span <= Store.KEEP_SCANS and e.o then
        local base = #out
        for _, smp in ipairs(Store.Samples(e.o)) do
            if not from or smp[1] >= from then
                out[#out + 1] = { t = smp[1], low = smp[2], qty = smp[3], depth = smp[4] }
            end
        end
        -- the open day's record is replaced by its scans
        if #out > base and out[base] and out[base].daily and math.floor(out[base].t / 86400) == e.o[1] then
            table.remove(out, base)
        end
    end
    return out
end

-- Summary for the header: last point, price 24 h ago, scans today.
function H.Summary(id)
    local e = P.Entry(id)
    if not e then return nil end
    local now = time()
    local today = math.floor(now / 86400)
    local last, ago
    local list = {}
    for _, pt in ipairs(Store.Points(e, now - 3 * 86400)) do list[#list + 1] = { pt[1], pt[2], pt[3], pt[4] } end
    if #list == 0 then
        for _, smp in ipairs(Store.Samples(e.o)) do list[#list + 1] = { smp[1], smp[2], nil, smp[3] } end
    end
    for _, p in ipairs(list) do
        if p[2] then last = p end
        if p[2] and p[1] <= now - 86400 then ago = p end
    end
    if not ago then
        for _, d in ipairs(Store.Days(e, today - 7)) do
            if d[1] < today and d[D.low] then ago = { d[1] * 86400 + 43200, d[D.usual] or d[D.low] } end
        end
    end
    local scansToday = (e.o and e.o[1] == today) and #Store.Samples(e.o) or 0
    return { t = last and last[1] or e.t, low = last and last[2] or e.cur, mkt = last and last[3],
        qty = last and last[4] or e.qty, ago = ago and ago[2], today = scansToday }
end

-- ------------------------------------------------------------ window
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

-- Taken from the price card (v0.24.0): differences in %, AH scarcity, price at a given time.
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

    -- Header
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

    -- Key numbers (from the price card): difference to vendor or usual price, 4 days, 1st scan, supply.
    f.tiles = {}
    for i = 1, 4 do
        local t = Tile(f)
        t:SetSize(92, 46)
        t:SetPoint("TOPRIGHT", -40 - (4 - i) * 98, -18)
        f.tiles[i] = t
    end

    -- Legend
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

    -- Chart area: prices on top, bars at the bottom.
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
    -- Reading the fluctuations: usual price, range, volatility, sales, verdict.
    f.stats = T.Text(f, 12, { color = C.muted }); f.stats:SetPoint("BOTTOMLEFT", 20, 50)
    f.stats:SetWidth(660); f.stats:SetWordWrap(false)
    f.empty = T.Text(f, 13, { color = C.muted, justify = "CENTER", wrap = true })
    f.empty:SetPoint("CENTER", plot, "CENTER"); f.empty:SetWidth(420)
    f.tag = CreateFrame("Frame", nil, f); f.tag:SetSize(56, 16)
    f.tagBg = T.Rounded(f.tag, C.gold, 4, "BACKGROUND")
    f.tagTx = T.Text(f.tag, 10, { bold = true, justify = "CENTER", color = { 0.08, 0.07, 0.05, 1 } })
    f.tagTx:SetPoint("CENTER")

    -- Hover: vertical line + tooltip of the nearest scan.
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
        local when = pt.weekly and (Tr("Week of %s")):format(date("%d/%m/%Y", math.floor(pt.t - 3.5 * 86400)))
            or date(pt.daily and "%d/%m/%Y" or "%d/%m %H:%M", math.floor(pt.t))
        GameTooltip:AddLine(when, 0.75, 0.72, 0.66)
        local function M(v) return v and ns.FormatMoney(v, { iconSize = 11 }) or "—" end
        GameTooltip:AddDoubleLine(Tr("Lowest listing"), M(pt.low), C.gold[1], C.gold[2], C.gold[3], 1, 1, 1)
        GameTooltip:AddDoubleLine(Tr("Market price"), M(pt.mkt), BLUE[1], BLUE[2], BLUE[3], 1, 1, 1)
        if pt.usual and pt.daily then
            GameTooltip:AddDoubleLine(Tr("Usual price"), M(pt.usual), 0.93, 0.90, 0.84, 1, 1, 1)
        end
        if pt.high and pt.daily and pt.high ~= pt.low then
            GameTooltip:AddDoubleLine(Tr("Highest lowest listing"), M(pt.high), 0.7, 0.7, 0.7, 1, 1, 1)
        end
        local function Count(v) return v and tostring(math.floor(v + 0.5)) or "—" end
        GameTooltip:AddDoubleLine(Tr("Listed"), Count(pt.qty), 0.7, 0.7, 0.7, 1, 1, 1)
        if pt.depth then
            GameTooltip:AddDoubleLine(Tr("Within 10% of the lowest"), Count(pt.depth), 0.7, 0.7, 0.7, 1, 1, 1)
        end
        if pt.weekly then
            GameTooltip:AddDoubleLine(Tr("Sold per day (estimate)"), Count(pt.sold), C.pos[1], C.pos[2], C.pos[3], 1, 1, 1)
        else
            GameTooltip:AddDoubleLine(Tr("Units gone"), Count(pt.gone), C.pos[1], C.pos[2], C.pos[3], 1, 1, 1)
            GameTooltip:AddDoubleLine(Tr("Units listed"), Count(pt.new), PINK[1], PINK[2], PINK[3], 1, 1, 1)
        end
        if pt.daily and pt.scans then
            GameTooltip:AddLine((Tr("%d scans that day")):format(pt.scans), 0.6, 0.6, 0.6)
            if not pt.weekly and pt.scans < 2 then GameTooltip:AddLine(Tr("Only one scan: units gone unknown"), 0.6, 0.6, 0.6) end
        end
        GameTooltip:Show()
    end)

    -- Periods
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
    -- Reference lines (vendor price, usual): only if they stay close to the curve.
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

    -- Grid + prices on the right
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
    -- Dates at the bottom (5)
    local fmt = (t1 - t0) <= 86400 * 1.5 and "%H:%M" or "%d/%m"
    for i = 1, 5 do
        local t = t0 + (t1 - t0) * (i - 1) / 4
        local l = Pool(f.xlabels, i, function() return T.Text(f, 10, { color = C.faint, justify = "CENTER" }) end)
        l:ClearAllPoints()
        l:SetPoint(i == 1 and "TOPLEFT" or i == 5 and "TOPRIGHT" or "TOP", barsF, "BOTTOMLEFT", X(t), -5)
        l:SetText(date(fmt, math.floor(t)))
    end

    -- Usual price band (low–high) and dotted reference lines (from the price card).
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

    -- Curves: one point per scan, joined to the next scan when both have a value.
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

    -- Bars: gone (green) and added (pink), side by side under each scan.
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

    -- Label of the last lowest price, on the axis.
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
    -- Key numbers.
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

-- Opens the window on an item (or switches item if it is already open).
function H.Show(id)
    if not id then return end
    H.frame = H.frame or Build()
    H.id = id
    if not ns.GetItemInfo(id) then ns.RequestItem(id) end
    H.frame:Show()
    H.frame:Raise()
    H.Refresh()
end

-- /ipg item <link | id | name>
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
-- Automatic tracking of opened items (tried then removed): erase what it may have left.
ns.On("DB_READY", function() if ns.db then ns.db.histTrack = nil end end)

