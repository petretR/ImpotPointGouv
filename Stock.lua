-- ImpotPointGouv : onglet Stock. Tout ce que vous possédez (sacs, banques, courrier, en vente,
-- en route, bataillon), tous personnages, avec sa valeur : HV nette (après la commission de 5 %)
-- ou prix marchand, le meilleur des deux. Les objets liés ne valent que le prix marchand.
local _, ns = ...
local Tr = ns.L
local T, P, I = ns.Theme, ns.Prices, ns.Inventory
local C = T.C
local S = {}
ns.Stock = S

-- Valeur d'une unité : prix, source ("ah" | "vendor"), ou nil si aucun prix connu.
function S.Unit(id)
    local vs = P.VendorSell(id) or 0
    if I.IsBound(id) then
        if vs > 0 then return vs, "vendor" end
        return nil
    end
    local ah = P.AHValue(id)
    local net = ah and math.floor(ah * 0.95) or 0
    if net > 0 and net >= vs then return net, "ah" end
    if vs > 0 then return vs, "vendor" end
    return nil
end

-- Lignes du stock : { id, q (détail), unit, src, total }.
function S.Rows()
    local rows, total, n, unpriced = {}, 0, 0, 0
    for id, q in pairs(I.AllStock()) do
        local unit, src = S.Unit(id)
        local v = unit and unit * q.total or 0
        rows[#rows + 1] = { id = id, q = q, unit = unit, src = src, total = v }
        total = total + v
        n = n + q.total
        if not unit then unpriced = unpriced + 1 end
    end
    return rows, math.floor(total), n, unpriced
end

-- Pour la carte de la page Bilan.
function S.Value()
    local _, total, n = S.Rows()
    return total, n
end

-- ------------------------------------------------------------ page
local ROWS = 14
local FILTERS = { { "all", "All" }, { "ah", "AH value" }, { "vendor", "Vendor value" }, { "none", "No price" } }
local SORTS = {
    name  = function(a, b) return P.Name(a.id) < P.Name(b.id) end,
    qty   = function(a, b) if a.q.total ~= b.q.total then return a.q.total > b.q.total end return a.total > b.total end,
    unit  = function(a, b) if (a.unit or -1) ~= (b.unit or -1) then return (a.unit or -1) > (b.unit or -1) end return a.total > b.total end,
    total = function(a, b) if a.total ~= b.total then return a.total > b.total end return P.Name(a.id) < P.Name(b.id) end,
}

local function Where(q)
    local parts = {}
    local function Add(n, label) if n > 0 then parts[#parts + 1] = ("%s %d"):format(Tr(label), n) end end
    Add(q.bags, "bags"); Add(q.bank, "bank"); Add(q.warband, "warband"); Add(q.mail, "mail")
    Add(q.listed, "AH"); Add(q.transit, "in transit")
    return table.concat(parts, "  ·  ")
end

function S.BuildPage(page)
    local title = T.Text(page, 20, { bold = true, text = Tr("Stock") })
    title:SetPoint("TOPLEFT", 0, -2)
    page.sub = T.Text(page, 11, { color = C.muted })
    page.sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    page.filter = ns.db.settings.stockFilter or "all"
    page.sort = ns.db.settings.stockSort or "total"
    page.offset = 0
    page.fb = {}
    local prev
    for i = #FILTERS, 1, -1 do
        local d = FILTERS[i]
        local b = T.Button(page, Tr(d[2]), 92, 26, function()
            page.filter = d[1]; ns.db.settings.stockFilter = d[1]; page.offset = 0; page:Refresh()
        end, "pill")
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", 0, 0) end
        prev = b
        page.fb[d[1]] = b
    end
    page.fb.none.tooltip = Tr("Items with no AH price and no vendor price: scan the AH, or the game has not loaded them yet.")

    local list = CreateFrame("Frame", nil, page)
    T.Surface(list, C.surface, 10)
    list:SetPoint("TOPLEFT", 0, -46); list:SetPoint("BOTTOMRIGHT", 0, 0)
    -- En-têtes cliquables pour trier.
    local heads = {
        { "Item", "LEFT", 44, "name" }, { "Where", "LEFT", 330 }, { "Qty", "RIGHT", -330, "qty" },
        { "Unit value", "RIGHT", -210, "unit" }, { "Total", "RIGHT", -20, "total" },
    }
    page.heads = {}
    for _, h in ipairs(heads) do
        local b = CreateFrame("Button", nil, list)
        b:SetSize(110, 18)
        b:SetPoint("TOP" .. h[2], h[3], -7)
        b.text = T.Text(b, 10, { bold = true, color = C.faint, text = Tr(h[1]), justify = h[2] })
        b.text:SetPoint(h[2], 0, 0)
        b.key = h[4]
        b.label = Tr(h[1])
        if h[4] then
            b:SetScript("OnClick", function()
                page.sort = h[4]; ns.db.settings.stockSort = h[4]; page.offset = 0; page:Refresh()
            end)
            b:SetScript("OnEnter", function(self) self.text:SetTextColor(unpack(C.text)) end)
            b:SetScript("OnLeave", function(self) page:Heads() end)
        end
        page.heads[#page.heads + 1] = b
    end
    function page:Heads()
        for _, b in ipairs(self.heads) do
            local on = b.key and b.key == self.sort
            b.text:SetText(b.label .. (on and " ▼" or ""))
            b.text:SetTextColor(unpack(on and C.gold or C.faint))
        end
    end

    page.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Frame", nil, list)
        r:SetHeight(28)
        r:SetPoint("TOPLEFT", 8, -28 - (i - 1) * 28); r:SetPoint("TOPRIGHT", -8, -28 - (i - 1) * 28)
        r:EnableMouse(true)
        r.hl = T.Rounded(r, { 1, 1, 1, 0 }, 6, "BACKGROUND")
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(20, 20); r.icon:SetPoint("LEFT", 8, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.name = T.Text(r, 12); r.name:SetPoint("LEFT", 36, 0); r.name:SetWidth(280); r.name:SetWordWrap(false)
        r.where = T.Text(r, 11, { color = C.faint }); r.where:SetPoint("LEFT", 322, 0); r.where:SetWidth(200); r.where:SetWordWrap(false)
        r.qty = T.Text(r, 12, { justify = "RIGHT" }); r.qty:SetPoint("RIGHT", -322, 0)
        r.unit = T.Text(r, 12, { justify = "RIGHT", color = C.muted }); r.unit:SetPoint("RIGHT", -202, 0)
        r.src = T.Text(r, 10, { bold = true }); r.src:SetPoint("LEFT", r, "RIGHT", -192, 0)
        r.total = T.Text(r, 13, { bold = true, justify = "RIGHT" }); r.total:SetPoint("RIGHT", -12, 0)
        r:SetScript("OnEnter", function(self)
            self.hl:SetColor({ 1, 1, 1, 0.04 })
            local row = self.row
            if not row then return end
            T.ItemTooltip(self, row.id)
            GameTooltip:AddLine(" ")
            local chars, listed, transit, warband = I.Breakdown(row.id)
            for _, c in ipairs(chars) do
                local parts = {}
                if c[2] > 0 then parts[#parts + 1] = Tr("bags") .. " " .. c[2] end
                if c[3] > 0 then parts[#parts + 1] = Tr("bank") .. " " .. c[3] end
                if c[4] > 0 then parts[#parts + 1] = Tr("mail") .. " " .. c[4] end
                GameTooltip:AddDoubleLine(c[1], table.concat(parts, ", "), 0.8, 0.8, 0.8, 1, 1, 1)
            end
            if warband > 0 then GameTooltip:AddDoubleLine(Tr("Warband bank"), tostring(warband), 0.8, 0.8, 0.8, 1, 1, 1) end
            if listed > 0 then GameTooltip:AddDoubleLine(Tr("Listed at the AH"), tostring(listed), 0.8, 0.8, 0.8, 1, 1, 1) end
            if transit > 0 then GameTooltip:AddDoubleLine(Tr("In the mail to your characters"), tostring(transit), 0.8, 0.8, 0.8, 1, 1, 1) end
            GameTooltip:AddLine(" ")
            local ah, vs = P.AHValue(row.id), P.VendorSell(row.id)
            if ah then GameTooltip:AddDoubleLine(Tr("AH (after the 5 % cut)"), ns.FormatMoney(math.floor(ah * 0.95), { iconSize = 11 }), 0.7, 0.7, 0.7, 1, 1, 1) end
            if vs then GameTooltip:AddDoubleLine(Tr("Vendor"), ns.FormatMoney(vs, { iconSize = 11 }), 0.7, 0.7, 0.7, 1, 1, 1) end
            if I.IsBound(row.id) then GameTooltip:AddLine(Tr("Soulbound: vendor value only"), 0.6, 0.6, 0.6) end
            GameTooltip:AddLine(Tr("Click: price history"), 0.88, 0.66, 0.24)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function(self) self.hl:SetColor({ 1, 1, 1, 0 }); GameTooltip:Hide() end)
        -- Clic : historique des prix ; Maj-clic : lien dans la discussion.
        r:SetScript("OnMouseUp", function(self, button)
            local row = self.row
            if not row or button ~= "LeftButton" then return end
            if IsModifiedClick and IsModifiedClick("CHATLINK") then
                local _, link = ns.GetItemInfo(row.id)
                if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
            elseif ns.History then
                ns.History.Show(row.id)
            end
        end)
        page.rows[i] = r
    end
    page.empty = T.Text(list, 12, { color = C.muted, justify = "CENTER", wrap = true })
    page.empty:SetPoint("CENTER"); page.empty:SetWidth(520)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, d)
        page.offset = math.max(0, math.min(math.max(0, #(page.data or {}) - ROWS), page.offset - d * 3))
        page:Draw()
    end)

    local function Money(v, size) return ns.FormatMoney(v, { iconSize = size or 11, short = true }) end
    function page:Draw()
        local data = self.data or {}
        for i, r in ipairs(self.rows) do
            local row = data[self.offset + i]
            r.row = row
            if row then
                if not ns.GetItemInfo(row.id) then ns.RequestItem(row.id) end
                r.icon:SetTexture(ns.GetItemIcon(row.id) or "Interface\\Icons\\INV_Misc_QuestionMark")
                local _, _, quality = ns.GetItemInfo(row.id)
                local qc = ITEM_QUALITY_COLORS and quality and ITEM_QUALITY_COLORS[quality]
                r.name:SetText(P.Name(row.id))
                if qc then r.name:SetTextColor(qc.r, qc.g, qc.b) else r.name:SetTextColor(unpack(C.text)) end
                r.where:SetText(Where(row.q))
                r.qty:SetText(tostring(row.q.total))
                r.unit:SetText(row.unit and Money(row.unit) or "|cff615f5c—|r")
                if row.src == "ah" then r.src:SetText(Tr("AH")); r.src:SetTextColor(unpack(C.gold))
                elseif row.src == "vendor" then r.src:SetText(Tr("Vendor")); r.src:SetTextColor(0.45, 0.68, 0.95)
                else r.src:SetText("") end
                r.total:SetText(row.unit and Money(row.total, 12) or "|cff615f5c—|r")
                r:Show()
            else
                r:Hide()
            end
        end
    end

    function page:Refresh()
        for k, b in pairs(self.fb) do b:SetSelected(k == self.filter) end
        self:Heads()
        local rows, total, n, unpriced = S.Rows()
        local data = {}
        for _, row in ipairs(rows) do
            local f = self.filter
            if f == "all" or (f == "none" and not row.unit) or (row.src == f) then data[#data + 1] = row end
        end
        table.sort(data, SORTS[self.sort] or SORTS.total)
        self.data = data
        self.offset = math.min(self.offset, math.max(0, #data - ROWS))
        local sub = (Tr("%d items  ·  %d kinds  ·  worth %s")):format(n, #rows, Money(total))
        if unpriced > 0 then sub = sub .. (Tr("  ·  %d without a price")):format(unpriced) end
        self.sub:SetText(sub)
        self.empty:SetText(#rows == 0 and Tr("Nothing recorded yet: open your bags and your bank on each character.")
            or Tr("Nothing here."))
        self.empty:SetShown(#data == 0)
        self:Draw()
    end
end

-- Noms et prix marchands qui arrivent après coup : redessine la page.
local pend
local ev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(ev, "Stock") end
pcall(ev.RegisterEvent, ev, "GET_ITEM_INFO_RECEIVED")
local lastDraw = 0
ev:SetScript("OnEvent", function(_, _, id, success)
    -- Objet inexistant, ou pas demandé par l'addon : rien à redessiner.
    if success == false or pend or not ns.ItemWanted(id) then return end
    pend = true
    C_Timer.After(math.max(0.6, 2 - (GetTime() - lastDraw)), function()
        pend = false
        lastDraw = GetTime()
        local f = _G.ImpotPointGouvFrame
        if f and f:IsShown() and ns.UI.Current and ns.UI.Current() == "stock" then ns.UI.Refresh() end
    end)
end)
ns.On("INVENTORY_CHANGED", function()
    if ns.UI.Current and ns.UI.Current() == "stock" then ns.UI.Refresh() end
end)
