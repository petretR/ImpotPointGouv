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

local DrawRouteRow
local function Money(v) return v and ns.FormatMoney(v, { iconSize = 11, short = true }) or "|cff615f5c—|r" end

-- ------------------------------------------------------------ tri par colonne
-- Trie arr selon val(élément) ; les valeurs inconnues (nil) toujours en dernier, égalités départagées par tie.
function LU.SortBy(arr, val, desc, tie)
    local v, t = {}, {}
    for _, a in ipairs(arr) do v[a] = val(a); t[a] = tie(a) or "" end
    table.sort(arr, function(a, b)
        local va, vb = v[a], v[b]
        if va == nil or vb == nil then
            if va ~= vb then return va ~= nil end
        elseif va ~= vb then
            if desc then return va > vb end
            return va < vb
        end
        return t[a] < t[b]
    end)
end
-- Valeur d'une colonne pour un objet (vue liste) : nom, prix, volatilité, ventes, en vente, possédés, verdict.
local VERDICT_RANK = { buy = 3, sell = 2, farm = 1 }
function LU.ListValue(key, id, st, verdict)
    if key == "name" then return P.Name(id):lower() end
    if key == "have" then return LS.Have(id) end
    if key == "tag" then return VERDICT_RANK[verdict] end
    if not st then return nil end
    if key == "now" then return st.cur elseif key == "usual" then return st.med
    elseif key == "vol" then return st.cv elseif key == "sales" then return st.sales
    elseif key == "listed" then return st.qty end
end

-- ------------------------------------------------------------ route de montée : lignes dédiées
-- Montant arrondi : à l'argent près dès 1 pa, à l'or près dès 100 po.
local function RMoney(v, opts)
    if not v then return "|cff615f5c—|r" end
    local a = math.abs(v)
    if a >= 100 then a = math.floor(a / 100 + 0.5) * 100 end
    opts = opts or {}
    return ns.FormatMoney(v < 0 and -a or a, { iconSize = opts.icon or 11, short = true, sign = opts.sign })
end
local SRC_STYLE = {
    known   = { "Known",   { 0.36, 0.82, 0.45 } },
    trainer = { "Trainer", { 0.80, 0.78, 0.72 } },
    ah      = { "AH",      { 0.88, 0.66, 0.24 } },
    vendor  = { "Vendor",  { 0.45, 0.68, 0.95 } },
}
local function RouteUI(r)
    if rawget(r, "rt") then return r.rt end
    local C = ns.Theme.C
    local rt = {}
    rt.range = T.Text(r, 11, { bold = true, color = C.gold }); rt.range:SetPoint("LEFT", 14, 2)
    rt.track = r:CreateTexture(nil, "ARTWORK"); rt.track:SetTexture(T.WHITE)
    rt.track:SetVertexColor(1, 1, 1, 0.07); rt.track:SetSize(54, 2); rt.track:SetPoint("BOTTOMLEFT", 14, 5)
    rt.fill = r:CreateTexture(nil, "OVERLAY"); rt.fill:SetTexture(T.WHITE)
    rt.fill:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.85); rt.fill:SetHeight(2)
    rt.name = T.Text(r, 12); rt.name:SetWordWrap(false)
    rt.crafts = T.Text(r, 12, { justify = "RIGHT", color = C.muted }); rt.crafts:SetPoint("RIGHT", -272, 0)
    rt.pill = CreateFrame("Frame", nil, r); rt.pill:SetHeight(18); rt.pill:SetPoint("LEFT", r, "RIGHT", -252, 0)
    rt.pillBg = T.Rounded(rt.pill, { 1, 1, 1, 0.06 }, 9)
    rt.pillTx = T.Text(rt.pill, 10, { bold = true, justify = "CENTER" }); rt.pillTx:SetPoint("CENTER", 0, 0)
    rt.learn = T.Text(r, 11, { color = C.muted }); rt.learn:SetPoint("LEFT", rt.pill, "RIGHT", 6, 0)
    rt.cost = T.Text(r, 13, { bold = true, justify = "RIGHT" }); rt.cost:SetPoint("RIGHT", -16, 0)
    function rt.SetShown(on)
        for _, w in ipairs({ rt.range, rt.track, rt.fill, rt.name, rt.crafts, rt.pill, rt.learn, rt.cost }) do w:SetShown(on) end
    end
    r.rt = rt
    return rt
end

DrawRouteRow = function(r, row, absIndex, page)
    local C = ns.Theme.C
    local rt = RouteUI(r)
    rt.SetShown(true)
    local main = row.route ~= nil
    local x = row.route or row.alt
    local rc = x.r
    rc.name = rc.name or "?"
    -- Palier + petite jauge de progression vers 300.
    if main then
        rt.range:SetText(("%d – %d"):format(x.from, x.to))
        local w = 54
        rt.fill:ClearAllPoints()
        rt.fill:SetPoint("BOTTOMLEFT", rt.track, "BOTTOMLEFT", math.floor(w * x.from / 300), 0)
        rt.fill:SetWidth(math.max(2, math.floor(w * (x.to - x.from) / 300)))
    end
    rt.range:SetShown(main); rt.track:SetShown(main); rt.fill:SetShown(main)
    -- Icône + nom.
    local left = main and 86 or 104
    local tex = rc.out and ns.GetItemIcon(rc.out) or (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(rc.spell)) or "Interface\\Icons\\INV_Misc_QuestionMark"
    r.icon:ClearAllPoints(); r.icon:SetPoint("LEFT", left, 0); r.icon:SetTexture(tex)
    r.icon:SetSize(main and 18 or 15, main and 18 or 15)
    rt.name:ClearAllPoints(); rt.name:SetPoint("LEFT", left + (main and 26 or 22), 0)
    rt.name:SetWidth(math.max(120, (r:GetWidth() or 800) - left - 26 - 300))
    local label = rc.name .. (rc.est and "|cff6b675f ~|r" or "")
    if main then
        local n = #(x.alts or {})
        if n > 0 then
            local open = page.routeOpen and page.routeOpen[x.from]
            label = label .. "   |cff6b675f" .. (open and "▼" or ((Tr("+%d options")):format(n))) .. "|r"
        end
        rt.name:SetTextColor(0.93, 0.90, 0.84)
    else
        rt.name:SetTextColor(unpack(C.muted))
    end
    rt.name:SetText(label)
    -- Crafts.
    rt.crafts:SetText(("×%d"):format(math.floor((x.crafts or 0) + 0.5)))
    -- Source : pastille colorée, puis le coût d'apprentissage.
    local st = SRC_STYLE[rc.label] or { rc.label or "?", C.muted }
    local col = st[2]
    local txt = Tr(st[1])
    if rc.label == "ah" and rc.qtyListed then txt = txt .. " · " .. rc.qtyListed end
    rt.pillTx:SetText(txt); rt.pillTx:SetTextColor(col[1], col[2], col[3], 1)
    rt.pillBg:SetColor({ col[1], col[2], col[3], 0.14 })
    rt.pill:SetWidth((rt.pillTx:GetStringWidth() or 40) + 16)
    if rc.F and rc.F > 0 and not x.reuse then
        rt.learn:SetText(RMoney(rc.F, { icon = 10 }) .. (rc.estF and " ~" or ""))
    else
        rt.learn:SetText("")
    end
    -- Coût total de la tranche ; pour une alternative, l'écart avec l'étape choisie.
    if main then
        -- Signe du point de vue de ta bourse : − ça coûte, + ça rapporte.
        local v = -(x.cost or 0)
        rt.cost:SetText(RMoney(v, { sign = true }))
        T.SetFont(rt.cost, 13, true)
        if v > 0 then rt.cost:SetTextColor(0.36, 0.82, 0.45) else rt.cost:SetTextColor(0.93, 0.90, 0.84) end
    else
        local d = (row.seg.cost or 0) - x.cost -- ce que tu perds en prenant cette alternative
        rt.cost:SetText(RMoney(d, { icon = 10, sign = true }))
        T.SetFont(rt.cost, 11, false); rt.cost:SetTextColor(unpack(C.muted))
    end
    for k = 1, 7 do r.bars[k]:Hide() end
    r.buy:Hide(); r.tag:Hide()
    r.band:SetShown(main)
    r.sep:SetShown(main and absIndex > 1)
    r:SetAlpha(1)
    r:Show()
end

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
    LU._page = page
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
    -- Vue : par recette (produit / enchantement puis ses composants) ou liste à plat.
    page.view = ns.db.settings.listView or "recipe"
    page.viewBtns = {}
    local kprev
    for i = 2, 1, -1 do
        local k = ({ { "recipe", "By recipe" }, { "flat", "Flat list" } })[i]
        local b = T.Button(main, Tr(k[2]), 84, 22, function()
            page.view = k[1]; ns.db.settings.listView = k[1]; page.offset = 0; page:Refresh()
        end, "pill")
        if kprev then b:SetPoint("RIGHT", kprev, "LEFT", -4, 0) else b:SetPoint("TOPRIGHT", 0, fy) end
        kprev = b
        page.viewBtns[k[1]] = b
    end
    -- Listes de montée de métier : liste de courses ou meilleure route.
    page.lvView = ns.db.settings.lvView or "route"
    page.lvBtns = {}
    local lprev
    for i = 2, 1, -1 do
        local k = ({ { "shop", "Shopping list" }, { "route", "Best route" } })[i]
        local b = T.Button(main, Tr(k[2]), 96, 22, function()
            page.lvView = k[1]; ns.db.settings.lvView = k[1]; page.offset = 0; page:Refresh()
        end, "pill")
        if lprev then b:SetPoint("RIGHT", lprev, "LEFT", -4, 0) else b:SetPoint("TOPRIGHT", 0, fy) end
        lprev = b
        page.lvBtns[k[1]] = b
    end
    page.noAH = T.Button(main, Tr("No AH patterns"), 112, 22, function()
        ns.db.settings.routeNoAH = not ns.db.settings.routeNoAH; page:Refresh()
    end, "pill")
    page.noAH:SetPoint("TOPLEFT", 0, fy)
    page.noAH.tooltip = Tr("Route with trainer recipes, vendor patterns and recipes you know only.")
    page.resetRoute = T.Button(main, Tr("Reset my choices"), 120, 22, function()
        if page.routeProf then ns.Route.ResetBans(page.routeProf) end; page:Refresh()
    end)
    page.resetRoute:SetPoint("LEFT", page.noAH, "RIGHT", 6, 0)

    -- Tableau
    local list = CreateFrame("Frame", nil, main)
    T.Surface(list, C.surface, 10)
    list:SetPoint("TOPLEFT", 0, -74); list:SetPoint("BOTTOMRIGHT", 0, 0)
    page.listFrame = list
    local cols = {
        { "Item", "LEFT", 38 }, { "Now", "RIGHT", -402 }, { "Usual", "RIGHT", -330 }, { "7 days", "LEFT", -316, true },
        { "Sold/day", "RIGHT", -176 }, { "Listed", "RIGHT", -120 }, { "Have", "RIGHT", -82 }, { "", "RIGHT", -8 },
    }
    page.heads, page.headLabels = {}, {}
    for k, h in ipairs(cols) do
        local t = T.Text(list, 10, { bold = true, color = C.faint, text = h[1], justify = h[4] and "LEFT" or h[2] })
        if h[4] then t:SetPoint("TOPLEFT", list, "TOPRIGHT", h[3], -9) else t:SetPoint("TOP" .. h[2], h[3], -9) end
        page.heads[k] = t
        -- Zone cliquable sur le titre : trie la colonne.
        local b = CreateFrame("Button", nil, list)
        b:SetPoint("TOPLEFT", t, "TOPLEFT", -4, 4); b:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", 4, -4)
        b:SetScript("OnClick", function() page:SortBy(k) end)
        b:SetScript("OnEnter", function(self)
            if not page:SortKey(k) then return end
            t:SetTextColor(unpack(C.text))
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(Tr("Click to sort, again to reverse, a third time for the default order"), 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide(); page:Heads() end)
    end

    -- Tri par colonne : une clé par colonne, selon la vue (listes ou route de montée).
    local SORT_COLS = {
        list = { "name", "now", "usual", "vol", "sales", "listed", "have", "tag" },
        route = { "skill", "recipe", nil, nil, "crafts", "source", "cost" },
    }
    local ASC_FIRST = { name = true, skill = true, recipe = true, source = true }
    local saved = ns.db.settings.listSort or {}
    page.sortState = { list = saved.list or {}, route = saved.route or {} }
    page.sortMode = "list"
    function page:SortKey(k) return SORT_COLS[self.sortMode][k] end
    function page:SortBy(k)
        local key = self:SortKey(k)
        if not key then return end
        local s = self.sortState[self.sortMode]
        if s.key ~= key then s.key, s.desc = key, not ASC_FIRST[key]
        elseif s.desc == not ASC_FIRST[key] then s.desc = not s.desc
        else s.key, s.desc = nil, nil end
        ns.db.settings.listSort = self.sortState
        self.offset = 0
        self:Refresh()
    end
    function page:Heads()
        local s = self.sortState[self.sortMode]
        for k, t in ipairs(self.heads) do
            local key = self:SortKey(k)
            local on = key and key == s.key
            t:SetText((self.headLabels[k] or "") .. (on and (s.desc and " ▼" or " ▲") or ""))
            t:SetTextColor(unpack(on and C.gold or C.faint))
        end
    end
    page.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, list)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", 6, -26 - (i - 1) * ROW_H); r:SetPoint("TOPRIGHT", -6, -26 - (i - 1) * ROW_H)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r.hl = T.Rounded(r, { 1, 1, 1, 0 }, 6, "BACKGROUND")
        -- Ligne de recette : bande de fond + trait or au-dessus, pour séparer chaque recette.
        r.band = T.Rounded(r, { C.gold[1], C.gold[2], C.gold[3], 0.07 }, 6, "BACKGROUND", -1)
        r.sep = r:CreateTexture(nil, "ARTWORK"); r.sep:SetTexture(T.WHITE); r.sep:SetHeight(1)
        r.sep:SetPoint("TOPLEFT", 4, 2); r.sep:SetPoint("TOPRIGHT", -4, 2); r.sep:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.35)
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
            if row.route or row.alt then
                local rc = row.route and row.route.r or row.alt.r
                if rc.out then T.ItemTooltip(self, rc.out) else GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine(rc.name or "?", 1, 1, 1) end
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(("|cffff8040%d|r  |cffffff00%d|r  |cff40bf40%d|r  |cff808080%d|r%s"):format(rc.o, rc.y,
                    math.floor((rc.y + rc.g) / 2), rc.g, rc.est and ("  " .. Tr("(estimated)")) or ""))
                for _, m in ipairs(rc.mats) do
                    local st = P.Stats(m[1])
                    local p = (P.IsVendorItem(m[1]) and P.VendorBuy(m[1])) or (st and (st.med or st.cur))
                    GameTooltip:AddDoubleLine(m[2] .. "× " .. P.Name(m[1]), p and Money(p * m[2]) or "?", 0.8, 0.8, 0.8, 1, 1, 1)
                end
                if (rc.resale or 0) > 0 then GameTooltip:AddDoubleLine(Tr("Resale of what you craft"), "+" .. Money(rc.resale), 0.7, 0.7, 0.7, 0.36, 0.82, 0.45) end
                if (rc.F or 0) > 0 and (row.route or row.alt).reuse then GameTooltip:AddDoubleLine(Tr("Learn it (once)"), Tr("already paid earlier in the route"), 0.7, 0.7, 0.7, 0.6, 0.6, 0.6)
                elseif (rc.F or 0) > 0 then GameTooltip:AddDoubleLine(Tr("Learn it (once)"), Money(rc.F) .. (rc.estF and " ~" or ""), 0.7, 0.7, 0.7, 1, 1, 1) end
                GameTooltip:AddDoubleLine(Tr("Per craft (resale − materials)"), ns.FormatMoney(-(rc.c or 0), { iconSize = 11, short = true, sign = true, color = true }), 0.7, 0.7, 0.7, 1, 1, 1)
                GameTooltip:AddLine(" ")
                if row.alt then GameTooltip:AddLine(Tr("Click: use this recipe instead"), 0.88, 0.66, 0.24)
                else
                    if #(row.route.alts or {}) > 0 then GameTooltip:AddLine(Tr("Click: show the alternatives"), 0.88, 0.66, 0.24) end
                    GameTooltip:AddLine(Tr("Right-click: skip this recipe"), 0.88, 0.66, 0.24)
                end
                GameTooltip:Show()
                return
            end
            if row.head and not row.id then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(Tr(row.rec.name), 1, 1, 1)
                for _, m in ipairs(row.rec.mats) do
                    if m[3] == 1 then GameTooltip:AddDoubleLine(P.Name(m[1]), "×" .. LS.FmtQty(m[2]), 0.8, 0.8, 0.8, 0.6, 0.6, 0.6) end
                end
                GameTooltip:AddDoubleLine(Tr("Usual price (7 days)"), Money(row.cost), 0.7, 0.7, 0.7, 1, 1, 1)
                GameTooltip:Show()
                return
            end
            T.ItemTooltip(self, row.id)
            if row.head and row.rec then
                GameTooltip:AddLine(" ")
                GameTooltip:AddDoubleLine(Tr("Materials, best mix"), Money(row.cost), 0.88, 0.66, 0.24, 1, 1, 1)
                if row.rec._allBuy and row.rec._allBuy ~= row.cost then
                    GameTooltip:AddDoubleLine(Tr("Materials, all bought"), Money(row.rec._allBuy), 0.7, 0.7, 0.7, 1, 1, 1)
                end
                if row.value then GameTooltip:AddDoubleLine(Tr("Sells for (after AH cut)"), Money(row.value), 0.7, 0.7, 0.7, 1, 1, 1) end
            end
            if row.choice then
                GameTooltip:AddLine(" ")
                GameTooltip:AddDoubleLine(Tr("Buy it"), Money(row.choice.buy), 0.7, 0.7, 0.7, 1, 1, 1)
                GameTooltip:AddDoubleLine(Tr("Craft it (materials below)"), Money(row.choice.craft), 0.7, 0.7, 0.7, 1, 1, 1)
                GameTooltip:AddLine(row.choice.best == "craft" and Tr("Cheaper to craft") or Tr("Cheaper to buy"), 0.36, 0.82, 0.45)
            end
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
            if e.qty and e.qty > 0 then GameTooltip:AddDoubleLine(e.range and ("Needed (" .. e.range .. ")") or "Needed", LS.FmtQty(e.qty), 0.7, 0.7, 0.7, 1, 1, 1) end
            if e.note then GameTooltip:AddLine(e.note, 0.88, 0.66, 0.24) end
            if e.usedIn and not row.head then
                local names = {}
                for rec, q in pairs(e.usedIn) do
                    local n = rec.cd and Tr(rec.name) or (rec.id and P.Name(rec.id)) or Tr(rec.name)
                    names[#names + 1] = { n, q }
                end
                table.sort(names, function(a, b) return a[1] < b[1] end)
                GameTooltip:AddLine(Tr("Used in:"), 0.88, 0.66, 0.24)
                for k = 1, math.min(10, #names) do GameTooltip:AddDoubleLine("  " .. names[k][1], "×" .. LS.FmtQty(names[k][2]), 0.8, 0.8, 0.8, 0.6, 0.6, 0.6) end
                if #names > 10 then GameTooltip:AddLine(("  +%d"):format(#names - 10), 0.6, 0.6, 0.6) end
            end
            if row.why then GameTooltip:AddLine(row.why, 0.6, 0.6, 0.6) end
            local rl = {}
            for _, r2 in ipairs(LS.ROLES) do if e.roles[r2[1]] then rl[#rl + 1] = Tr(r2[2]) end end
            if #rl > 0 and #rl < 5 then GameTooltip:AddLine(Tr("Used by: ") .. table.concat(rl, ", "), 0.6, 0.6, 0.6) end
            -- Où sont vos exemplaires (sacs, banque, courrier, en route, en vente).
            local I = ns.Inventory
            if I and I.Breakdown then
                local rows, listed, transit, warband = I.Breakdown(row.id)
                if #rows > 0 or listed > 0 or transit > 0 or warband > 0 then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddDoubleLine(Tr("You have"), tostring(LS.Have(row.id)), 0.88, 0.66, 0.24, 1, 1, 1)
                    for _, c in ipairs(rows) do
                        local parts = {}
                        if c[2] > 0 then parts[#parts + 1] = Tr("bags") .. " " .. c[2] end
                        if c[3] > 0 then parts[#parts + 1] = Tr("bank") .. " " .. c[3] end
                        if c[4] > 0 then parts[#parts + 1] = Tr("mail") .. " " .. c[4] end
                        GameTooltip:AddDoubleLine("  " .. c[1], table.concat(parts, ", "), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
                    end
                    if warband > 0 then GameTooltip:AddDoubleLine("  " .. Tr("Warband bank"), tostring(warband), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8) end
                    if transit > 0 then GameTooltip:AddDoubleLine("  " .. Tr("Mailed, not collected yet"), tostring(transit), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8) end
                    if listed > 0 then GameTooltip:AddDoubleLine("  " .. Tr("Listed at the AH"), tostring(listed), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8) end
                end
            end
            GameTooltip:AddLine(Tr("Right-click: add to one of your lists"), 0.88, 0.66, 0.24)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function(self) self.hl:SetColor({ 1, 1, 1, 0 }); GameTooltip:Hide() end)
        r:SetScript("OnClick", function(self, button)
            if not self.row then return end
            if self.row.alt then
                ns.Route.Ban(self.row.prof, self.row.seg.r.spell); page:Refresh(); return
            elseif self.row.route then
                if button == "RightButton" then
                    ns.Route.Ban(self.row.prof, self.row.route.r.spell)
                elseif #(self.row.route.alts or {}) > 0 then
                    local k = self.row.route.from
                    page.routeOpen[k] = not page.routeOpen[k] or nil
                end
                page:Refresh()
                return
            end
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
            local indent = row and row.depth and (row.depth * 16) or 0
            local isHead = row and row.head
            r.band:SetShown(isHead and true or false)
            r.sep:SetShown(isHead and (self.offset + i) > 1 or false)
            r.icon:ClearAllPoints(); r.icon:SetPoint("LEFT", 8 + indent, 0); r.icon:SetSize(18, 18)
            r.name:ClearAllPoints(); r.name:SetPoint("LEFT", 32 + indent, 0); r.name:SetWidth(176 - indent)
            local SRC = { known = { Tr("Known"), VERDICT.buy[2] }, trainer = { Tr("Trainer"), C.text },
                ah = { Tr("AH"), C.gold }, vendor = { Tr("Vendor"), { 0.45, 0.68, 0.95, 1 } } }
            local isRouteRow = row and (row.route or row.alt) and true or false
            for _, w in ipairs({ r.name, r.now, r.usual, r.vol, r.sales, r.listed, r.have }) do w:SetShown(not isRouteRow) end
            if rawget(r, "rt") then r.rt.SetShown(not not isRouteRow) end
            if isRouteRow then
                DrawRouteRow(r, row, self.offset + i, self)
            elseif row and row.head and not row.id then
                -- En-tête d'enchantement (pas d'objet) : coût des composants.
                local rec = row.rec
                local tex = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(rec.spell)) or "Interface\\Icons\\Trade_Engraving"
                r.icon:SetTexture(tex)
                r.name:SetText("|cffece6d6" .. Tr(rec.name) .. "|r")
                r.now:SetText(Money(row.costNow)); r.usual:SetText(Money(row.cost))
                for k = 1, 7 do r.bars[k]:Hide() end
                r.vol:SetText(""); r.sales:SetText(""); r.listed:SetText(""); r.have:SetText("")
                r.buy:Hide(); r.tag:Show(); r.tag:SetText("")
                r:SetAlpha(1)
                r:Show()
            elseif row then
                local id, st, e = row.id, row.st, row.e
                if not ns.GetItemInfo(id) and C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
                local _, _, icon = LS.Instant(id)
                r.icon:SetTexture(ns.GetItemIcon(id) or icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                local name = (row.head and row.rec and row.rec.cd) and Tr(row.rec.name) or P.Name(id)
                if row.head or (not row.depth and e.kind == "product") then name = "|cffe0a83d" .. name .. "|r" end
                if row.depth and row.qty then name = "|cff8a877f" .. LS.FmtQty(row.qty) .. "×|r " .. name end
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
                for k = 1, 7 do r.bars[k]:Show() end
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
                if row.head then
                    -- Recette : gain net par craft (valeur HV après commission − composants).
                    if row.value and row.missing == 0 then
                        r.tag:SetText(ns.FormatMoney(row.value - row.cost, { sign = true, color = true, iconSize = 10, short = true }))
                    else
                        r.tag:SetText("")
                    end
                elseif row.choice then
                    -- Intermédiaire : l'acheter ou le fabriquer, le moins cher des deux.
                    local craft = row.choice.best == "craft"
                    r.tag:SetText(craft and Tr("CRAFT") or Tr("BUY IT"))
                    r.tag:SetTextColor(unpack(craft and VERDICT.buy[2] or C.gold))
                elseif v and VERDICT[v] then r.tag:SetText(Tr(VERDICT[v][1])); r.tag:SetTextColor(unpack(VERDICT[v][2])) else r.tag:SetText("") end
                r:SetAlpha(row.dim and 0.45 or 1)
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
        -- Rôles : seulement pour ce qui dépend des spés (consommables, enchantements, pré-BiS).
        local showRoles = not (l.leveling or l.custom or l.cd or l.noRoles)
        local showKinds = not (l.leveling or l.custom) and #l.recipes > 0
        local role = showRoles and self.role or "all"
        local kind = "all"
        local byRecipe = showKinds and self.view == "recipe"
        for k, btn in pairs(self.roleBtns) do btn:SetSelected(k == self.role); btn:SetShown(showRoles) end
        for k, btn in pairs(self.viewBtns) do btn:SetSelected(k == self.view); btn:SetShown(showKinds) end
        local isRoute = l.leveling and self.lvView == "route"
        for k, btn in pairs(self.lvBtns) do btn:SetSelected(k == self.lvView); btn:SetShown(l.leveling and true or false) end
        self.noAH:SetShown(isRoute and true or false); self.noAH:SetSelected(ns.db.settings.routeNoAH and true or false)
        self.routeProf = l.leveling and l.key:sub(4) or nil
        self.resetRoute:SetShown(isRoute and ns.Route.HasBans(self.routeProf) or false)
        local H = isRoute and { Tr("Skill"), Tr("Recipe"), "", "", Tr("Crafts"), Tr("Source"), Tr("Cost"), "" }
            or { Tr("Item"), Tr("Now"), Tr("Usual"), Tr("7 days"), Tr("Sold/day"), Tr("Listed"), Tr("Have"),
                byRecipe and Tr("Profit") or Tr("Verdict") }
        self.sortMode = isRoute and "route" or "list"
        local sortS = self.sortState[self.sortMode]
        self.headLabels = H
        self:Heads()
        -- Colonnes : celles de la route ou celles des listes.
        local HP = isRoute and {
            { "LEFT", 14 }, { "LEFT", 112 }, { "RIGHT", -300 }, { "RIGHT", -300 },
            { "RIGHT", -278 }, { "TOPLEFT", -252 }, { "RIGHT", -22 } }
            or { { "LEFT", 38 }, { "RIGHT", -402 }, { "RIGHT", -330 }, { "TOPLEFT", -316 },
            { "RIGHT", -176 }, { "RIGHT", -120 }, { "RIGHT", -82 } }
        for k = 1, 7 do
            local h, pos = self.heads[k], HP[k]
            h:ClearAllPoints()
            if pos[1] == "TOPLEFT" then h:SetPoint("TOPLEFT", self.listFrame, "TOPRIGHT", pos[2], -9); h:SetJustifyH("LEFT")
            else h:SetPoint("TOP" .. pos[1], pos[2], -9); h:SetJustifyH(pos[1]) end
        end
        self.listFrame:ClearAllPoints()
        self.listFrame:SetPoint("TOPLEFT", 0, (showRoles or showKinds or l.leveling) and -74 or -44)
        self.listFrame:SetPoint("BOTTOMRIGHT", 0, 0)

        -- lignes filtrées et triées : affaires, puis produits, puis demande
        local data = {}
        for _, e in ipairs(l.entries) do
            if (role == "all" or e.roles[role]) and (kind == "all" or e.kind == kind or (kind == "mat" and e.kind == "tool")) then
                local row = LS.Row(e)
                data[#data + 1] = row
            end
        end
        local order = { buy = 1, sell = 2, farm = 3 }
        table.sort(data, function(a, b)
            local oa, ob = order[a.verdict] or 4, order[b.verdict] or 4
            if oa ~= ob then return oa < ob end
            if a.e.uses ~= b.e.uses then return a.e.uses > b.e.uses end
            return P.Name(a.id) < P.Name(b.id)
        end)
        if sortS.key and not byRecipe then
            LU.SortBy(data, function(row) return LU.ListValue(sortS.key, row.id, row.st, row.verdict) end,
                sortS.desc, function(row) return P.Name(row.id) end)
        end
        if byRecipe then
            -- Une ligne par recette, puis ses composants en retrait.
            local recs = {}
            for _, rec in ipairs(l.recipes) do
                if role == "all" or (rec.roles and rec.roles[role]) then
                    local cost, missing, value = LS.RecipeCost(rec)
                    local costNow = LS.RecipeCost(rec, true)
                    recs[#recs + 1] = { rec = rec, cost = cost, costNow = costNow, missing = missing, value = value,
                        gain = (value and missing == 0) and (value - cost) or nil }
                end
            end
            table.sort(recs, function(a, b)
                if (a.gain ~= nil) ~= (b.gain ~= nil) then return a.gain ~= nil end
                if a.gain and b.gain and a.gain ~= b.gain then return a.gain > b.gain end
                return Tr(a.rec.name) < Tr(b.rec.name)
            end)
            if sortS.key then
                LU.SortBy(recs, function(x)
                    if sortS.key == "tag" then return x.gain end
                    if sortS.key == "name" then return Tr(x.rec.name):lower() end
                    return x.rec.id and LU.ListValue(sortS.key, x.rec.id, P.Stats(x.rec.id)) or nil
                end, sortS.desc, function(x) return Tr(x.rec.name) end)
            end
            data = {}
            for _, x in ipairs(recs) do
                local head = { head = true, rec = x.rec, id = x.rec.id, cost = x.cost, costNow = x.costNow, missing = x.missing, value = x.value }
                if x.rec.id then
                    head.e = l.byId[x.rec.id] or { id = x.rec.id, kind = "product", roles = {}, uses = 1 }
                    head.st = P.Stats(x.rec.id)
                end
                data[#data + 1] = head
                local detail = x.rec._detail or {}
                local dimBelow
                for k, m in ipairs(x.rec.mats) do
                    local e = l.byId[m[1]] or { id = m[1], kind = "mat", roles = {}, uses = 1 }
                    local row = LS.Row(e)
                    row.depth, row.qty = m[3], m[2]
                    if dimBelow and m[3] <= dimBelow then dimBelow = nil end
                    row.dim = dimBelow ~= nil
                    local d = detail[k]
                    if d and d.craft then
                        row.choice = d
                        if d.best == "buy" then dimBelow = m[3] end
                    end
                    data[#data + 1] = row
                end
            end
        end
        local route
        if isRoute then
            route = ns.Route.Compute(self.routeProf, { noAH = ns.db.settings.routeNoAH })
            if self.routeOpenFor ~= self.routeProf then self.routeOpen, self.routeOpenFor = {}, self.routeProf end
            data = {}
            local segs = { unpack(route.segs) }
            if sortS.key then
                LU.SortBy(segs, function(sg)
                    local k = sortS.key
                    if k == "skill" then return sg.from elseif k == "recipe" then return (sg.r.name or ""):lower()
                    elseif k == "crafts" then return sg.crafts elseif k == "source" then return sg.r.label
                    elseif k == "cost" then return sg.cost end
                end, sortS.desc, function(sg) return ("%03d"):format(sg.from) end)
            end
            for _, sg in ipairs(segs) do
                data[#data + 1] = { route = sg, prof = self.routeProf }
                if self.routeOpen[sg.from] then
                    for _, a in ipairs(sg.alts) do data[#data + 1] = { alt = a, seg = sg, prof = self.routeProf } end
                end
            end
        end
        self.data = data
        self.offset = math.min(self.offset, math.max(0, #data - ROWS))

        -- sous-titre
        local sub = byRecipe and (Tr("%d recipes")):format(#(function() local n = {} for _, d in ipairs(data) do if d.head then n[#n + 1] = d end end return n end)())
            or (Tr("%d items")):format(#data)
        if isRoute then
            sub = (Tr("From %d%s to 300: %s in %d steps")):format(route.start, route.who and (" (" .. route.who .. ")") or "",
                ns.FormatMoney(-route.total, { iconSize = 11, short = true, sign = true, color = route.total < 0 }), #route.segs)
            if not route.reached then sub = sub .. Tr("  ·  |cffed5c52Incomplete: scan the AH so more recipes get a price|r") end
            if (route.cdSkipped or 0) > 0 then sub = sub .. (Tr("  ·  %d cooldown recipes left out")):format(route.cdSkipped) end
        elseif l.leveling then
            local now, usual, missing = LS.LevelCost(l)
            sub = sub .. (Tr("  ·  Cost now %s, usual %s%s")):format(Money(now), Money(usual), missing > 0 and (Tr("  (%d not priced)")):format(missing) or "")
            if usual > 0 and now > usual * 1.1 then sub = sub .. Tr("  ·  |cffe0a83dPrices are high: wait|r")
            elseif usual > 0 and now < usual * 0.9 then sub = sub .. Tr("  ·  |cff5cd173Good time to buy|r") end
        elseif l.cd then
            local board = {}
            for _, c in ipairs(LS.CooldownBoard()) do if c.cd.p == l.prof then board[#board + 1] = c end end
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
        self.empty:SetText(#data == 0 and Tr("Nothing matches these filters.")
            or (not anyPrice and "No prices yet. Open the auction house and click Scan list.\nThe usual price and the verdicts get reliable after a few scans on different days." or ""))
        if isRoute then
            anyPrice = true
            if #data == 0 then
                self.empty:SetText(Tr("No route yet: scan the AH (full scan) so the materials get a price."))
            end
        end
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
