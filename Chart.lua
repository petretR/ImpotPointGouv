-- ImpotPointGouv: line + area chart, "bank account" style.
local _, ns = ...
local T = ns.Theme
local Chart = {}
ns.Chart = Chart

local function NiceStep(range, ticks)
    if range <= 0 then return 1 end
    local raw = range / ticks
    local mag = 10 ^ math.floor(math.log10(raw))
    local norm = raw / mag
    local nice = norm < 1.5 and 1 or norm < 3 and 2 or norm < 7 and 5 or 10
    return nice * mag
end

function Chart.Create(parent)
    local c = CreateFrame("Frame", nil, parent)
    c.lines, c.bars, c.grids, c.ylabels, c.xlabels = {}, {}, {}, {}, {}
    c.color = T.C.gold
    c.lastDot, c.lastRing = false, false
    c.refTex, c.refLabels, c.lastLabel = {}, {}, false

    c.plot = CreateFrame("Frame", nil, c)
    c.plot:SetPoint("TOPLEFT", 58, -8)
    c.plot:SetPoint("BOTTOMRIGHT", -10, 24)
    if c.plot.SetClipsChildren then c.plot:SetClipsChildren(true) end

    c.empty = T.Text(c, 13, { color = T.C.muted, justify = "CENTER", wrap = true })
    c.empty:SetPoint("CENTER", c.plot, "CENTER")
    c.empty:SetWidth(360)

    -- Hover: vertical line + dot + tooltip.
    c.cross = c.plot:CreateTexture(nil, "OVERLAY")
    c.cross:SetTexture(T.WHITE); c.cross:SetVertexColor(1, 1, 1, 0.18); c.cross:SetWidth(1)
    c.cross:Hide()
    c.dot = c.plot:CreateTexture(nil, "OVERLAY", nil, 2)
    c.dot:SetTexture(T.CIRCLE); c.dot:SetSize(9, 9); c.dot:Hide()
    c.dotRing = c.plot:CreateTexture(nil, "OVERLAY", nil, 1)
    c.dotRing:SetTexture(T.CIRCLE); c.dotRing:SetSize(17, 17); c.dotRing:Hide()

    c.plot:EnableMouse(true)
    c.plot:SetScript("OnEnter", function() c.hovering = true end)
    c.plot:SetScript("OnLeave", function()
        c.hovering = false
        c.cross:Hide(); c.dot:Hide(); c.dotRing:Hide()
        GameTooltip:Hide()
    end)
    c.plot:SetScript("OnUpdate", function()
        if not c.hovering or not c.coords or #c.coords < 2 then return end
        local scale = c.plot:GetEffectiveScale()
        local x = GetCursorPosition() / scale - c.plot:GetLeft()
        local best, bi = math.huge, 1
        for i, p in ipairs(c.coords) do
            local d = math.abs(p.x - x)
            if d < best then best, bi = d, i end
        end
        if bi == c.hoverIndex and GameTooltip:IsOwned(c.plot) then return end
        c.hoverIndex = bi
        local p = c.coords[bi]
        c.cross:ClearAllPoints()
        c.cross:SetPoint("TOP", c.plot, "TOPLEFT", p.x, 0)
        c.cross:SetPoint("BOTTOM", c.plot, "BOTTOMLEFT", p.x, 0)
        c.cross:Show()
        c.dot:ClearAllPoints(); c.dot:SetPoint("CENTER", c.plot, "BOTTOMLEFT", p.x, p.y); c.dot:Show()
        c.dotRing:ClearAllPoints(); c.dotRing:SetPoint("CENTER", c.plot, "BOTTOMLEFT", p.x, p.y); c.dotRing:Show()
        GameTooltip:SetOwner(c.plot, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        local right = p.x > c.plot:GetWidth() * 0.6
        GameTooltip:SetPoint(right and "BOTTOMRIGHT" or "BOTTOMLEFT", c.plot, "BOTTOMLEFT",
            p.x + (right and -14 or 14), math.min(p.y + 14, c.plot:GetHeight() - 40))
        GameTooltip:AddLine(date(c.span <= 86400 * 1.5 and "%d/%m %H:%M" or "%d/%m/%Y", p.t), 0.75, 0.72, 0.66)
        GameTooltip:AddLine(ns.FormatMoney(p.v, { iconSize = 12 }), 1, 1, 1)
        if c.tooltipExtra then c.tooltipExtra(GameTooltip, bi, p) end
        GameTooltip:Show()
    end)
    c.SetData = Chart.SetData
    return c
end

local function Pool(list, i, create)
    local o = list[i]
    if not o then o = create(); list[i] = o end
    o:Show()
    return o
end

local function HideFrom(list, n) for i = n, #list do list[i]:Hide() end end

-- points = { {t, v}, ... } ; opts.color, opts.zeroLine, opts.emptyText
function Chart.SetData(c, points, opts)
    opts = opts or {}
    local color = opts.color or T.C.gold
    c.coords = {}
    c.hoverIndex = nil
    local plot = c.plot
    local W, H = plot:GetWidth(), plot:GetHeight()
    local n = points and #points or 0
    local flat = true
    for i = 2, n do if points[i][2] ~= points[1][2] then flat = false; break end end
    if n < 2 or W <= 0 or (opts.hideFlat and flat) then
        HideFrom(c.lines, 1); HideFrom(c.bars, 1); HideFrom(c.grids, 1)
        HideFrom(c.ylabels, 1); HideFrom(c.xlabels, 1)
        c.empty:SetText(opts.emptyText or "No data yet.")
        c.empty:Show()
        if c.lastDot then c.lastDot:Hide(); c.lastRing:Hide() end
        if c.refTex then HideFrom(c.refTex, 1) end
        if c.refLabels then HideFrom(c.refLabels, 1) end
        if c.lastLabel then c.lastLabel:Hide() end
        return
    end
    c.empty:Hide()

    local vmin, vmax = math.huge, -math.huge
    for _, p in ipairs(points) do
        if p[2] < vmin then vmin = p[2] end
        if p[2] > vmax then vmax = p[2] end
    end
    if opts.zeroLine then vmin = math.min(vmin, 0); vmax = math.max(vmax, 0) end
    -- Reference lines (vendor price, usual price): shown when they stay close to the curve.
    for _, ref in ipairs(opts.refs or {}) do
        if ref.v and ref.v > 0 and ref.v <= vmax * 1.6 then vmin = math.min(vmin, ref.v); vmax = math.max(vmax, ref.v) end
    end
    if vmax == vmin then vmax = vmax + 10000; vmin = math.max(opts.zeroLine and vmin or 0, vmin - 10000) end
    local step = NiceStep(vmax - vmin, 4)
    local lo = math.floor(vmin / step) * step
    local hi = math.ceil(vmax / step) * step
    if hi == lo then hi = lo + step end
    local function Y(v) return (v - lo) / (hi - lo) * (H - 6) + 3 end
    local t0, t1 = points[1][1], points[n][1]
    c.span = t1 - t0
    local function X(t) return (t - t0) / math.max(1, t1 - t0) * W end

    -- Grid + Y labels
    local gi = 0
    for v = lo, hi + step * 0.5, step do
        gi = gi + 1
        local g = Pool(c.grids, gi, function()
            local tx = plot:CreateTexture(nil, "BACKGROUND", nil, 1)
            tx:SetTexture(T.WHITE); tx:SetHeight(1)
            return tx
        end)
        local isZero = opts.zeroLine and math.abs(v) < step * 0.01
        g:SetVertexColor(1, 1, 1, isZero and 0.16 or 0.035)
        g:ClearAllPoints()
        g:SetPoint("LEFT", plot, "BOTTOMLEFT", 0, Y(v))
        g:SetPoint("RIGHT", plot, "BOTTOMRIGHT", 0, Y(v))
        local lbl = Pool(c.ylabels, gi, function() return T.Text(c, 10, { color = T.C.faint, justify = "RIGHT" }) end)
        lbl:ClearAllPoints()
        lbl:SetPoint("RIGHT", plot, "BOTTOMLEFT", -8, Y(v))
        lbl:SetText(ns.FormatMoneyAxis(v))
    end
    HideFrom(c.grids, gi + 1); HideFrom(c.ylabels, gi + 1)

    -- X labels (5)
    local fmt = c.span <= 86400 * 1.5 and "%H:%M" or "%d/%m"
    for i = 1, 5 do
        local t = t0 + (t1 - t0) * (i - 1) / 4
        local lbl = Pool(c.xlabels, i, function() return T.Text(c, 10, { color = T.C.faint, justify = "CENTER" }) end)
        lbl:ClearAllPoints()
        local anchor = i == 1 and "TOPLEFT" or i == 5 and "TOPRIGHT" or "TOP"
        lbl:SetPoint(anchor, plot, "BOTTOMLEFT", X(t), -7)
        lbl:SetText(date(fmt, t))
    end

    -- "Finary" style: smoothed curve, area gradient fading downwards, dot on the last value.
    local base = opts.zeroLine and Y(0) or 0
    for i = 1, n do
        c.coords[i] = { x = X(points[i][1]), y = Y(points[i][2]), t = points[i][1], v = points[i][2] }
    end
    -- Resample every 2 px (linear interpolation between points).
    local STEP = 2
    local samples, j = {}, 1
    for x = 0, W, STEP do
        while j < n - 1 and c.coords[j + 1].x < x do j = j + 1 end
        local a, b = c.coords[j], c.coords[math.min(n, j + 1)]
        local f = (b.x > a.x) and math.max(0, math.min(1, (x - a.x) / (b.x - a.x))) or 0
        samples[#samples + 1] = { x = x, y = a.y + (b.y - a.y) * f, v = a.v + (b.v - a.v) * f }
    end
    -- Light smoothing (moving average) to soften the steps.
    local smooth = {}
    for i = 1, #samples do
        local sum, k = 0, 0
        for d = -2, 2 do
            local p = samples[i + d]
            if p then sum = sum + p.y; k = k + 1 end
        end
        smooth[i] = { x = samples[i].x, y = sum / k, v = samples[i].v }
    end
    local hasGradient = (CreateColor ~= nil)
    for i = 1, #smooth - 1 do
        local p, q = smooth[i], smooth[i + 1]
        local col = Pool(c.bars, i, function()
            local tx = plot:CreateTexture(nil, "BORDER")
            tx:SetTexture(T.WHITE)
            return tx
        end)
        local top = (p.y + q.y) / 2
        local y1, y2 = math.min(base, top), math.max(base, top)
        col:ClearAllPoints()
        col:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", p.x, y1)
        col:SetSize(STEP + 0.5, math.max(1, y2 - y1))
        local above = top >= base
        local r, g, bl = color[1], color[2], color[3]
        if opts.zeroLine and not above then r, g, bl = T.C.neg[1], T.C.neg[2], T.C.neg[3] end
        -- No SetVertexColor after SetGradient: it would erase the gradient (white area).
        local ok = hasGradient and col.SetGradient and pcall(col.SetGradient, col, "VERTICAL",
            CreateColor(r, g, bl, above and 0 or 0.26), CreateColor(r, g, bl, above and 0.26 or 0))
        if not ok then col:SetVertexColor(r, g, bl, 0.12) end
    end
    HideFrom(c.bars, #smooth)
    -- Curve: soft glow + sharp line.
    local li = 0
    for i = 1, #smooth - 1, 2 do
        local p, q = smooth[i], smooth[math.min(#smooth, i + 2)]
        local lr, lg, lb = color[1], color[2], color[3]
        if opts.zeroLine and (p.v + q.v) < 0 then lr, lg, lb = T.C.neg[1], T.C.neg[2], T.C.neg[3] end
        li = li + 1
        local glow = Pool(c.lines, li, function()
            local l = plot:CreateLine(nil, "ARTWORK", nil, 1)
            l:SetTexture(T.WHITE)
            return l
        end)
        glow:SetThickness(6); glow:SetVertexColor(lr, lg, lb, 0.12)
        glow:SetStartPoint("BOTTOMLEFT", plot, p.x, p.y); glow:SetEndPoint("BOTTOMLEFT", plot, q.x, q.y)
        li = li + 1
        local line = Pool(c.lines, li, function()
            local l = plot:CreateLine(nil, "ARTWORK", nil, 2)
            l:SetTexture(T.WHITE)
            return l
        end)
        line:SetThickness(2.2); line:SetVertexColor(lr, lg, lb, 1)
        line:SetStartPoint("BOTTOMLEFT", plot, p.x, p.y); line:SetEndPoint("BOTTOMLEFT", plot, q.x, q.y)
    end
    HideFrom(c.lines, li + 1)
    -- Usual price band (low–high) and dotted reference lines.
    local ri = 0
    local function Tex(layer, sub)
        ri = ri + 1
        return Pool(c.refTex, ri, function() local tx = plot:CreateTexture(nil, layer or "BORDER", nil, sub or 2); tx:SetTexture(T.WHITE); return tx end)
    end
    if opts.band and opts.band[1] and opts.band[2] and opts.band[2] > opts.band[1] then
        local y1, y2 = math.max(0, Y(opts.band[1])), math.min(H, Y(opts.band[2]))
        if y2 > y1 then
            local b = Tex("BACKGROUND", 2)
            b:ClearAllPoints(); b:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y1); b:SetSize(W, y2 - y1)
            b:SetVertexColor(1, 1, 1, 0.035)
        end
    end
    local rl = 0
    for _, ref in ipairs(opts.refs or {}) do
        local y = ref.v and Y(ref.v)
        if y and y >= 0 and y <= H then
            local col = ref.color or { 1, 1, 1 }
            for x = 0, W, 9 do
                local d = Tex("ARTWORK", 0)
                d:ClearAllPoints(); d:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x, y); d:SetSize(5, 1)
                d:SetVertexColor(col[1], col[2], col[3], ref.alpha or 0.35)
            end
            if ref.label then
                rl = rl + 1
                local lbl = Pool(c.refLabels, rl, function() return T.Text(c, 10, { color = T.C.faint }) end)
                lbl:ClearAllPoints(); lbl:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 4, y + 2)
                lbl:SetText(ref.label); lbl:SetTextColor(col[1], col[2], col[3], 0.8)
            end
        end
    end
    HideFrom(c.refTex, ri + 1)
    HideFrom(c.refLabels, rl + 1)
    -- Dot on the current value.
    if not c.lastDot then
        c.lastDot = plot:CreateTexture(nil, "OVERLAY", nil, 3); c.lastDot:SetTexture(T.CIRCLE); c.lastDot:SetSize(8, 8)
        c.lastRing = plot:CreateTexture(nil, "OVERLAY", nil, 2); c.lastRing:SetTexture(T.CIRCLE); c.lastRing:SetSize(18, 18)
    end
    local last = c.coords[n]
    c.lastDot:ClearAllPoints(); c.lastDot:SetPoint("CENTER", plot, "BOTTOMLEFT", last.x - 1, last.y)
    c.lastRing:ClearAllPoints(); c.lastRing:SetPoint("CENTER", plot, "BOTTOMLEFT", last.x - 1, last.y)
    c.lastDot:SetVertexColor(color[1], color[2], color[3], 1); c.lastRing:SetVertexColor(color[1], color[2], color[3], 0.22)
    c.lastDot:Show(); c.lastRing:Show()
    if opts.lastLabel then
        if not c.lastLabel then c.lastLabel = T.Text(c, 11, { bold = true, justify = "RIGHT" }) end
        c.lastLabel:ClearAllPoints()
        local above = last.y < H - 24
        c.lastLabel:SetPoint(above and "BOTTOMRIGHT" or "TOPRIGHT", plot, "BOTTOMLEFT", last.x - 8, last.y + (above and 8 or -8))
        c.lastLabel:SetText(opts.lastLabel); c.lastLabel:Show()
    elseif c.lastLabel then c.lastLabel:Hide() end

    c.dot:SetVertexColor(color[1], color[2], color[3], 1)
    c.dotRing:SetVertexColor(color[1], color[2], color[3], 0.25)
end
