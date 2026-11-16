-- ImpotPointGouv : onglet "Lists" de la fenêtre principale.
-- À gauche : les listes (avec le nombre d'affaires). À droite : les objets de la liste choisie,
-- prix actuel / habituel, courbe 7 jours, ventes estimées, stock, verdict et achat des affaires.
local _, ns = ...
local Tr = ns.L
local T, P, LS = ns.Theme, ns.Prices, ns.Lists
local C = T.C
local LU = {}
ns.ListsUI = LU

local ROWS = 14
local ROW_H = 26
local SIDE_W = 214

local VERDICT = {
    buy  = { "BUY",  { 0.361, 0.820, 0.451, 1 } },
    sell = { "SELL", { 0.878, 0.659, 0.239, 1 } },
    farm = { "FARM", { 0.45, 0.68, 0.95, 1 } },
}

local function Money(v) return v and ns.FormatMoney(v, { iconSize = 11, short = true }) or "|cff615f5c—|r" end
local function AHOpen() return AuctionHouseFrame and AuctionHouseFrame:IsShown() end

-- ------------------------------------------------------------ petit menu contextuel
local pop
local function Popup(anchor, entries)
    if not pop then
        pop = CreateFrame("Frame", "ImpotPointGouvListMenu", UIParent)
        pop:SetFrameStrata("DIALOG"); pop:SetClampedToScreen(true); pop:EnableMouse(true)
        T.Surface(pop, C.window, 10, { 1, 1, 1, 0.12 })
        pop.btns = {}
        local away = 0
        pop:SetScript("OnUpdate", function(self, el)
            if self:IsMouseOver(8, -8, -8, 8) then away = 0 else away = away + el end
            if away > 1.2 then self:Hide() end
        end)
        tinsert(UISpecialFrames, "ImpotPointGouvListMenu")
    end
    for _, b in ipairs(pop.btns) do b:Hide() end
    for i, e in ipairs(entries) do
        local b = pop.btns[i]
        if not b then
            b = CreateFrame("Button", nil, pop)
            b:SetHeight(24)
            b.hl = T.Rounded(b, { 1, 1, 1, 0 }, 6, "BACKGROUND")
            b.t = T.Text(b, 12); b.t:SetPoint("LEFT", 10, 0)
            b:SetScript("OnEnter", function(self) self.hl:SetColor({ C.gold[1], C.gold[2], C.gold[3], 0.18 }) end)
            b:SetScript("OnLeave", function(self) self.hl:SetColor({ 1, 1, 1, 0 }) end)
            pop.btns[i] = b
        end
        b:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 26); b:SetPoint("TOPRIGHT", -8, -8 - (i - 1) * 26)
        b.t:SetText(e[1]); b.t:SetTextColor(unpack(e.color or C.text))
        b:SetScript("OnClick", function() pop:Hide(); if e[2] then e[2]() end end)
        b:Show()
    end
    pop:SetSize(240, 16 + #entries * 26)
    pop:ClearAllPoints()
    local x, y = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    pop:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s, y / s)
    pop:Show()
end

StaticPopupDialogs["IMPOTPOINTGOUV_NEWLIST"] = {
    text = Tr("Name of the new list:"), button1 = OKAY or "OK", button2 = CANCEL or "Cancel",
    hasEditBox = true, maxLetters = 40, timeout = 0, whileDead = true, hideOnEscape = true,
    OnAccept = function(self, data)
        local eb = self.editBox or self.EditBox
        local name = eb and eb:GetText()
        if not name or name:match("^%s*$") then name = nil end
        local i = LS.NewCustom(name)
        if data and data.id then LS.AddToCustom(i, data.id) end
        LU.select = "my_" .. i
        if ns.UI then ns.UI.Refresh() end
    end,
    EditBoxOnEnterPressed = function(self)
        local p = self:GetParent()
        StaticPopupDialogs["IMPOTPOINTGOUV_NEWLIST"].OnAccept(p, p.data)
        p:Hide()
    end,
}

local function AddToListMenu(id)
    local entries = {}
    for i, cl in ipairs(ns.db.lists or {}) do
        entries[#entries + 1] = { Tr("Add to ") .. cl.name, function() LS.AddToCustom(i, id); ns.UI.Refresh() end }
    end
    entries[#entries + 1] = { "Add to a new list…", function() StaticPopup_Show("IMPOTPOINTGOUV_NEWLIST", nil, nil, { id = id }) end, color = C.gold }
    return entries
end

-- ------------------------------------------------------------ page
function LU.BuildPage(page)
    page.offset, page.sideOffset = 0, 0
    page.role = ns.db.settings.listRole or "all"
    page.kind = ns.db.settings.listKind or "all"
    page.dealsOnly = false
    LU.select = LU.select or ns.db.settings.listSelect or "consum"

    -- Colonne de gauche : les listes
    local side = CreateFrame("Frame", nil, page)
    side:SetPoint("TOPLEFT", 0, 0); side:SetPoint("BOTTOMLEFT", 0, 0); side:SetWidth(SIDE_W)
    T.Surface(side, C.surface, 10)
    page.sideBtns = {}
    page.collapsed = ns.db.settings.listCollapsed or { level = true, prebis = true, cd = true }
    ns.db.settings.listCollapsed = page.collapsed
    local SIDE_ROWS = 22
    local HEAD_H, ITEM_H = 30, 26
    page.sideH = 0
    for i = 1, SIDE_ROWS do
        local b = CreateFrame("Button", nil, side)
        b.hl = T.Rounded(b, { 1, 1, 1, 0 }, 6, "BACKGROUND")
        b.t = T.Text(b, 12); b.t:SetWidth(SIDE_W - 52); b.t:SetWordWrap(false)
        b.chev = T.Text(b, 12, { bold = true, color = C.gold, justify = "RIGHT" }); b.chev:SetPoint("RIGHT", -10, 0)
        b.badge = T.Text(b, 11, { bold = true, justify = "RIGHT", color = VERDICT.buy[2] })
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnEnter", function(self)
            if self.item and not self.item.new then self.hl:SetColor({ 1, 1, 1, 0.05 }) end
            if self.item and self.item.list and self.item.list.info then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine(Tr(self.item.list.title), 1, 1, 1)
                GameTooltip:AddLine(self.item.list.info, 0.75, 0.75, 0.75, true); GameTooltip:Show()
            end end)
        b:SetScript("OnLeave", function(self) GameTooltip:Hide(); page:DrawSide() end)
        b:SetScript("OnClick", function(self, button)
            local it = self.item
            if not it then return end
            if it.new then StaticPopup_Show("IMPOTPOINTGOUV_NEWLIST"); return end
            if it.header then
                page.collapsed[it.key] = not page.collapsed[it.key] or nil
                page:Refresh()
                return
            end
            if button == "RightButton" and it.list.custom then
                local idx = it.list.custom
                Popup(self, { { Tr("Delete this list"), function()
                    LS.DeleteCustom(idx); LU.select = "consum"; ns.UI.Refresh() end, color = C.neg } })
                return
            end
            LU.select = it.list.key; ns.db.settings.listSelect = it.list.key
            page.offset = 0
            page:Refresh()
        end)
        page.sideBtns[i] = b
    end
    side:EnableMouseWheel(true)
    side:SetScript("OnMouseWheel", function(_, d)
        page.sideOffset = math.max(0, math.min(math.max(0, #(page.sideItems or {}) - 1), page.sideOffset - d))
        page:DrawSide()
    end)
    page.side = side
    page.HEAD_H, page.ITEM_H = HEAD_H, ITEM_H

    -- En-tête de droite
    local main = CreateFrame("Frame", nil, page)
    main:SetPoint("TOPLEFT", SIDE_W + 12, 0); main:SetPoint("BOTTOMRIGHT", 0, 0)
    page.title = T.Text(main, 18, { bold = true }); page.title:SetPoint("TOPLEFT", 0, -2)
    page.sub = T.Text(main, 11, { color = C.muted }); page.sub:SetPoint("TOPLEFT", page.title, "BOTTOMLEFT", 0, -7)
    page.sub:SetPoint("RIGHT", main, "RIGHT", -230, 0); page.sub:SetWordWrap(false)

    page.scan = T.Button(main, Tr("Scan list"), 100, 26, function()
        local sc = P.Scanning and P.Scanning()
        if sc then P.ScanIds(nil) ; return end
        if not AHOpen() then LU.Msg(Tr("Open the auction house to scan this list.")); return end
        local l = LS.Get(LU.select)
        if l then P.ScanIds(LS.IdsOf(l), l.title) end
    end, "primary")
    page.scan:SetPoint("TOPRIGHT", 0, 0)
    page.scan.tooltip = Tr("Checks the live price and quantity of every item in this list (a few seconds per 20 items). Each scan builds the price history: usual price, volatility, sales.")
    page.export = T.Button(main, Tr("→ Auctionator"), 112, 26, function()
        local l = LS.Get(LU.select)
        if not l then return end
        local ok, n = LS.ExportAuctionator(l)
        LU.Msg(ok and ((Tr("Auctionator shopping list \"IPG - %s\" created (%d items). Buy from the Buy buttons here: they stop at your limit.")):format(l.title, n)) or n)
    end)
    page.export:SetPoint("RIGHT", page.scan, "LEFT", -6, 0)
    page.export.tooltip = Tr("Creates an Auctionator shopping list with these items, to look at prices there. Auctionator buys whatever you click: buy deals from here instead.")

    -- Filtres
    local fy = -44
    page.roleBtns = {}
    local prev
    local roles = { { "all", "All roles" } }
    for _, r in ipairs(LS.ROLES) do roles[#roles + 1] = r end
    for _, r in ipairs(roles) do
        local b = T.Button(main, Tr(r[2]), r[1] == "all" and 72 or 62, 22, function()
            page.role = r[1]; ns.db.settings.listRole = r[1]; page.offset = 0; page:Refresh()
        end, "pill")
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 0, fy) end
        prev = b
        page.roleBtns[r[1]] = b
    end
    page.kindBtns = {}
    local kprev
    for i = 3, 1, -1 do
        local k = ({ { "all", "All" }, { "product", "Crafted" }, { "mat", "Materials" } })[i]
        local b = T.Button(main, Tr(k[2]), k[1] == "mat" and 78 or 64, 22, function()
            page.kind = k[1]; ns.db.settings.listKind = k[1]; page.offset = 0; page:Refresh()
        end, "pill")
        if kprev then b:SetPoint("RIGHT", kprev, "LEFT", -4, 0) else b:SetPoint("TOPRIGHT", 0, fy) end
        kprev = b
        page.kindBtns[k[1]] = b
    end
    page.dealBtn = T.Button(main, Tr("Deals only"), 84, 22, function()
        page.dealsOnly = not page.dealsOnly; page.offset = 0; page:Refresh()
    end, "pill")
    page.dealBtn:SetPoint("RIGHT", kprev, "LEFT", -10, 0)

    -- Tableau
    local list = CreateFrame("Frame", nil, main)
    T.Surface(list, C.surface, 10)
    list:SetPoint("TOPLEFT", 0, -74); list:SetPoint("BOTTOMRIGHT", 0, 0)
    local cols = {
        { "Item", "LEFT", 38 }, { "Now", "RIGHT", -402 }, { "Usual", "RIGHT", -330 }, { "7 days", "LEFT", -316, true },
        { "Sold/day", "RIGHT", -176 }, { "Listed", "RIGHT", -120 }, { "Have", "RIGHT", -82 }, { "", "RIGHT", -8 },
    }
    page.heads = {}
    for _, h in ipairs(cols) do
        local t = T.Text(list, 10, { bold = true, color = C.faint, text = h[1], justify = h[4] and "LEFT" or h[2] })
        if h[4] then t:SetPoint("TOPLEFT", list, "TOPRIGHT", h[3], -9) else t:SetPoint("TOP" .. h[2], h[3], -9) end
        page.heads[#page.heads + 1] = t
    end
    page.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, list)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", 6, -26 - (i - 1) * ROW_H); r:SetPoint("TOPRIGHT", -6, -26 - (i - 1) * ROW_H)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r.hl = T.Rounded(r, { 1, 1, 1, 0 }, 6, "BACKGROUND")
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(18, 18); r.icon:SetPoint("LEFT", 8, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.name = T.Text(r, 12); r.name:SetPoint("LEFT", 32, 0); r.name:SetWidth(176); r.name:SetWordWrap(false)
        r.now = T.Text(r, 12, { justify = "RIGHT" }); r.now:SetPoint("RIGHT", -396, 0)
        r.usual = T.Text(r, 12, { justify = "RIGHT", color = C.muted }); r.usual:SetPoint("RIGHT", -324, 0)
        -- Courbe : 7 barres (plus bas prix du jour), la plus récente en or.
        r.bars = {}
        for k = 1, 7 do
            local t = r:CreateTexture(nil, "ARTWORK"); t:SetTexture(T.WHITE)
            t:SetWidth(9); t:SetPoint("BOTTOMLEFT", r, "BOTTOMRIGHT", -310 + (k - 1) * 12, 5)
            r.bars[k] = t
        end
        r.vol = T.Text(r, 9, { color = C.neg }); r.vol:SetPoint("LEFT", r, "RIGHT", -222, 0)
        r.sales = T.Text(r, 12, { justify = "RIGHT" }); r.sales:SetPoint("RIGHT", -170, 0)
        r.listed = T.Text(r, 12, { justify = "RIGHT", color = C.muted }); r.listed:SetPoint("RIGHT", -114, 0)
        r.have = T.Text(r, 12, { justify = "RIGHT" }); r.have:SetPoint("RIGHT", -76, 0)
        r.tag = T.Text(r, 11, { bold = true, justify = "RIGHT" }); r.tag:SetPoint("RIGHT", -10, 0)
        r.buy = T.Button(r, Tr("Buy"), 60, 20, function() if r.row then LS.Buy(r.row.id) end end, "primary")
        r.buy:SetPoint("RIGHT", -4, 0)
        r:SetScript("OnEnter", function(self)
            self.hl:SetColor({ 1, 1, 1, 0.04 })
            local row = self.row
            if not row then return end
            T.ItemTooltip(self, row.id)
            local st = row.st
            GameTooltip:AddLine(" ")
            if st and st.med then
                GameTooltip:AddDoubleLine(Tr("Usual price (7 days)"), ns.FormatMoney(st.med, { iconSize = 11 }), 0.7, 0.7, 0.7, 1, 1, 1)
                GameTooltip:AddDoubleLine(Tr("Low / high"), ns.FormatMoney(st.low, { iconSize = 11 }) .. "  /  " .. ns.FormatMoney(st.high, { iconSize = 11 }), 0.7, 0.7, 0.7, 1, 1, 1)
                local mx = LS.BuyMax(st)
                if mx then GameTooltip:AddDoubleLine(Tr("Buy limit"), ns.FormatMoney(mx, { iconSize = 11 }), 0.7, 0.7, 0.7, 0.36, 0.82, 0.45) end
                GameTooltip:AddDoubleLine(Tr("Volatility"), ("%d %%"):format(math.floor((st.cv or 0) * 100 + 0.5)), 0.7, 0.7, 0.7, 1, 1, 1)
                GameTooltip:AddDoubleLine(Tr("Price points"), tostring(st.n or 0), 0.7, 0.7, 0.7, 1, 1, 1)
            else
                GameTooltip:AddLine(Tr("No price history yet: scan this list at the AH."), 0.6, 0.6, 0.6, true)
            end
            local e = row.e
            if e.qty and e.qty > 0 then GameTooltip:AddDoubleLine(e.range and ("Needed (" .. e.range .. ")") or "Needed", tostring(e.qty), 0.7, 0.7, 0.7, 1, 1, 1) end
            if e.note then GameTooltip:AddLine(e.note, 0.88, 0.66, 0.24) end
            if row.why then GameTooltip:AddLine(row.why, 0.6, 0.6, 0.6) end
            local rl = {}
            for _, r2 in ipairs(LS.ROLES) do if e.roles[r2[1]] then rl[#rl + 1] = Tr(r2[2]) end end
            if #rl > 0 and #rl < 5 then GameTooltip:AddLine(Tr("Used by: ") .. table.concat(rl, ", "), 0.6, 0.6, 0.6) end
            GameTooltip:AddLine(Tr("Right-click: add to one of your lists"), 0.88, 0.66, 0.24)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function(self) self.hl:SetColor({ 1, 1, 1, 0 }); GameTooltip:Hide() end)
        r:SetScript("OnClick", function(self, button)
            if not self.row then return end
            if button == "RightButton" then
                local entries = AddToListMenu(self.row.id)
                local l = LS.Get(LU.select)
                if l and l.custom then
                    local idx, id = l.custom, self.row.id
                    table.insert(entries, 1, { "Remove from this list", function() LS.RemoveFromCustom(idx, id); ns.UI.Refresh() end, color = C.neg })
                end
                Popup(self, entries)
            elseif IsModifiedClick and IsModifiedClick("CHATLINK") then
                local _, link = ns.GetItemInfo(self.row.id)
                if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
            end
        end)
        page.rows[i] = r
    end
    page.empty = T.Text(list, 12, { color = C.muted, justify = "CENTER", wrap = true })
    page.empty:SetPoint("CENTER"); page.empty:SetWidth(460)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, d)
        page.offset = math.max(0, math.min(math.max(0, #(page.data or {}) - ROWS), page.offset - d * 3))
        page:Draw()
    end)

    -- ---------------------------------------------------------- dessin
    function page:DrawSide()
        local items = self.sideItems or {}
        local y = -8
        local sh = self.side:GetHeight()
        if not sh or sh < 100 then sh = 500 end
        local maxY = -sh + 8
        for i, b in ipairs(self.sideBtns) do
            local it = items[self.sideOffset + i]
            b.item = it
            local h = it and (it.header and self.HEAD_H or self.ITEM_H) or 0
            if it and it.header and i > 1 then y = y - 6 end -- un peu d'air avant chaque groupe
            if it and y - h >= maxY then
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", 6, y); b:SetPoint("TOPRIGHT", -6, y); b:SetHeight(h)
                y = y - h
                b.t:ClearAllPoints(); b.badge:ClearAllPoints()
                if it.header then
                    b.t:SetPoint("LEFT", 10, 0)
                    b.t:SetText(Tr(it.header)); T.SetFont(b.t, 11, true); b.t:SetTextColor(unpack(C.gold))
                    b.chev:SetText(it.open and "–" or "+"); b.chev:Show()
                    b.badge:SetPoint("RIGHT", b.chev, "LEFT", -8, 0)
                    b.badge:SetText((not it.open and it.deals > 0) and ("● " .. it.deals) or "")
                    b.hl:SetColor({ 1, 1, 1, 0.025 })
                elseif it.new then
                    b.t:SetPoint("LEFT", 22, 0)
                    b.t:SetText(Tr("+ New list")); T.SetFont(b.t, 12, false); b.t:SetTextColor(unpack(C.gold))
                    b.chev:Hide(); b.badge:SetText(""); b.hl:SetColor({ 1, 1, 1, 0 })
                else
                    local sel = it.list.key == LU.select
                    b.t:SetPoint("LEFT", 22, 0)
                    b.t:SetText(Tr(it.list.title)); T.SetFont(b.t, 12, sel); b.t:SetTextColor(unpack(sel and C.text or C.muted))
                    b.chev:Hide()
                    b.badge:SetPoint("RIGHT", -10, 0)
                    b.badge:SetText(it.deals > 0 and ("● " .. it.deals) or "")
                    b.hl:SetColor(sel and { C.gold[1], C.gold[2], C.gold[3], 0.14 } or { 1, 1, 1, 0 })
                end
                b:Show()
            else
                b:Hide()
            end
        end
    end

    function page:Draw()
        local data = self.data or {}
        local b = LS.Buying()
        local ah = AHOpen()
        for i, r in ipairs(self.rows) do
            local row = data[self.offset + i]
            r.row = row
            if row then
                local id, st, e = row.id, row.st, row.e
                if not ns.GetItemInfo(id) and C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
                local _, _, icon = LS.Instant(id)
                r.icon:SetTexture(ns.GetItemIcon(id) or icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                local name = P.Name(id)
                if e.kind == "product" then name = "|cffe0a83d" .. name .. "|r" end
                r.name:SetText(name)
                r.now:SetText(st and st.cur and Money(st.cur) or (st and st.med and "|cff6fa8f0none|r" or Money(nil)))
                r.usual:SetText(Money(st and st.med))
                -- barres de la courbe
                local sp = st and st.spark or {}
                local lo, hi
                for k = 1, 7 do local v = sp[k]; if v then lo = lo and math.min(lo, v) or v; hi = hi and math.max(hi, v) or v end end
                for k = 1, 7 do
                    local t, v = r.bars[k], sp[k]
                    if v then
                        local h = (hi and hi > lo) and (3 + 13 * (v - lo) / (hi - lo)) or 8
                        t:SetHeight(h)
                        if k == 7 then t:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.95) else t:SetVertexColor(1, 1, 1, 0.22) end
                        t:Show()
                    else
                        t:SetHeight(2); t:SetVertexColor(1, 1, 1, 0.06); t:Show()
                    end
                end
                r.vol:SetText((st and (st.n or 0) >= 4 and (st.cv or 0) > 0.35) and "unstable" or "")
                r.sales:SetText(st and st.sales and (st.sales >= 10 and ("%d"):format(math.floor(st.sales + 0.5)) or ("%.1f"):format(st.sales)) or "|cff615f5c—|r")
                r.listed:SetText(st and st.qty and (st.qty >= 10000 and (Tr("%dk")):format(math.floor(st.qty / 1000)) or tostring(st.qty)) or "|cff615f5c—|r")
                local have = LS.Have(id)
                if e.qty and e.qty > 0 and self.list and self.list.leveling then
                    r.have:SetText((have >= e.qty and "|cff5cd173" or "") .. have .. "/" .. e.qty .. (have >= e.qty and "|r" or ""))
                else
                    r.have:SetText(have > 0 and tostring(have) or "|cff615f5c·|r")
                end
                local v = row.verdict
                local buying = b and b.id == id
                r.buy:SetShown(v == "buy" and ah and ns.IsCommodity(id) or buying)
                r.tag:SetShown(not r.buy:IsShown())
                if r.buy:IsShown() then
                    r.buy.text:SetText(buying and (b.stage == "confirm" and "Confirm" or "…") or "Buy")
                    r.buy:SetDisabled(b ~= nil and not buying)
                end
                if v and VERDICT[v] then r.tag:SetText(Tr(VERDICT[v][1])); r.tag:SetTextColor(unpack(VERDICT[v][2])) else r.tag:SetText("") end
                r:Show()
            else
                r:Hide()
            end
        end
    end

    function page:Refresh()
        local groups = LS.Groups()
        -- colonne de gauche
        local items = {}
        for _, g in ipairs(groups) do
            local open = not self.collapsed[g.key]
            local head = { header = g.title, key = g.key, open = open, deals = 0 }
            items[#items + 1] = head
            for _, l in ipairs(g.lists) do
                local d = LS.Deals(l)
                head.deals = head.deals + d
                if open then items[#items + 1] = { list = l, deals = d } end
            end
            if g.custom and open then items[#items + 1] = { new = true } end
        end
        self.sideItems = items
        self:DrawSide()

        local l = LS.Get(LU.select) or LS.Get("consum")
        self.list = l
        if not l then return end
        LU.select = l.key
        self.title:SetText(Tr(l.title))
        for k, btn in pairs(self.roleBtns) do btn:SetSelected(k == self.role) end
        for k, btn in pairs(self.kindBtns) do btn:SetSelected(k == self.kind) end
        self.dealBtn:SetSelected(self.dealsOnly)

        -- lignes filtrées et triées : affaires, puis produits, puis demande
        local data = {}
        for _, e in ipairs(l.entries) do
            if (self.role == "all" or e.roles[self.role]) and (self.kind == "all" or e.kind == self.kind or (self.kind == "mat" and e.kind == "tool")) then
                local row = LS.Row(e)
                if not self.dealsOnly or row.verdict == "buy" then data[#data + 1] = row end
            end
        end
        local order = { buy = 1, sell = 2, farm = 3 }
        table.sort(data, function(a, b)
            local oa, ob = order[a.verdict] or 4, order[b.verdict] or 4
            if oa ~= ob then return oa < ob end
            if a.e.uses ~= b.e.uses then return a.e.uses > b.e.uses end
            return P.Name(a.id) < P.Name(b.id)
        end)
        self.data = data
        self.offset = math.min(self.offset, math.max(0, #data - ROWS))

        -- sous-titre
        local sub = (Tr("%d items")):format(#data)
        if l.leveling then
            local now, usual, missing = LS.LevelCost(l)
            sub = sub .. (Tr("  ·  Cost now %s, usual %s%s")):format(Money(now), Money(usual), missing > 0 and (Tr("  (%d not priced)")):format(missing) or "")
            if usual > 0 and now > usual * 1.1 then sub = sub .. Tr("  ·  |cffe0a83dPrices are high: wait|r")
            elseif usual > 0 and now < usual * 0.9 then sub = sub .. Tr("  ·  |cff5cd173Good time to buy|r") end
        elseif l.key == "cd" then
            local board = LS.CooldownBoard()
            local parts = {}
            for k = 1, math.min(3, #board) do
                local c = board[k]
                local ready = c.readyAt <= time()
                parts[#parts + 1] = ("%s %s %s"):format(c.char, c.cd.n:gsub("^Transmute: ", "T: "),
                    ready and ("|cff5cd173" .. Tr("ready") .. "|r") or (Tr("in %s")):format((P.Ago(c.readyAt - time()):gsub(" ago", ""))))
            end
            sub = sub .. "  ·  " .. (#parts > 0 and table.concat(parts, "  ·  ") or Tr("Open your crafters' professions once to track their cooldowns"))
        end
        local sc = P.Scanning and P.Scanning()
        if sc and sc.mode == "list" then sub = (Tr("Scanning %s: %d / %d…")):format(sc.label, sc.i, #sc.ids) end
        if LU.msg and LU.msgT and GetTime() - LU.msgT < 15 then sub = LU.msg end
        if LS.msg and LS.msgT and GetTime() - LS.msgT < 15 then sub = LS.msg end
        self.sub:SetText(sub)
        self.scan.text:SetText(sc and "Stop" or "Scan list")

        local anyPrice = false
        for _, row in ipairs(data) do if row.st and row.st.med then anyPrice = true; break end end
        self.empty:SetText(#data == 0 and (self.dealsOnly and "No deal in this list right now." or "Nothing matches these filters.")
            or (not anyPrice and "No prices yet. Open the auction house and click Scan list.\nThe usual price and the verdicts get reliable after a few scans on different days." or ""))
        self.empty:SetShown(#data == 0 or not anyPrice)
        self:Draw()
    end
end

function LU.Msg(t)
    LU.msg, LU.msgT = t, GetTime()
    if ns.UI and ns.UI.Current and ns.UI.Current() == "lists" then ns.UI.Refresh() end
end

local function RefreshIfShown()
    local f = _G.ImpotPointGouvFrame
    if f and f:IsShown() and ns.UI.Current and ns.UI.Current() == "lists" then ns.UI.Refresh() end
end
local pend
local function Soon()
    if pend then return end
    pend = true
    C_Timer.After(0.3, function() pend = false; RefreshIfShown() end)
end
ns.On("LISTS_CHANGED", Soon)
ns.On("PRICES_CHANGED", Soon)
ns.On("LIST_SCAN", Soon)
local ev = CreateFrame("Frame")
for _, e in ipairs({ "GET_ITEM_INFO_RECEIVED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "BAG_UPDATE_DELAYED" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function() Soon() end)
