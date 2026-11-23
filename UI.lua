-- ImpotPointGouv : fenêtre principale (Bilan, Transactions, Personnages), minimap, commandes.
local _, ns = ...
local Tr = ns.L
local T, L = ns.Theme, ns.Ledger
local C = T.C
local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 960, 620
local PAD = 18

local RANGES = {
    { key = "24h", label = "24h", secs = 86400, desc = "last 24 hours" },
    { key = "7d",  label = "7d",  secs = 7 * 86400, desc = "last 7 days" },
    { key = "30d", label = "30d", secs = 30 * 86400, desc = "last 30 days" },
    { key = "all", label = Tr("All"), secs = nil, desc = "since tracking began" },
}

local function RangeStart()
    local key = ns.db.settings.range
    for _, r in ipairs(RANGES) do
        if r.key == key then
            if r.secs then return time() - r.secs, r end
            return math.min(L.FirstTime() or time(), time() - 3600), r
        end
    end
    return time() - 30 * 86400, RANGES[3]
end

-- ================================================================ fenêtre
local frame
local pages, tabs = {}, {}
local current

local function ShowPage(name)
    current = name
    for k, p in pairs(pages) do p:SetShown(k == name) end
    for k, t in pairs(tabs) do t:SetSelected(k == name) end
    if pages[name] and pages[name].Refresh then pages[name]:Refresh() end
end

local function Card(parent)
    local f = CreateFrame("Frame", nil, parent)
    T.Surface(f, C.surface, 10)
    return f
end

local function CardTitle(card, text)
    local fs = T.Text(card, 12, { bold = true, color = C.text, text = text })
    fs:SetPoint("TOPLEFT", 16, -14)
    return fs
end

-- ------------------------------------------------------------ page Bilan
-- Valeur du stock : composants et créations de vos recettes (+ compos d'enchantement) détenus par tous vos persos,
-- au prix où vous les vendriez aujourd'hui (HV nette ou marchand, le meilleur).
function UI.StockValue()
    return ns.Stock.Value()
end

local function BuildBilan(page)
    local title = T.Text(page, 20, { bold = true, text = Tr("Overview") })
    title:SetPoint("TOPLEFT", 0, -2)
    page.period = T.Text(page, 12, { color = C.muted })
    page.period:SetPoint("LEFT", title, "RIGHT", 12, -1)

    -- Sélecteur de période
    page.rangeButtons = {}
    local prev
    for i = #RANGES, 1, -1 do
        local r = RANGES[i]
        local b = T.Button(page, r.label, 54, 26, function()
            ns.db.settings.range = r.key
            page:Refresh()
        end, "pill")
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", 0, 0) end
        prev = b
        page.rangeButtons[r.key] = b
    end

    -- 4 cartes de synthèse
    page.cards = {}
    local defs = {
        { "Total gold", "all characters" },
        { "Trading result", "sales − purchases − AH fees" },
        { "Stock value", "everything you hold" },
        { "Sales", "" },
    }
    local gap = 12
    local cw = (WIDTH - PAD * 2 - gap * 3) / 4
    for i, d in ipairs(defs) do
        local card = Card(page)
        card:SetSize(cw, 86)
        card:SetPoint("TOPLEFT", (i - 1) * (cw + gap), -42)
        card.label = T.Text(card, 11, { color = C.muted, text = d[1] })
        card.label:SetPoint("TOPLEFT", 16, -14)
        card.value = T.Text(card, 20, { bold = true })
        card.value:SetPoint("TOPLEFT", 16, -32)
        card.sub = T.Text(card, 11, { color = C.faint, text = d[2] })
        card.sub:SetPoint("TOPLEFT", 16, -62)
        card.sub:SetWidth(cw - 28)
        if i == 1 then
            card.accent = card:CreateTexture(nil, "ARTWORK")
            card.accent:SetTexture(T.WHITE)
            card.accent:SetVertexColor(unpack(C.gold))
            card.accent:SetSize(3, 40)
            card.accent:SetPoint("LEFT", 0, 0)
        end
        if i == 3 then
            -- Clic : l'onglet Stock (détail objet par objet).
            card:EnableMouse(true)
            card:SetScript("OnMouseUp", function() UI.Toggle("stock") end)
            card:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:AddLine(Tr("Click: see every item in the Stock tab"), 0.88, 0.66, 0.24)
                GameTooltip:Show()
            end)
            card:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        page.cards[i] = card
    end

    -- Colonne droite
    local rightW = 286
    local chartCard = Card(page)
    chartCard:SetPoint("TOPLEFT", 0, -142)
    chartCard:SetPoint("BOTTOMRIGHT", -(rightW + gap), 0)
    page.chartTitle = CardTitle(chartCard, "Gold over time")
    page.modeButtons = {}
    local modes = { { "balance", "Gold" }, { "ahprofit", "AH profit" } }
    prev = nil
    for i = #modes, 1, -1 do
        local m = modes[i]
        local b = T.Button(chartCard, m[2], 84, 24, function()
            ns.db.settings.chartMode = m[1]
            page:Refresh()
        end, "pill")
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", -12, -10) end
        prev = b
        page.modeButtons[m[1]] = b
    end
    page.chart = ns.Chart.Create(chartCard)
    page.chart:SetPoint("TOPLEFT", 6, -46)
    page.chart:SetPoint("BOTTOMRIGHT", -8, 8)

    local split = Card(page)
    split:SetPoint("TOPRIGHT", 0, -142)
    split:SetSize(rightW, 200)
    CardTitle(split, "Breakdown")
    page.splitRows = {}
    for i = 1, 7 do
        local row = CreateFrame("Frame", nil, split)
        row:SetSize(rightW - 32, 20)
        row:SetPoint("TOPLEFT", 16, -40 - (i - 1) * 21)
        row.dot = T.Dot(row, 8, C.gold); row.dot:SetPoint("LEFT", 0, 0)
        row.label = T.Text(row, 12, { color = C.text }); row.label:SetPoint("LEFT", 16, 0)
        row.value = T.Text(row, 12, { justify = "RIGHT" }); row.value:SetPoint("RIGHT", 0, 0)
        page.splitRows[i] = row
    end
    page.splitEmpty = T.Text(split, 12, { color = C.faint, text = Tr("No gold movement in this period.") })
    page.splitEmpty:SetPoint("TOPLEFT", 16, -42)

    local top = Card(page)
    top:SetPoint("TOPRIGHT", split, "BOTTOMRIGHT", 0, -gap)
    top:SetPoint("BOTTOMLEFT", page, "BOTTOMRIGHT", -rightW, 0)
    CardTitle(top, "Top AH sales")
    page.topRows = {}
    for i = 1, 6 do
        local row = CreateFrame("Frame", nil, top)
        row:SetSize(rightW - 32, 20)
        row:SetPoint("TOPLEFT", 16, -40 - (i - 1) * 21)
        row.rank = T.Text(row, 11, { color = C.gold, bold = true }); row.rank:SetPoint("LEFT", 0, 0)
        row.label = T.Text(row, 12); row.label:SetPoint("LEFT", 18, 0); row.label:SetWidth(132)
        row.qty = T.Text(row, 11, { color = C.faint }); row.qty:SetPoint("LEFT", 154, 0)
        row.value = T.Text(row, 12, { justify = "RIGHT" }); row.value:SetPoint("RIGHT", 0, 0)
        page.topRows[i] = row
    end
    page.topEmpty = T.Text(top, 12, { color = C.faint, wrap = true,
        text = Tr("Your sales show up here as soon as you collect AH gold from your mailbox.") })
    page.topEmpty:SetPoint("TOPLEFT", 16, -42)
    page.topEmpty:SetWidth(rightW - 32)

    function page:Refresh()
        local t0, range = RangeStart()
        for k, b in pairs(self.rangeButtons) do b:SetSelected(k == range.key) end
        self.period:SetText(range.desc)
        local st = L.Stats(t0)
        local total = L.TotalMoney()
        local series = L.BalanceSeries(t0, time(), 2)
        local startBal = series[1] and series[1][2] or total

        local c = self.cards
        c[1].value:SetText(ns.FormatMoney(total, { iconSize = 16 }))
        c[1].sub:SetText(ns.FormatMoney(total - startBal, { sign = true, color = true, iconSize = 10 }) ..
            Tr("  |cff615f5cthis period|r"))
        -- Résultat du commerce (HV + marchand) ; le stock acheté mais pas encore vendu est montré à côté.
        c[2].value:SetText(ns.FormatMoney(st.trade, { sign = true, color = true, iconSize = 16 }))
        c[2].sub:SetText(Tr("bought ") .. ns.FormatMoney(-st.bought, { iconSize = 10 }) .. Tr("  ·  fees ") .. ns.FormatMoney(st.fees, { iconSize = 10 }))
        local sv, sn = UI.StockValue()
        c[3].value:SetText(ns.FormatMoney(sv, { iconSize = 16 }))
        c[3].sub:SetText(sn > 0 and (Tr("%d items, all characters, at today's prices")):format(sn) or "nothing in stock")
        c[4].value:SetText(ns.FormatMoney(st.sold, { iconSize = 16 }))
        c[4].sub:SetText(st.soldCount == 0 and "no sales" or
            (st.soldCount .. (st.soldCount > 1 and " sales" or " sale") .. Tr(" (AH + vendor)")))

        local mode = ns.db.settings.chartMode
        for k, b in pairs(self.modeButtons) do b:SetSelected(k == mode) end
        local N = 90
        if mode == "ahprofit" then
            self.chartTitle:SetText(Tr("Cumulative AH profit"))
            self.chart:SetData(L.AHProfitSeries(t0, time(), N), { zeroLine = true, color = C.pos, hideFlat = true,
                emptyText = "No AH activity in this period.\nSell, buy, post: it all gets counted here." })
        else
            self.chartTitle:SetText(Tr("Gold over time"))
            self.chart:SetData(L.BalanceSeries(t0, time(), N), { hideFlat = true,
                emptyText = "The tax office just opened your file.\nThe curve will grow as you earn and spend." })
        end

        -- Répartition
        local rows = {}
        for k, v in pairs(st.byCat) do if v ~= 0 then rows[#rows + 1] = { k = k, v = v } end end
        table.sort(rows, function(a, b) return math.abs(a.v) > math.abs(b.v) end)
        for i, row in ipairs(self.splitRows) do
            local r = rows[i]
            if r then
                local cat = ns.CATEGORIES[r.k] or ns.CATEGORIES.other
                row.dot:SetVertexColor(cat.color[1], cat.color[2], cat.color[3], 1)
                row.label:SetText(cat.label)
                row.value:SetText(ns.FormatMoney(r.v, { sign = true, color = true, short = true, iconSize = 11 }))
                row:Show()
            else
                row:Hide()
            end
        end
        self.splitEmpty:SetShown(#rows == 0)

        -- Meilleures ventes
        for i, row in ipairs(self.topRows) do
            local it = st.top[i]
            if it then
                row.rank:SetText(i)
                row.label:SetText(it.name)
                row.qty:SetText("×" .. it.qty)
                row.value:SetText(ns.FormatMoney(it.total, { short = true, iconSize = 11 }))
                row:Show()
            else
                row:Hide()
            end
        end
        self.topEmpty:SetShown(#st.top == 0)
    end
end

-- ------------------------------------------------------------ page Transactions
local FILTERS = {
    { key = "all",    label = Tr("All") },
    { key = "ah",     label = Tr("Auction House") },
    { key = "vendor", label = Tr("Vendors") },
    { key = "loot",   label = Tr("Loot") },
    { key = "quest",  label = Tr("Quests") },
    { key = "other",  label = Tr("Other") },
}

local function BuildTransactions(page)
    local title = T.Text(page, 20, { bold = true, text = Tr("Transactions") })
    title:SetPoint("TOPLEFT", 0, -2)
    page.count = T.Text(page, 12, { color = C.muted })
    page.count:SetPoint("LEFT", title, "RIGHT", 12, -1)

    page.filter = "all"
    page.filterButtons = {}
    local prev
    for i = #FILTERS, 1, -1 do
        local f = FILTERS[i]
        local b = T.Button(page, f.label, 0, 26, function()
            page.filter = f.key; page.offset = 0; page:Refresh()
        end, "pill")
        b:SetWidth(b.text:GetStringWidth() + 26)
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", 0, 0) end
        prev = b
        page.filterButtons[f.key] = b
    end

    local list = Card(page)
    list:SetPoint("TOPLEFT", 0, -42)
    list:SetPoint("BOTTOMRIGHT", 0, 0)
    local cols = {
        { "Date", 16, 96, "LEFT" }, { "Character", 116, 130, "LEFT" }, { "Category", 252, 150, "LEFT" },
        { "Details", 408, 300, "LEFT" },
    }
    for _, col in ipairs(cols) do
        local h = T.Text(list, 11, { color = C.faint, bold = true, text = col[1] })
        h:SetPoint("TOPLEFT", col[2], -14)
    end
    local hm = T.Text(list, 11, { color = C.faint, bold = true, text = Tr("Amount"), justify = "RIGHT" })
    hm:SetPoint("TOPRIGHT", -30, -14)
    local div = T.Divider(list)
    div:SetPoint("TOPLEFT", 12, -34); div:SetPoint("TOPRIGHT", -12, -34)

    local ROW_H = 24
    page.rows = {}
    page.offset = 0
    local visible = 0
    local function EnsureRows()
        local h = list:GetHeight() - 46
        visible = math.max(1, math.floor(h / ROW_H))
        for i = #page.rows + 1, visible do
            local r = CreateFrame("Frame", nil, list)
            r:SetHeight(ROW_H)
            r:SetPoint("TOPLEFT", 8, -38 - (i - 1) * ROW_H)
            r:SetPoint("TOPRIGHT", -22, -38 - (i - 1) * ROW_H)
            r.bg = r:CreateTexture(nil, "BACKGROUND", nil, 1)
            r.bg:SetTexture(T.WHITE); r.bg:SetAllPoints()
            r.bg:SetVertexColor(1, 1, 1, i % 2 == 0 and 0.018 or 0)
            r.date = T.Text(r, 12, { color = C.muted }); r.date:SetPoint("LEFT", 8, 0)
            r.char = T.Text(r, 12); r.char:SetPoint("LEFT", 108, 0); r.char:SetWidth(128)
            r.dot = T.Dot(r, 7, C.gold); r.dot:SetPoint("LEFT", 244, 0)
            r.cat = T.Text(r, 12); r.cat:SetPoint("LEFT", 258, 0)
            r.detail = T.Text(r, 12, { color = C.muted }); r.detail:SetPoint("LEFT", 400, 0); r.detail:SetWidth(310)
            r.amount = T.Text(r, 12, { justify = "RIGHT" }); r.amount:SetPoint("RIGHT", -8, 0)
            page.rows[i] = r
        end
    end

    -- Barre de défilement fine
    local track = CreateFrame("Frame", nil, list)
    track:SetPoint("TOPRIGHT", -8, -40); track:SetPoint("BOTTOMRIGHT", -8, 10); track:SetWidth(4)
    T.Rounded(track, { 1, 1, 1, 0.04 }, 2, "BACKGROUND")
    local thumb = CreateFrame("Frame", nil, track)
    thumb:SetWidth(4)
    T.Rounded(thumb, { C.gold[1], C.gold[2], C.gold[3], 0.55 }, 2, "ARTWORK")

    page.empty = T.Text(list, 13, { color = C.faint, justify = "CENTER",
        text = Tr("No transactions yet.") })
    page.empty:SetPoint("CENTER", 0, 0)

    local filtered = {}
    local function Collect()
        wipe(filtered)
        local list_ = ns.db.tx
        for i = #list_, 1, -1 do
            local tx = list_[i]
            local cat = ns.CATEGORIES[tx.k] or ns.CATEGORIES.other
            if page.filter == "all" or cat.group == page.filter then filtered[#filtered + 1] = tx end
        end
    end

    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        local maxOff = math.max(0, #filtered - visible)
        page.offset = math.min(maxOff, math.max(0, page.offset - delta * 3))
        page:Draw()
    end)

    function page:Draw()
        EnsureRows()
        for i = 1, #self.rows do
            local r = self.rows[i]
            local tx = (i <= visible) and filtered[self.offset + i]
            if tx then
                local cat = ns.CATEGORIES[tx.k] or ns.CATEGORIES.other
                r.date:SetText(date("%d/%m %H:%M", tx.t))
                local ch = ns.db.chars[tx.c]
                r.char:SetText(ch and ch.name or "?")
                r.char:SetTextColor(ns.ClassColor(ch and ch.class))
                r.dot:SetVertexColor(cat.color[1], cat.color[2], cat.color[3], 1)
                r.cat:SetText(cat.label)
                local d = tx.i or ""
                if tx.q and tx.q > 1 then d = d .. Tr("  |cff615f5c×") .. tx.q .. "|r" end
                if tx.who and tx.who ~= "" and tx.k ~= "mail" then d = d .. Tr("  |cff615f5c(") .. tx.who .. ")|r"
                elseif tx.k == "mail" and tx.who then d = tx.who .. (tx.i and ("  |cff615f5c" .. tx.i .. "|r") or "") end
                r.detail:SetText(d)
                r.amount:SetText(ns.FormatMoney(tx.a, { sign = true, color = true, iconSize = 11 }))
                r:Show()
            else
                r:Hide()
            end
        end
        self.empty:SetShown(#filtered == 0)
        local total = #filtered
        if total > visible then
            local h = track:GetHeight()
            local th = math.max(24, h * visible / total)
            thumb:SetHeight(th)
            thumb:ClearAllPoints()
            thumb:SetPoint("TOP", track, "TOP", 0, -(h - th) * self.offset / (total - visible))
            track:Show()
        else
            track:Hide()
        end
    end

    function page:Refresh()
        for k, b in pairs(self.filterButtons) do b:SetSelected(k == self.filter) end
        Collect()
        self.count:SetText(#filtered .. (#filtered > 1 and " transactions" or " transaction"))
        self.offset = math.min(self.offset, math.max(0, #filtered - visible))
        self:Draw()
    end
end

-- ------------------------------------------------------------ page Personnages
local function BuildCharacters(page)
    local title = T.Text(page, 20, { bold = true, text = Tr("Characters") })
    title:SetPoint("TOPLEFT", 0, -2)
    page.sub = T.Text(page, 12, { color = C.muted })
    page.sub:SetPoint("LEFT", title, "RIGHT", 12, -1)

    local list = Card(page)
    list:SetPoint("TOPLEFT", 0, -42)
    list:SetPoint("BOTTOMRIGHT", 0, 0)
    page.rows = {}

    function page:Refresh()
        local chars = {}
        local total = L.TotalMoney()
        for key, c in pairs(ns.db.chars) do
            local money = (key == L.CharKey()) and GetMoney() or (c.money or 0)
            chars[#chars + 1] = { key = key, c = c, money = money }
        end
        table.sort(chars, function(a, b) return a.money > b.money end)
        local left = ns.Setup and ns.Setup.Remaining() or 0
        self.sub:SetText(#chars .. (#chars > 1 and " characters" or " character")
            .. (left > 0 and (Tr("  ·  |cffe0a83dsetup: %d step%s left|r")):format(left, left > 1 and "s" or "") or "  ·  |cff5cd173setup complete|r")
            .. Tr("   |cff8a877f(orange profession: open it once on that character)|r"))
        local crafter = ns.Queue and ns.Queue.Crafter()
        local bank = ns.db.settings.bankChar
        for i, e in ipairs(chars) do
            local r = self.rows[i]
            if not r then
                r = CreateFrame("Frame", nil, list)
                r:SetHeight(54)
                r:SetPoint("TOPLEFT", 12, -12 - (i - 1) * 58)
                r:SetPoint("TOPRIGHT", -12, -12 - (i - 1) * 58)
                T.Surface(r, C.surface2, 8)
                r.name = T.Text(r, 14, { bold = true }); r.name:SetPoint("TOPLEFT", 14, -8)
                r.realm = T.Text(r, 11, { color = C.faint }); r.realm:SetPoint("LEFT", r.name, "RIGHT", 10, -1)
                -- Ligne 2 : métiers sur toute la largeur.
                r.profs = T.Text(r, 11, { color = C.muted }); r.profs:SetPoint("TOPLEFT", 14, -32)
                r.profs:SetPoint("RIGHT", r, "RIGHT", -14, 0); r.profs:SetWordWrap(false)
                r.money = T.Text(r, 14, { bold = true, justify = "RIGHT" }); r.money:SetPoint("TOPRIGHT", -14, -9)
                r.seen = T.Text(r, 11, { color = C.faint }); r.seen:SetPoint("LEFT", r.realm, "RIGHT", 0, 0)
                -- Rôles en un clic.
                r.bankB = T.Button(r, Tr("Bank"), 70, 22, function()
                    ns.db.settings.bankChar = (ns.db.settings.bankChar ~= r.key) and r.key or nil
                    if ns.Routine then ns.Routine.Refresh() end
                    ns.Fire("CHARS_CHANGED"); page:Refresh()
                end, "pill")
                r.bankB:SetPoint("TOPRIGHT", r, "TOPRIGHT", -150, -6)
                r.craftB = T.Button(r, Tr("Crafter"), 70, 22, function()
                    ns.Queue.SetCrafter(r.key, not ns.Queue.IsCrafter(r.key))
                    if ns.Routine then ns.Routine.Refresh() end
                    ns.Fire("CHARS_CHANGED"); page:Refresh()
                end, "pill")
                r.craftB:SetPoint("RIGHT", r.bankB, "LEFT", -6, 0)
                r.craftB.tooltip = Tr("Characters who craft (several allowed). Each one has its own queue and shopping list; your bank shops for all of them.")
                r.bankB.tooltip = Tr("The character who buys reagents, posts and collects at the AH. Crafts are mailed to it.")
                self.rows[i] = r
            end
            r.key = e.key
            r.name:SetText(e.c.full or e.c.name or "?")
            r.name:SetTextColor(ns.ClassColor(e.c.class))
            r.realm:SetText((e.c.level and ("lvl " .. e.c.level .. "  ·  ") or "") .. ns.PrettyRealm(e.c.realm)
                .. (e.key == L.CharKey() and "  ·  |cffe0a83donline|r" or ""))
            -- Métiers : ✓ recettes lues, ⚠ à ouvrir une fois.
            local parts = {}
            for _, p in ipairs(e.c.profs or {}) do
                local seen = p.gather or (ns.db.profChars and ns.db.profChars[p.name] and ns.db.profChars[p.name][e.key])
                parts[#parts + 1] = (seen and "" or "|cffe0a83d") .. p.name .. (p.rank and (" " .. p.rank) or "")
                    .. (seen and "" or "|r")
            end
            local warn = not e.c.full and "   |cffe0a83dfull name unknown (press C)|r" or ""
            r.profs:SetText((#parts > 0 and table.concat(parts, "  ·  ") or (e.c.profs and "no profession" or "|cff615f5clog in once to read professions|r")) .. warn)
            r.money:SetText(ns.FormatMoney(e.money, { iconSize = 13 }))
            local share = total > 0 and e.money / total or 0
            r.seen:SetText(e.c.lastSeen and ("  ·  seen " .. date("%d/%m %H:%M", e.c.lastSeen)) or "")
            r.craftB:SetSelected(ns.Queue.IsCrafter(e.key))
            r.bankB:SetSelected(e.key == bank)
            r:SetShown(i <= 8)
        end
        for i = #chars + 1, #self.rows do self.rows[i]:Hide() end
    end
end

-- ------------------------------------------------------------ page Réglages
local function BuildSettings(page)
    local title = T.Text(page, 20, { bold = true, text = Tr("Settings") })
    title:SetPoint("TOPLEFT", 0, -2)
    page.items = {}
    local cols = { Card(page), Card(page) }
    cols[1]:SetPoint("TOPLEFT", 0, -42); cols[1]:SetPoint("BOTTOMRIGHT", page, "BOTTOM", -6, 0)
    cols[2]:SetPoint("TOPLEFT", page, "TOP", 6, -42); cols[2]:SetPoint("BOTTOMRIGHT", 0, 0)
    local y = { -16, -16 }
    local function Head(col, text)
        local h = T.Text(cols[col], 13, { bold = true, color = C.gold, text = Tr(text) })
        h:SetPoint("TOPLEFT", 16, y[col]); y[col] = y[col] - 30
    end
    local function Row(col, label, tip)
        local l = T.Text(cols[col], 12, { text = Tr(label) }); l:SetPoint("TOPLEFT", 16, y[col] - 4)
        local hit = CreateFrame("Frame", nil, cols[col]); hit:SetAllPoints(l); hit:EnableMouse(true)
        if tip then
            hit:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine(Tr(tip), 1, 1, 1, true); GameTooltip:Show()
            end)
            hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        local yy = y[col]; y[col] = y[col] - 36
        return yy
    end
    -- Interrupteur On/Off
    local function Toggle(col, label, get, set, tip)
        local yy = Row(col, label, tip)
        local b
        b = T.Button(cols[col], "", 64, 24, function() set(not get()); page:Refresh() end, "pill")
        b:SetPoint("TOPRIGHT", -16, yy)
        page.items[#page.items + 1] = function() b.text:SetText(get() and Tr("On") or Tr("Off")); b:SetSelected(get()) end
    end
    -- Valeur avec − / +
    local function Stepper(col, label, get, set, step, fmt, tip)
        local yy = Row(col, label, tip)
        local v = T.Text(cols[col], 12, { bold = true, justify = "CENTER" }); v:SetWidth(76)
        v:SetPoint("TOPRIGHT", -44, yy - 4)
        local minus = T.Button(cols[col], "−", 24, 24, function() set(get() - step); page:Refresh() end)
        minus:SetPoint("RIGHT", v, "LEFT", -2, 0)
        local plus = T.Button(cols[col], "+", 24, 24, function() set(get() + step); page:Refresh() end)
        plus:SetPoint("TOPRIGHT", -16, yy)
        page.items[#page.items + 1] = function() v:SetText(fmt(get())) end
    end
    local function R() return ns.Craft.Rules() end
    local function Clamp(k, lo, hi) return function(v) R()[k] = math.max(lo, math.min(hi, v)) end end
    local money = function(v) return ns.FormatMoney(v, { iconSize = 10 }) end
    local pct = function(v) return v .. " %" end
    local plain = function(v) return tostring(v) end
    local st = function() return ns.db.settings end

    Head(1, "General")
    Toggle(1, "Routine opens by itself", function() return st().routineAuto ~= false end,
        function(v) st().routineAuto = v end, "On your bank and crafters only, at the AH and vendors.")
    Toggle(1, "ImpotPointGouv mailbox", function() return st().mailOverlay ~= false end,
        function(v) st().mailOverlay = v end, "Replaces Blizzard's mailbox window with ours.")
    Toggle(1, "Minimap button", function() return not st().minimap.hide end,
        function(v) st().minimap.hide = not v; UI.UpdateMinimap() end)
    Head(1, "Crafting")
    Stepper(1, "Min profit per craft", function() return R().minProfit end, Clamp("minProfit", 0, 1000000), 5, money)
    Stepper(1, "Min margin", function() return R().minMargin end, Clamp("minMargin", 0, 500), 5, pct)
    Stepper(1, "Spend at most", function() return R().budgetPct end, Clamp("budgetPct", 5, 100), 5, pct,
        "Share of your total gold the craft queue can spend on reagents.")
    Stepper(1, "Crafts for the vendor (per session)", function() return R().vendorCap end, Clamp("vendorCap", 0, 500), 10, plain)
    Toggle(1, "White gear: vendor price only", function() return R().ignoreWhiteGear end,
        function(v) R().ignoreWhiteGear = v end, "White gear rarely sells at the AH.")

    Head(2, "Selling at the AH")
    local DUR = { "Short", "Medium", "Long" }
    Stepper(2, "Auction duration", function() return ns.Sell and ns.Sell.Rules().postDuration or 3 end,
        function(v) R().postDuration = math.max(1, math.min(3, v)) end, 1, function(v) return Tr(DUR[v] or "?") end)
    Stepper(2, "Max items per post (gear, bags)", function() return ns.Sell and ns.Sell.Rules().postCap or 10 end,
        Clamp("postCap", 1, 100), 1, plain, "Stackable items are always posted as one stack.")
    Stepper(2, "Stock target cap", function() return R().maxQty end, Clamp("maxQty", 1, 1000), 10, plain,
        "Highest stock the adaptive target can reach for an item that sells well.")
    Toggle(2, "Warn when vendoring AH-worthy loot", function() return st().vendorHints ~= false end,
        function(v) st().vendorHints = v end, "At the vendor: a tooltip line and a chat line when an item is worth much more at the AH. /ipg sold for the week.")
    Toggle(2, "Share scan prices with Auctionator", function() return st().shareAuctionator ~= false end,
        function(v) st().shareAuctionator = v end, "Each item scanned here also updates Auctionator's price, so its tooltip stays in sync.")
    Head(2, "Data")
    local setupB = T.Button(cols[2], Tr("Setup guide"), 140, 28, function() ns.Setup.Show() end)
    setupB:SetPoint("TOPLEFT", 16, y[2]); y[2] = y[2] - 38
    local reset = T.Button(cols[2], Tr("Reset all data"), 140, 28, function() StaticPopup_Show("IMPOTPOINTGOUV_RESET") end)
    reset:SetPoint("TOPLEFT", 16, y[2])
    reset.text:SetTextColor(unpack(C.neg))

    function page:Refresh() for _, f in ipairs(self.items) do f() end end
end

-- ------------------------------------------------------------ construction
local function Build()
    frame = CreateFrame("Frame", "ImpotPointGouvFrame", UIParent)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    T.Surface(frame, C.window, 14, { 1, 1, 1, 0.09 })
    tinsert(UISpecialFrames, "ImpotPointGouvFrame")

    -- En-tête (zone de déplacement)
    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(56)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() frame:StartMoving() end)
    header:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
    local hd = T.Divider(header, 0.07)
    hd:SetPoint("BOTTOMLEFT", 0, 0); hd:SetPoint("BOTTOMRIGHT", 0, 0)

    local icon = header:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ns.MEDIA .. Tr("icon.tga"))
    icon:SetSize(30, 30)
    icon:SetPoint("LEFT", PAD, 0)
    local name = T.Text(header, 17, { bold = true, text = Tr("|cffe0a83dImpot|r|cffece6d6PointGouv|r") })
    name:SetPoint("LEFT", icon, "RIGHT", 10, 0)

    local close = T.CloseButton(header, function() frame:Hide() end)
    close:SetPoint("RIGHT", -12, 0)
    local deB = T.Button(header, Tr("Disenchant"), 96, 26, function() ns.Destroy.Toggle() end)
    deB:SetPoint("RIGHT", close, "LEFT", -10, 0)
    deB.tooltip = Tr("Disenchant the greens in your bags, one key press each.")
    local rtB = T.Button(header, Tr("Routine"), 84, 26, function() ns.Routine.Toggle() end)
    rtB:SetPoint("RIGHT", deB, "LEFT", -6, 0)
    -- Disenchant seulement sur un personnage enchanteur ; sinon Routine prend sa place.
    frame.deB, frame.rtB, frame.closeB = deB, rtB, close
    rtB.tooltip = Tr("Your daily loop: craft queue, shopping list, Auctionator export, mail buttons.")

    local tabDefs = {
        { "bilan", "Overview" }, { "lists", "Lists" }, { "market", "Market" }, { "stock", "Stock" }, { "tx", "History" },
        { "chars", "Characters" }, { "settings", "Settings" },
    }
    local x = 226
    for _, d in ipairs(tabDefs) do
        local t = T.Tab(header, Tr(d[2]), function() ShowPage(d[1]) end)
        t:SetPoint("BOTTOMLEFT", x, 0)
        x = x + t:GetWidth()
        if d[3] then t.disabled = true; t.tooltip = d[3]; t:SetSelected(false) end
        tabs[d[1]] = t
    end

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", PAD, -56 - PAD)
    content:SetPoint("BOTTOMRIGHT", -PAD, 34)

    local function Page(key, builder)
        local p = CreateFrame("Frame", nil, content)
        p:SetAllPoints()
        p:Hide()
        builder(p)
        pages[key] = p
    end
    Page("bilan", BuildBilan)
    Page("tx", BuildTransactions)
    Page("chars", BuildCharacters)
    Page("market", ns.Market.BuildPage)
    Page("stock", ns.Stock.BuildPage)
    Page("lists", ns.ListsUI.BuildPage)
    Page("settings", BuildSettings)

    frame.footer = T.Text(frame, 11, { color = C.faint })
    frame.footer:SetPoint("BOTTOMLEFT", PAD, 12)
    local ver = T.Text(frame, 11, { color = C.faint, justify = "RIGHT", text = "v" .. ns.version })
    ver:SetPoint("BOTTOMRIGHT", -PAD, 12)

    frame:SetScript("OnShow", function() UI.Refresh() end)
    if ns.Setup then ns.Setup.AttachBanner(frame) end
    frame:Hide()
end

local RefreshPage
function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    if ns.Profile then ns.Profile.Time("Page:" .. tostring(current), RefreshPage) else RefreshPage() end
end
RefreshPage = function()
    local de = ns.Destroy and ns.Destroy.KnowsDisenchant and ns.Destroy.KnowsDisenchant()
    frame.deB:SetShown(de and true or false)
    frame.rtB:ClearAllPoints()
    if de then frame.rtB:SetPoint("RIGHT", frame.deB, "LEFT", -6, 0) else frame.rtB:SetPoint("RIGHT", frame.closeB, "LEFT", -10, 0) end
    local nChars = 0
    for _ in pairs(ns.db.chars) do nChars = nChars + 1 end
    local first = L.FirstTime()
    frame.footer:SetText((Tr("Tracking since %s")):format(first and date("%d/%m/%Y", first) or "—"))
    if current and pages[current] then pages[current]:Refresh() end
end

local refreshQueued
ns.On("MARKET_CHANGED", function()
    if current == "market" then UI.Refresh()
    elseif current == "lists" and ns.ListsUI and ns.ListsUI.Soon then ns.ListsUI.Soon() end -- limité à une fois toutes les 2 s
end)
ns.On("LEDGER_CHANGED", function()
    if refreshQueued or not frame or not frame:IsShown() then return end
    refreshQueued = true
    C_Timer.After(0.25, function() refreshQueued = false; UI.Refresh() end)
end)

function UI.Current() return current end

function UI.Toggle(page)
    if not frame then Build() end
    if frame:IsShown() and not page then frame:Hide(); return end
    frame:Show()
    ShowPage(page or current or "bilan")
end

-- ------------------------------------------------------------ minimap + commandes
local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
local LDB = LibStub and LibStub("LibDataBroker-1.1", true)

function UI.UpdateMinimap()
    if not LDBIcon then return end
    if ns.db.settings.minimap.hide then LDBIcon:Hide(ns.name) else LDBIcon:Show(ns.name) end
end

StaticPopupDialogs["IMPOTPOINTGOUV_RESET"] = {
    text = Tr("ImpotPointGouv: erase all history (transactions, charts, characters)?\nThis cannot be undone."),
    button1 = "Erase all", button2 = "Cancel",
    OnAccept = function() L.Reset(); ns.Print(Tr("history erased. The tax office starts over.")) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

ns.On("LEDGER_READY", function()
    if UI.ready then return end
    UI.ready = true
    if LDB and LDBIcon then
        local obj = LDB:NewDataObject(ns.name, {
            type = "launcher", label = Tr("ImpotPointGouv"), text = Tr("ImpotPointGouv"),
            icon = ns.MEDIA .. Tr("icon.tga"),
            OnClick = function(self, button)
                if button == "RightButton" then UI.Menu(self) else UI.Toggle() end
            end,
            OnTooltipShow = function(tt)
                tt:AddLine(Tr("|cffe0a83dImpot|rPointGouv"))
                tt:AddDoubleLine(Tr("Total gold"), ns.FormatMoney(L.TotalMoney(), { iconSize = 12 }), 0.7, 0.7, 0.7, 1, 1, 1)
                local st = L.Stats(time() - 86400)
                tt:AddDoubleLine(Tr("AH profit (24h)"), ns.FormatMoney(st.ahNet, { sign = true, color = true, iconSize = 12 }),
                    0.7, 0.7, 0.7, 1, 1, 1)
                local left = ns.Setup and ns.Setup.Remaining() or 0
                if left > 0 then tt:AddLine((Tr("Setup: %d step%s left (menu > Setup guide)")):format(left, left > 1 and "s" or ""), 0.88, 0.66, 0.24) end
                tt:AddLine(" ")
                tt:AddLine(Tr("Left-click: overview   ·   Right-click: menu"), 0.55, 0.55, 0.55)
            end,
        })
        LDBIcon:Register(ns.name, obj, ns.db.settings.minimap)
        UI.UpdateMinimap()
    end
    if ns.repairMsg then ns.Print(ns.repairMsg); ns.repairMsg = nil end
    -- Premier lancement (ou mise à jour) avec des étapes manquantes : on montre le guide une fois.
    if ns.Setup and not ns.db.settings.setupShown then
        C_Timer.After(4, function()
            if ns.Setup.Remaining() > 0 then ns.db.settings.setupShown = true; ns.Setup.Show() end
        end)
    end
    if ns.db.settings.firstRun then
        ns.db.settings.firstRun = false
        ns.Print(Tr("the tax office has opened your file. Type |cffece6d6/impot|r or |cffece6d6/ipg|r to see your overview."))
    end
end)

-- ------------------------------------------------------------ menu (clic droit sur l'icône minimap)
local menu
function UI.Menu(anchor)
    if not menu then
        menu = CreateFrame("Frame", "ImpotPointGouvMenu", UIParent)
        menu:SetFrameStrata("DIALOG")
        menu:SetClampedToScreen(true)
        menu:EnableMouse(true)
        T.Surface(menu, C.window, 10, { 1, 1, 1, 0.12 })
        local entries = {
            { "Overview", function() UI.Toggle("bilan") end },
            { "Routine (shopping list)", function() ns.Routine.Toggle() end },
            { "Disenchant", function() ns.Destroy.Toggle() end },
            { "Transactions", function() UI.Toggle("tx") end },
            { "Lists (watch, buy, farm)", function() UI.Toggle("lists") end },
            { "Market (what sells)", function() UI.Toggle("market") end },
            { "Test report", function() ns.Report.Show(30) end },
            { "Characters", function() UI.Toggle("chars") end },
            { "Settings", function() UI.Toggle("settings") end },
            { "Setup guide", function() ns.Setup.Show() end },
        }
        menu:SetSize(220, 16 + #entries * 28)
        for i, e in ipairs(entries) do
            local b = CreateFrame("Button", nil, menu)
            b:SetHeight(26)
            b:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 28); b:SetPoint("TOPRIGHT", -8, -8 - (i - 1) * 28)
            local hl = T.Rounded(b, { 1, 1, 1, 0 }, 6, "BACKGROUND")
            local t = T.Text(b, 12, { text = Tr(e[1]) }); t:SetPoint("LEFT", 10, 0)
            b:SetScript("OnEnter", function() hl:SetColor({ C.gold[1], C.gold[2], C.gold[3], 0.18 }) end)
            b:SetScript("OnLeave", function() hl:SetColor({ 1, 1, 1, 0 }) end)
            b:SetScript("OnClick", function() menu:Hide(); e[2]() end)
        end
        -- Se ferme dès que la souris l'a quitté depuis un moment.
        local away = 0
        menu:SetScript("OnUpdate", function(self, el)
            if self:IsMouseOver(8, -8, -8, 8) then away = 0 else away = away + el end
            if away > 1.2 then self:Hide() end
        end)
        tinsert(UISpecialFrames, "ImpotPointGouvMenu")
    end
    menu:ClearAllPoints()
    menu:SetPoint("TOPRIGHT", anchor or UIParent, anchor and "BOTTOMLEFT" or "CENTER", 0, 0)
    menu:Show()
end

SLASH_IMPOTPOINTGOUV1 = "/impot"
SLASH_IMPOTPOINTGOUV2 = "/ipg"
SlashCmdList.IMPOTPOINTGOUV = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local itemArg = msg:match("^item%s+(.+)$")
    if itemArg or msg == "item" then ns.History.Command(itemArg); return end
    if msg == "tx" or msg == "transactions" then UI.Toggle("tx")
    elseif msg == "persos" or msg == "chars" then UI.Toggle("chars")
    elseif msg == "vendor" then
        ns.db.settings.autoVendorBuy = ns.db.settings.autoVendorBuy == false
        ns.Print(Tr("auto-buy of vendor reagents ") .. (ns.db.settings.autoVendorBuy and "on." or "off."))
    elseif msg == "list" or msg == "routine" then
        ns.Routine.Toggle()
    elseif msg == "lists" or msg == "listes" then
        UI.Toggle("lists"); ns.Lists.Diag()
    elseif msg:match("^price") or msg:match("^prix") then
        -- /ipg price (v0.24.0) : même fenêtre que /ipg item.
        ns.History.Command((msg:gsub("^%S+%s*", "")))
    elseif msg:match("^perf") then
        ns.Profile.Report(msg:match("^perf%s+(%S+)"))
    elseif msg == "sold" or msg == "ventes" then
        ns.Track.Report(7)
    elseif msg == "hints" then
        ns.db.settings.vendorHints = ns.db.settings.vendorHints == false
        ns.Print(Tr("\"worth more at the AH\" warnings at the vendor ") .. (ns.db.settings.vendorHints ~= false and "on." or "off."))
    elseif msg == "report" then
        ns.Report.Show(30)
    elseif msg == "de" or msg == "disenchant" then
        ns.Destroy.Toggle()
    elseif msg == "diag" then
        ns.Craft.Diag()
    elseif msg == "profit" then
        ns.db.settings.inlineProfit = ns.db.settings.inlineProfit == false
        ns.Print(Tr("profit in the recipe list ") .. (ns.db.settings.inlineProfit and "shown." or "hidden."))
    elseif msg == "courrier" or msg == "mail" then
        ns.db.settings.mailOverlay = ns.db.settings.mailOverlay == false
        ns.Print(Tr("ImpotPointGouv mailbox ") .. (ns.db.settings.mailOverlay and "enabled." or "disabled (Blizzard mailbox)."))
    elseif msg == "minimap" then
        ns.db.settings.minimap.hide = not ns.db.settings.minimap.hide
        UI.UpdateMinimap()
    else UI.Toggle() end
end
