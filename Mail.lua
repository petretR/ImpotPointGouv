-- ImpotPointGouv : boîte aux lettres maison (liste, synthèse, "Collect all").
--
-- La fenêtre Blizzard reste ouverte mais invisible (la fermer couperait la session de
-- courrier) ; la nôtre la remplace : onglets Inbox (liste, récupération filtrée) et
-- Send (destinataire, or, objets des sacs). "Blizzard mailbox" révèle l'originale.
local _, ns = ...
local Tr = ns.L
local T = ns.Theme
local C = T.C
local M = {}
ns.Mail = M

local W, H = 760, 560
local ROW_H = 40

local KINDS = {
    sale      = { label = Tr("AH sale"),        color = { 0.36, 0.82, 0.45 } },
    pending   = { label = Tr("Sale pending"), color = { 0.88, 0.66, 0.24 } },
    won       = { label = Tr("AH purchase"),        color = { 0.45, 0.70, 0.98 } },
    expired   = { label = Tr("Expired"),          color = { 0.92, 0.58, 0.28 } },
    cancelled = { label = Tr("Cancelled"),          color = { 0.62, 0.60, 0.58 } },
    outbid    = { label = Tr("Outbid"),      color = { 0.55, 0.75, 0.95 } },
    cod       = { label = "C.O.D.",    color = { 0.93, 0.36, 0.32 } },
    gm        = { label = Tr("GM"),              color = { 0.80, 0.55, 0.95 } },
    mail      = { label = Tr("Mail"),        color = { 0.75, 0.74, 0.70 } },
}

local frame, mailOpen, lastCheck = nil, false, 0
local mails = {}
local run -- état de la récupération en cours
local sessionStart

-- ------------------------------------------------------------ lecture boîte
local function FreeSlots()
    local fn = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    if not fn then return 99 end
    local n = 0
    for bag = 0, 4 do
        local free, bagType = fn(bag)
        if free and (bagType == nil or bagType == 0) then n = n + free end
    end
    return n
end

local function ReadMail(i)
    local packageIcon, stationeryIcon, sender, subject, money, cod, daysLeft, itemCount, wasRead, _, _, _, isGM =
        GetInboxHeaderInfo(i)
    local m = {
        index = i, sender = sender or "?", subject = subject or "", money = money or 0, cod = cod or 0,
        daysLeft = daysLeft or 0, itemCount = itemCount or 0, wasRead = wasRead, isGM = isGM,
        icon = packageIcon or stationeryIcon,
    }
    local inv, invItem, invPlayer, invBid
    if GetInboxInvoiceInfo then inv, invItem, invPlayer, invBid = GetInboxInvoiceInfo(i) end
    local kind, subjItem = ns.AuctionMailKind(m.subject)
    if m.cod > 0 then m.kind = "cod"
    elseif isGM then m.kind = "gm"
    elseif inv == "seller" then m.kind = "sale"
    elseif inv == "seller_temp_invoice" then m.kind = "pending"
    elseif inv == "buyer" then m.kind = "won"
    else m.kind = kind or "mail" end
    m.item = invItem or subjItem
    m.who = invPlayer
    m.bid = invBid
    -- Première pièce jointe : icône, nom, qualité, quantité.
    if m.itemCount > 0 and GetInboxItem then
        for a = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
            local name, _, texture, count, quality = GetInboxItem(i, a)
            if name then
                m.attach = m.attach or a
                m.icon = texture or m.icon
                m.item = m.item or name
                m.firstName, m.firstQuality = m.firstName or name, m.firstQuality or quality
                m.qty = (m.qty or 0) + (count or 1)
            end
        end
    end
    if m.kind == "sale" or (m.money > 0 and m.itemCount == 0 and m.kind == "mail") then
        m.icon = m.icon or "Interface\\Icons\\INV_Misc_Coin_01"
    end
    m.sig = table.concat({ m.sender, m.subject, m.money, m.itemCount, math.floor(m.daysLeft * 1000) }, "|")
    return m
end

local function Scan()
    wipe(mails)
    if not GetInboxNumItems then return 0, 0 end
    local n, total = GetInboxNumItems()
    for i = 1, n do mails[i] = ReadMail(i) end
    return n, total or n
end

local function FindSig(sig)
    local n = GetInboxNumItems()
    for i = 1, n do
        local m = ReadMail(i)
        if m.sig == sig then return i end
    end
end

-- ------------------------------------------------------------ récupération
local FILTER = {
    sales = { sale = true },
    buys = { won = true, outbid = true },
    expired = { expired = true, cancelled = true },
    other = { mail = true, pending = true },
}

local function Takeable(m, mode, bagsFull)
    if m.cod > 0 or m.isGM then return false end
    if FILTER[mode] then
        if not FILTER[mode][m.kind] then return false end
        if bagsFull then return m.money > 0 end
        return m.money > 0 or m.itemCount > 0
    end
    if mode == "gold" then return m.money > 0 end
    if bagsFull then return m.money > 0 end
    return m.money > 0 or m.itemCount > 0
end

local function TakeMail(m, mode, bagsFull)
    local i = m.index
    if mode == "gold" or m.itemCount == 0 or bagsFull then
        if m.money > 0 then TakeInboxMoney(i); return true end
        return false
    end
    if AutoLootMailItem then AutoLootMailItem(i); return true end
    if m.money > 0 then TakeInboxMoney(i); return true end
    if m.attach then TakeInboxItem(i, m.attach); return true end
    return false
end

local Step, Finish

local function SetStatus(text) if frame then frame.status:SetText(text or "") end end

function Finish(reason)
    if not run then return end
    local gained = GetMoney() - run.startMoney
    local msg = (Tr("Done: %d mail%s, %s")):format(run.count, run.count > 1 and "s" or "",
        ns.FormatMoney(gained, { sign = true, color = true, iconSize = 11 }))
    if run.bagsFull then msg = msg .. Tr("  ·  |cffed5c52bags full, items left in the mailbox|r") end
    if reason then msg = reason end
    run = nil
    SetStatus(msg)
    M.Refresh()
end

-- Signature d'un courrier pour le sauter : plusieurs ventes identiques ont la même,
-- donc on compte combien de courriers de cette signature sont à sauter.
local function SkipAdd(sig) run.skip[sig] = (run.skip[sig] or 0) + 1 end

-- Un seul minuteur à la fois ; les événements du courrier relancent l'étape tout de suite.
local function Poke(delay)
    if not run or run.timer then return end
    run.timer = true
    local r = run
    C_Timer.After(delay or 0, function()
        if run ~= r then return end
        r.timer = false
        Step()
    end)
end
M.Poke = function() if run and run.pend then Poke(0) end end

-- Rafraîchit la liste au plus deux fois par seconde pendant la récupération.
local function LightRefresh()
    if run and run.lastDraw and GetTime() - run.lastDraw < 0.5 then return end
    if run then run.lastDraw = GetTime() end
    M.Refresh(true)
end

function Step()
    if not run then return end
    if not mailOpen then Finish("Mailbox closed, collection interrupted."); return end
    -- Attendre que le serveur ait traité la dernière action : le courrier a disparu ou s'est vidé.
    local p = run.pend
    if p then
        local n = GetInboxNumItems()
        local done = n < p.n
        if not done and p.i <= n then
            local _, _, _, subject, money, _, _, itemCount = GetInboxHeaderInfo(p.i)
            done = (money or 0) < p.money or (itemCount or 0) < p.items or subject ~= p.subject
        end
        if not done then
            if GetTime() - p.t < 4 then Poke(0.05); return end -- le serveur peut être lent
            SkipAdd(p.sig)
        end
        run.pend = nil
    end
    if run.mode == "all" and not run.bagsFull and FreeSlots() == 0 then run.bagsFull = true end
    local n, total = Scan()
    local seen = {}
    for i = n, 1, -1 do
        local m = mails[i]
        seen[m.sig] = (seen[m.sig] or 0) + 1
        if seen[m.sig] > (run.skip[m.sig] or 0) and Takeable(m, run.mode, run.bagsFull) then
            if TakeMail(m, run.mode, run.bagsFull) then
                run.pend = { i = i, n = n, money = m.money, items = m.itemCount, subject = m.subject,
                    sig = m.sig, t = GetTime() }
                run.count = run.count + 1
                SetStatus((Tr("Collecting… %d  ·  %s")):format(run.count,
                    ns.FormatMoney(GetMoney() - run.startMoney, { sign = true, color = true, iconSize = 11 })))
                LightRefresh()
                Poke(0.05)
                return
            end
            SkipAdd(m.sig)
        end
    end
    M.Refresh(true)
    -- Plus rien de visible : d'autres courriers attendent côté serveur ?
    if total > n then
        local wait = math.max(0, lastCheck + 61 - GetTime())
        SetStatus((Tr("%d mails waiting on the server, refreshing in %d s…")):format(total - n, math.ceil(wait)))
        if not run.waiting then
            run.waiting = true
            C_Timer.After(wait + 0.5, function()
                if not run then return end
                run.waiting = false
                lastCheck = GetTime()
                CheckInbox()
                C_Timer.After(1, Step)
            end)
        end
        return
    end
    -- Courriers sautés parce que le serveur tardait : on refait un passage avant de conclure.
    if next(run.skip) and (run.passes or 0) < 2 then
        run.passes = (run.passes or 0) + 1
        run.skip = {}
        SetStatus(Tr("Checking for mails the server was slow to hand over…"))
        Poke(1)
        return
    end
    Finish()
end

local function StartRun(mode)
    if run then Finish("Collection stopped."); return end
    run = { mode = mode, count = 0, skip = {}, startMoney = GetMoney(), tries = 0 }
    Step()
end
M.Collect = StartRun

-- ------------------------------------------------------------ interface
local function Card(parent)
    local f = CreateFrame("Frame", nil, parent)
    T.Surface(f, C.surface, 10)
    return f
end

-- La fenêtre Blizzard reste ouverte (sinon le courrier se ferme) mais invisible, sous la nôtre.
local function BlizzardVisible(v)
    if not MailFrame then return end
    MailFrame:SetAlpha(v and 1 or 0)
end

local function ShowBlizzard(sendTab)
    if frame then frame:Hide() end
    BlizzardVisible(true)
    if frame and frame.reopen then frame.reopen:Show() end
    if sendTab and MailFrameTab2 then
        if MailFrameTab_OnClick then MailFrameTab_OnClick(nil, 2) else MailFrameTab2:Click() end
    end
end

local function Build()
    frame = CreateFrame("Frame", "ImpotPointGouvMailFrame", UIParent)
    frame:SetSize(W, H)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    T.Surface(frame, C.window, 14, { 1, 1, 1, 0.09 })

    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", 1, -1); header:SetPoint("TOPRIGHT", -1, -1); header:SetHeight(56)
    header:EnableMouse(true); header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() frame:StartMoving() end)
    header:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
    local hd = T.Divider(header, 0.07); hd:SetPoint("BOTTOMLEFT"); hd:SetPoint("BOTTOMRIGHT")
    local icon = header:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ns.MEDIA .. Tr("icon.tga")); icon:SetSize(30, 30); icon:SetPoint("LEFT", 18, 0)
    local title = T.Text(header, 17, { bold = true, text = Tr("Mail") })
    title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, 0)
    local tag = T.Text(header, 11, { color = C.faint, text = Tr("|cffe0a83dImpot|rPointGouv  ·  mailbox") })
    tag:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 10, 0)

    local close = T.CloseButton(header, function()
        if MailFrame and HideUIPanel then HideUIPanel(MailFrame) elseif CloseMail then CloseMail() end
        frame:Hide()
    end)
    close:SetPoint("RIGHT", -12, 0)
    local blizz = T.Button(header, Tr("Blizzard mailbox"), 118, 26, function() ShowBlizzard(false) end)
    blizz:SetPoint("RIGHT", close, "LEFT", -10, 0)
    blizz.tooltip = Tr("Show the original mailbox. An ImpotPointGouv button brings you back here.")
    -- Onglets
    frame.tabs = {}
    local tx = 230
    for _, d in ipairs({ { "inbox", "Inbox" }, { "send", "Send" } }) do
        local t = T.Tab(header, Tr(d[2]), function() M.SetTab(d[1]) end)
        t:SetPoint("BOTTOMLEFT", tx, 0)
        tx = tx + t:GetWidth()
        frame.tabs[d[1]] = t
    end

    -- Cartes de synthèse
    frame.cards = {}
    local labels = { "Gold to collect", "AH sales", "Attached items", "Expired / cancelled" }
    local gap, pad = 12, 18
    local cw = (W - pad * 2 - gap * 3) / 4
    for i, lbl in ipairs(labels) do
        local card = Card(frame)
        card:SetSize(cw, 74)
        card:SetPoint("TOPLEFT", pad + (i - 1) * (cw + gap), -56 - 16)
        card.label = T.Text(card, 11, { color = C.muted, text = lbl }); card.label:SetPoint("TOPLEFT", 14, -12)
        card.value = T.Text(card, 18, { bold = true }); card.value:SetPoint("TOPLEFT", 14, -30)
        card.sub = T.Text(card, 11, { color = C.faint }); card.sub:SetPoint("TOPLEFT", 14, -54)
        frame.cards[i] = card
    end

    -- Récupération ciblée (comme TSM) : seulement un type de courrier.
    frame.filters = {}
    local fx = pad
    local lbl = T.Text(frame, 11, { color = C.faint, text = Tr("Collect only:") })
    lbl:SetPoint("TOPLEFT", pad, -56 - 16 - 74 - 18)
    fx = pad + 80
    for _, d in ipairs({ { "sales", "Sales" }, { "buys", "Purchases" }, { "expired", "Expired / cancelled" }, { "other", "Other mail" } }) do
        local b = T.Button(frame, Tr(d[2]), d[1] == "expired" and 140 or 96, 24, function() StartRun(d[1]) end)
        b:SetPoint("TOPLEFT", fx, -56 - 16 - 74 - 12)
        fx = fx + (d[1] == "expired" and 140 or 96) + 6
        frame.filters[d[1]] = b
    end

    -- Liste
    local list = Card(frame)
    list:SetPoint("TOPLEFT", pad, -56 - 16 - 74 - 12 - 34)
    list:SetPoint("BOTTOMRIGHT", -pad, 64)
    frame.list = list
    local hdrs = { { "Type", 14 }, { "Contents", 158 }, { "From", 420 }, { "Expires", 560 } }
    for _, h in ipairs(hdrs) do
        local fs = T.Text(list, 11, { bold = true, color = C.faint, text = h[1] }); fs:SetPoint("TOPLEFT", h[2], -12)
    end
    local hm = T.Text(list, 11, { bold = true, color = C.faint, text = Tr("Amount"), justify = "RIGHT" })
    hm:SetPoint("TOPRIGHT", -26, -12)
    local div = T.Divider(list); div:SetPoint("TOPLEFT", 10, -30); div:SetPoint("TOPRIGHT", -10, -30)
    frame.empty = T.Text(list, 13, { color = C.faint, justify = "CENTER", text = Tr("Mailbox empty. Nothing for the tax office to seize.") })
    frame.empty:SetPoint("CENTER")

    frame.rows = {}
    frame.offset = 0
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        local visible = #frame.rows
        frame.offset = math.min(math.max(0, #mails - visible), math.max(0, frame.offset - delta * 2))
        M.Draw()
    end)

    -- Barre du bas
    frame.status = T.Text(frame, 12, { color = C.muted })
    frame.status:SetPoint("BOTTOMLEFT", pad, 24)
    frame.status:SetWidth(380)
    frame.session = T.Text(frame, 11, { color = C.faint })
    frame.session:SetPoint("BOTTOMLEFT", pad, 8)
    frame.takeAll = T.Button(frame, Tr("Collect all"), 170, 34, function() StartRun("all") end)
    frame.takeAll:SetPoint("BOTTOMRIGHT", -pad, 16)
    frame.takeAll.tooltip = Tr("Takes the gold and items from every mail (except C.O.D.).")
    frame.takeGold = T.Button(frame, Tr("Collect gold"), 130, 34, function() StartRun("gold") end)
    frame.takeGold:SetPoint("RIGHT", frame.takeAll, "LEFT", -8, 0)
    frame.takeGold.tooltip = Tr("Takes only the gold: items stay in the mailbox.")

    M.BuildSend(frame)

    -- Bouton pour revenir depuis la boîte Blizzard
    if MailFrame then
        local reopen
        reopen = T.Button(MailFrame, Tr("ImpotPointGouv"), 120, 22, function()
            reopen:Hide(); M.ShowOverlay()
        end, "primary")
        reopen:SetPoint("TOPRIGHT", MailFrame, "TOPRIGHT", -60, -4)
        reopen:SetFrameLevel((MailFrame:GetFrameLevel() or 1) + 10)
        reopen:Hide()
        frame.reopen = reopen
    end
    frame:Hide()
end

local function EnsureRows()
    local h = frame.list:GetHeight() - 38
    local visible = math.max(1, math.floor(h / ROW_H))
    for i = #frame.rows + 1, visible do
        local r = CreateFrame("Button", nil, frame.list)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", 6, -34 - (i - 1) * ROW_H)
        r:SetPoint("TOPRIGHT", -18, -34 - (i - 1) * ROW_H)
        r.hl = T.Rounded(r, { 1, 1, 1, 0 }, 6, "BACKGROUND", 1)
        r.badgeBg = CreateFrame("Frame", nil, r)
        r.badgeBg:SetSize(112, 20); r.badgeBg:SetPoint("LEFT", 8, 0)
        r.badgeFill = T.Rounded(r.badgeBg, { 1, 1, 1, 0.1 }, 6, "ARTWORK")
        r.badge = T.Text(r.badgeBg, 11, { bold = true, justify = "CENTER" }); r.badge:SetPoint("CENTER")
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(28, 28); r.icon:SetPoint("LEFT", 132, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.title = T.Text(r, 12, { bold = true }); r.title:SetPoint("TOPLEFT", 168, -6); r.title:SetWidth(240)
        r.desc = T.Text(r, 11, { color = C.faint }); r.desc:SetPoint("BOTTOMLEFT", 168, 6); r.desc:SetWidth(240)
        r.from = T.Text(r, 12, { color = C.muted }); r.from:SetPoint("LEFT", 414, 0); r.from:SetWidth(134)
        r.exp = T.Text(r, 12); r.exp:SetPoint("LEFT", 554, 0)
        r.amount = T.Text(r, 13, { bold = true, justify = "RIGHT" }); r.amount:SetPoint("RIGHT", -8, 0)
        r:SetScript("OnEnter", function(self)
            self.hl:SetColor({ 1, 1, 1, 0.045 })
            if self.mail and self.mail.attach and GameTooltip.SetInboxItem then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetInboxItem(self.mail.index, self.mail.attach)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(Tr("Click: collect this mail"), 0.88, 0.66, 0.24)
                GameTooltip:Show()
            elseif self.mail then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(self.mail.subject, 1, 1, 1, true)
                GameTooltip:AddLine(Tr("Click: collect this mail"), 0.88, 0.66, 0.24)
                GameTooltip:Show()
            end
        end)
        r:SetScript("OnLeave", function(self) self.hl:SetColor({ 1, 1, 1, 0 }); GameTooltip:Hide() end)
        r:SetScript("OnClick", function(self)
            local m = self.mail
            if not m or run then return end
            if m.cod > 0 then
                ns.Print(Tr("C.O.D. mail: open it from the Blizzard mailbox to confirm payment."))
                return
            end
            if not TakeMail(m, "all", FreeSlots() == 0) then
                if m.money == 0 and m.itemCount == 0 then
                    ns.Print(Tr("this mail only contains text: read it from the Blizzard mailbox."))
                else
                    ns.Print(Tr("bags full: cannot take the items."))
                end
            end
            C_Timer.After(0.4, function() M.Refresh() end)
        end)
        frame.rows[i] = r
    end
    for i = visible + 1, #frame.rows do frame.rows[i]:Hide() end
    return visible
end

local function ExpireText(days)
    if days < 1 then return "|cffed5c52< 1d|r" end
    local d = math.floor(days)
    local txt = d .. "d"
    if d <= 3 then return "|cffe0943d" .. txt .. "|r" end
    return txt
end

function M.Draw()
    if not frame or not frame:IsShown() then return end
    local visible = EnsureRows()
    frame.offset = math.min(frame.offset, math.max(0, #mails - visible))
    for i = 1, visible do
        local r = frame.rows[i]
        local m = mails[frame.offset + i]
        r.mail = m
        if m then
            local k = KINDS[m.kind] or KINDS.mail
            r.badge:SetText(k.label)
            r.badge:SetTextColor(k.color[1], k.color[2], k.color[3])
            r.badgeFill:SetColor({ k.color[1], k.color[2], k.color[3], 0.14 })
            r.icon:SetTexture(m.icon or "Interface\\Icons\\INV_Letter_15")
            local name = m.item or m.subject
            if m.firstQuality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[m.firstQuality] and m.firstName == name then
                local qc = ITEM_QUALITY_COLORS[m.firstQuality]
                r.title:SetTextColor(qc.r, qc.g, qc.b)
            else
                r.title:SetTextColor(unpack(C.text))
            end
            r.title:SetText(name .. ((m.qty and m.qty > 1) and ("  |cff8a877f×" .. m.qty .. "|r") or ""))
            local desc
            if m.kind == "sale" then
                desc = m.who and ("bought by " .. m.who) or "auction sold"
                if m.bid and m.bid > 0 then desc = desc .. Tr("  ·  price ") .. ns.FormatMoney(m.bid, { iconSize = 9 }) end
            elseif m.kind == "pending" then desc = "gold arrives in about an hour"
            elseif m.kind == "expired" then desc = "unsold, item returned"
            elseif m.kind == "cancelled" then desc = "auction cancelled"
            elseif m.kind == "outbid" then desc = "your bid is refunded"
            elseif m.kind == "won" then desc = "item bought at the AH"
            elseif m.itemCount > 1 then desc = m.itemCount .. Tr(" attachments")
            else desc = (m.item and m.subject ~= name) and m.subject or "" end
            r.desc:SetText(desc)
            r.from:SetText(m.sender)
            r.exp:SetText(ExpireText(m.daysLeft))
            if m.cod > 0 then
                r.amount:SetText(Tr("|cffed5c52CR ") .. ns.FormatMoney(-m.cod, { iconSize = 11 }) .. "|r")
            elseif m.money > 0 then
                r.amount:SetText(ns.FormatMoney(m.money, { sign = true, color = true, iconSize = 11 }))
            else
                r.amount:SetText(Tr("|cff615f5c—|r"))
            end
            r:SetAlpha(run and 0.75 or 1)
            r:Show()
        else
            r:Hide()
        end
    end
    frame.empty:SetShown(#mails == 0)
end

function M.Refresh(quiet)
    if not frame or not frame:IsShown() then return end
    local n, total = Scan()
    local gold, salesN, salesSum, items, expired, cancelled = 0, 0, 0, 0, 0, 0
    for _, m in ipairs(mails) do
        if m.cod == 0 then gold = gold + m.money end
        if m.kind == "sale" then salesN = salesN + 1; salesSum = salesSum + m.money end
        items = items + m.itemCount
        if m.kind == "expired" then expired = expired + 1 elseif m.kind == "cancelled" then cancelled = cancelled + 1 end
    end
    local c = frame.cards
    c[1].value:SetText(ns.FormatMoney(gold, { iconSize = 15 }))
    c[1].sub:SetText(n .. (n > 1 and " mails" or " mail") .. (total > n and ("  ·  +" .. (total - n) .. Tr(" waiting")) or ""))
    c[2].value:SetText(salesN)
    c[2].sub:SetText(salesN > 0 and ns.FormatMoney(salesSum, { iconSize = 10 }) or "no sales")
    c[3].value:SetText(items)
    local free = FreeSlots()
    c[3].sub:SetText(free .. (free > 1 and " free bag slots" or " free bag slot"))
    if items > free then c[3].sub:SetText(Tr("|cffed5c52") .. c[3].sub:GetText() .. "|r") end
    c[4].value:SetText(expired + cancelled)
    c[4].sub:SetText(expired .. Tr(" expired") .. (expired > 1 and "s" or "") .. "  ·  " .. cancelled .. Tr(" cancelled") .. (cancelled > 1 and "s" or ""))

    local counts = {}
    for _, m in ipairs(mails) do
        for k, set in pairs(FILTER) do if set[m.kind] and m.cod == 0 then counts[k] = (counts[k] or 0) + 1 end end
    end
    for k, b in pairs(frame.filters) do
        local base = ({ sales = "Sales", buys = "Purchases", expired = "Expired / cancelled", other = "Other mail" })[k]
        b.text:SetText(run and run.mode == k and "Stop" or (base .. ((counts[k] or 0) > 0 and (" (" .. counts[k] .. ")") or "")))
        b:SetDisabled((run ~= nil and run.mode ~= k) or (not run and (counts[k] or 0) == 0))
    end
    frame.takeAll.text:SetText(run and run.mode == "all" and "Stop" or "Collect all")
    frame.takeGold.text:SetText(run and run.mode == "gold" and "Stop" or "Collect gold")
    frame.takeAll:SetDisabled(run ~= nil and run.mode ~= "all")
    frame.takeGold:SetDisabled(run ~= nil and run.mode ~= "gold")
    if sessionStart then
        frame.session:SetText(Tr("Collected since opening: ") ..
            ns.FormatMoney(GetMoney() - sessionStart, { sign = true, color = true, iconSize = 10 }))
    end
    if not run and not quiet and (frame.status:GetText() or "") == "" then
        SetStatus(gold > 0 and "Ready. Click a row to collect just that mail." or "")
    end
    M.Draw()
end

function M.ShowOverlay()
    if not frame then Build() end
    frame:ClearAllPoints()
    if MailFrame and MailFrame:IsShown() then
        frame:SetPoint("TOPLEFT", MailFrame, "TOPLEFT", 0, 0)
    else
        frame:SetPoint("CENTER")
    end
    frame:Show()
    frame:Raise()
    BlizzardVisible(false)
    if frame.reopen then frame.reopen:Hide() end
    frame.offset = 0
    M.SetTab("inbox")
    M.Refresh()
end

-- ------------------------------------------------------------ onglet Send (façon TSM)
-- Destinataire (vos persos en un clic), or, et objets des sacs à cocher ; envoi par lots de 12 pièces jointes.
local basket = {}

local function BagItems()
    local by, list = {}, {}
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + 1)
    for bag = 0, last do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isBound then
                local e = by[info.itemID]
                if not e then
                    e = { id = info.itemID, count = 0, icon = info.iconFileID, quality = info.quality,
                        name = ns.Prices.Name(info.itemID) }
                    by[info.itemID] = e
                    list[#list + 1] = e
                end
                e.count = e.count + (info.stackCount or 1)
            end
        end
    end
    table.sort(list, function(a, b)
        if (basket[a.id] ~= nil) ~= (basket[b.id] ~= nil) then return basket[a.id] ~= nil end
        return a.name < b.name
    end)
    return list
end

local function MakeBox(parent, w)
    local eb = CreateFrame("EditBox", nil, parent)
    eb:SetSize(w, 26)
    eb:SetAutoFocus(false); eb:SetFontObject(ChatFontNormal)
    T.Surface(eb, C.surface2, 6)
    eb:SetTextInsets(8, 8, 0, 0)
    eb:SetScript("OnEscapePressed", eb.ClearFocus)
    eb:SetScript("OnEnterPressed", eb.ClearFocus)
    return eb
end

function M.BuildSend(f)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", 1, -57); p:SetPoint("BOTTOMRIGHT", -1, 1)
    p:SetFrameLevel((f:GetFrameLevel() or 1) + 30)
    p:EnableMouse(true)
    T.Surface(p, C.window, 12)
    f.send = p
    local pad = 18

    -- Colonne gauche : destinataire, or, panier
    local to = T.Text(p, 12, { bold = true, text = Tr("To") }); to:SetPoint("TOPLEFT", pad, -18)
    p.to = MakeBox(p, 250); p.to:SetPoint("TOPLEFT", pad, -38)
    -- Saisie semi-automatique : vos persos (nom complet) et vos destinataires récents.
    p.sug = CreateFrame("Frame", nil, p)
    p.sug:SetPoint("TOPLEFT", p.to, "BOTTOMLEFT", 0, -2); p.sug:SetWidth(250)
    p.sug:SetFrameLevel((p:GetFrameLevel() or 1) + 40)
    T.Surface(p.sug, C.surface2, 6, { 1, 1, 1, 0.12 })
    p.sug.buttons = {}
    for i = 1, 6 do
        local b = CreateFrame("Button", nil, p.sug)
        b:SetHeight(22); b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 22); b:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * 22)
        b.hl = T.Rounded(b, { 1, 1, 1, 0 }, 4, "BACKGROUND", 1)
        b.text = T.Text(b, 12); b.text:SetPoint("LEFT", 6, 0)
        b.tag = T.Text(b, 10, { color = C.faint, justify = "RIGHT" }); b.tag:SetPoint("RIGHT", -6, 0)
        b:SetScript("OnEnter", function(self) self.hl:SetColor({ 1, 1, 1, 0.06 }) end)
        b:SetScript("OnLeave", function(self) self.hl:SetColor({ 1, 1, 1, 0 }) end)
        b:SetScript("OnClick", function(self) p.to:SetText(self.name); p.sug:Hide(); p.to:ClearFocus(); M.DrawSend() end)
        p.sug.buttons[i] = b
    end
    p.sug:Hide()
    p.chips = {}
    for i = 1, 4 do
        local b = T.Button(p, "", 122, 22, function(self) if self.name then p.to:SetText(self.name) end end)
        b:SetPoint("TOPLEFT", pad + ((i - 1) % 2) * 128, -70 - math.floor((i - 1) / 2) * 26)
        p.chips[i] = b
    end
    local gl = T.Text(p, 12, { bold = true, text = Tr("Gold") }); gl:SetPoint("TOPLEFT", pad, -134)
    p.gold = MakeBox(p, 90); p.gold:SetPoint("TOPLEFT", pad, -154); p.gold:SetNumeric(true)
    local gtag = T.Text(p, 11, { color = C.faint, text = "g" }); gtag:SetPoint("LEFT", p.gold, "RIGHT", 4, 0)
    p.silver = MakeBox(p, 60); p.silver:SetPoint("LEFT", p.gold, "RIGHT", 18, 0); p.silver:SetNumeric(true)
    local stag = T.Text(p, 11, { color = C.faint, text = "s" }); stag:SetPoint("LEFT", p.silver, "RIGHT", 4, 0)

    local quick = T.Text(p, 12, { bold = true, text = Tr("Quick fill") }); quick:SetPoint("TOPLEFT", pad, -194)
    p.qCrafts = T.Button(p, Tr("Crafts → bank"), 122, 24, function() M.QuickFill("crafts") end)
    p.qCrafts:SetPoint("TOPLEFT", pad, -214)
    p.qCrafts.tooltip = Tr("Selects what this character crafted to sell (and enchanting mats if it disenchants), minus your keep amounts, and sets your bank as recipient.")
    p.qReag = T.Button(p, Tr("Reagents → crafter"), 122, 24, function() M.QuickFill("reagents") end)
    p.qReag:SetPoint("LEFT", p.qCrafts, "RIGHT", 6, 0)
    p.qReag.tooltip = Tr("Selects the reagents your crafter is missing for the queue, and sets your crafter as recipient.")
    p.qClear = T.Button(p, Tr("Clear"), 70, 24, function() wipe(basket); M.DrawSend() end)
    p.qClear:SetPoint("TOPLEFT", pad, -244)

    p.summary = T.Text(p, 12, { color = C.text, wrap = true, justify = "LEFT" })
    p.summary:SetPoint("TOPLEFT", pad, -282); p.summary:SetWidth(250)
    p.barBg = p:CreateTexture(nil, "ARTWORK"); p.barBg:SetTexture(T.WHITE); p.barBg:SetVertexColor(1, 1, 1, 0.06)
    p.barBg:SetPoint("TOPLEFT", pad, -370); p.barBg:SetSize(250, 6)
    p.bar = p:CreateTexture(nil, "ARTWORK", nil, 1); p.bar:SetTexture(T.WHITE); p.bar:SetVertexColor(unpack(C.gold))
    p.bar:SetPoint("LEFT", p.barBg, "LEFT"); p.bar:SetHeight(6)

    p.status = T.Text(p, 11, { color = C.muted, wrap = true, justify = "LEFT" })
    p.status:SetPoint("BOTTOMLEFT", pad, 64); p.status:SetWidth(250)
    p.go = T.Button(p, Tr("Send"), 250, 36, function() M.DoSend() end, "primary")
    p.go:SetPoint("BOTTOMLEFT", pad, 16)
    for _, eb in ipairs({ p.gold, p.silver }) do
        eb:SetScript("OnTextChanged", function(_, user) if user then M.DrawSend() end end)
    end
    p.to:SetScript("OnTextChanged", function(_, user) if user then M.Suggest(); M.DrawSend() end end)
    p.to:SetScript("OnEditFocusGained", function() M.Suggest() end)
    p.to:SetScript("OnEditFocusLost", function() C_Timer.After(0.2, function() p.sug:Hide() end) end)
    p.to:SetScript("OnEnterPressed", function(self)
        local first = p.sug:IsShown() and p.sug.buttons[1]:IsShown() and p.sug.buttons[1].name
        if first then self:SetText(first) end
        p.sug:Hide(); self:ClearFocus(); M.DrawSend()
    end)
    p.to:SetScript("OnTabPressed", function(self)
        local first = p.sug:IsShown() and p.sug.buttons[1]:IsShown() and p.sug.buttons[1].name
        if first then self:SetText(first); self:SetCursorPosition(#first) end
        p.sug:Hide(); M.DrawSend()
    end)

    -- Colonne droite : objets des sacs (clic = ajouter / retirer)
    local right = Card(p)
    right:SetPoint("TOPLEFT", pad + 270, -14); right:SetPoint("BOTTOMRIGHT", -pad, 16)
    local rt = T.Text(right, 12, { bold = true, text = Tr("Your bags") }); rt:SetPoint("TOPLEFT", 14, -10)
    local rh = T.Text(right, 11, { color = C.faint, text = Tr("click to add / remove · soulbound items are hidden") })
    rh:SetPoint("TOPRIGHT", -14, -11)
    p.rows = {}
    for i = 1, 13 do
        local r = CreateFrame("Button", nil, right)
        r:SetHeight(28)
        r:SetPoint("TOPLEFT", 8, -32 - (i - 1) * 29); r:SetPoint("TOPRIGHT", -8, -32 - (i - 1) * 29)
        r.hl = T.Rounded(r, { 1, 1, 1, 0 }, 6, "BACKGROUND", 1)
        r.check = r:CreateTexture(nil, "ARTWORK"); r.check:SetSize(14, 14); r.check:SetPoint("LEFT", 6, 0)
        r.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(22, 22); r.icon:SetPoint("LEFT", 26, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.name = T.Text(r, 12); r.name:SetPoint("LEFT", 56, 0); r.name:SetWidth(260)
        r.count = T.Text(r, 12, { bold = true, justify = "RIGHT" }); r.count:SetPoint("RIGHT", -8, 0)
        r:SetScript("OnClick", function(self)
            if not self.item then return end
            if basket[self.item.id] then basket[self.item.id] = nil else basket[self.item.id] = self.item.count end
            M.DrawSend()
        end)
        r:SetScript("OnEnter", function(self)
            self.hl:SetColor({ 1, 1, 1, 0.045 })
            if self.item then T.ItemTooltip(self, self.item.id) end
        end)
        r:SetScript("OnLeave", function(self) self.hl:SetColor({ 1, 1, 1, 0 }); GameTooltip:Hide() end)
        p.rows[i] = r
    end
    p.offset = 0
    right:EnableMouseWheel(true)
    right:SetScript("OnMouseWheel", function(_, d)
        p.offset = math.max(0, math.min(math.max(0, #(p.items or {}) - #p.rows), p.offset - d * 3))
        M.DrawSend()
    end)
    p.empty = T.Text(right, 12, { color = C.faint, text = Tr("Nothing mailable in your bags.") }); p.empty:SetPoint("CENTER")
    -- Indique qu'il y a d'autres objets plus bas (molette).
    p.more = T.Text(right, 11, { color = C.gold, justify = "CENTER" }); p.more:SetPoint("BOTTOM", 0, 8)
    p.track = right:CreateTexture(nil, "ARTWORK"); p.track:SetTexture(T.WHITE); p.track:SetVertexColor(1, 1, 1, 0.05)
    p.track:SetPoint("TOPRIGHT", -3, -32); p.track:SetPoint("BOTTOMRIGHT", -3, 28); p.track:SetWidth(3)
    p.thumb = right:CreateTexture(nil, "ARTWORK", nil, 1); p.thumb:SetTexture(T.WHITE); p.thumb:SetVertexColor(unpack(C.gold))
    p.thumb:SetWidth(3)
    p:Hide()
end

-- Destinataires possibles : vos persos (nom complet si connu) puis vos envois récents.
local function Candidates()
    local list, seen = {}, {}
    local me = ns.Ledger.CharKey()
    local RT = ns.Routine
    local function Add(name, tag)
        if not name or name == "" or seen[name:lower()] then return end
        seen[name:lower()] = true
        list[#list + 1] = { name = name, tag = tag }
    end
    for k, c in pairs(ns.db.chars) do
        if k ~= me then
            local role = (RT and k == RT.Bank()) and "bank" or ns.Queue.IsCrafter(k) and "crafter" or "alt"
            Add((RT and RT.CharName(k)) or c.full or c.name, role)
        end
    end
    for _, n in ipairs(ns.db.mailRecent or {}) do Add(n, "recent") end
    return list
end

function M.Suggest()
    local p = frame and frame.send
    if not p then return end
    local q = (p.to:GetText() or ""):lower()
    local shown = 0
    for _, cand in ipairs(Candidates()) do
        local n = cand.name:lower()
        -- Correspond au début du nom, ou au début du nom de famille ("vach" -> Roselyne Vachelot).
        local hit = q == "" or n:find(q, 1, true) == 1 or n:find(" " .. q, 1, true)
        if hit and n ~= q and shown < #p.sug.buttons then
            shown = shown + 1
            local b = p.sug.buttons[shown]
            b.name = cand.name; b.text:SetText(cand.name); b.tag:SetText(cand.tag); b:Show()
        end
    end
    for i = shown + 1, #p.sug.buttons do p.sug.buttons[i]:Hide() end
    p.sug:SetHeight(8 + shown * 22)
    p.sug:SetShown(shown > 0 and p.to:HasFocus())
end

-- Après un envoi réussi : mémorise le destinataire, et apprend le nom complet d'un de vos persos.
local function Remember(name)
    if not name or name == "" then return end
    ns.db.mailRecent = ns.db.mailRecent or {}
    local r = ns.db.mailRecent
    for i = #r, 1, -1 do if r[i]:lower() == name:lower() then table.remove(r, i) end end
    table.insert(r, 1, name)
    while #r > 15 do table.remove(r) end
    if name:find(" ") then
        local first = name:match("^(%S+)")
        for _, c in pairs(ns.db.chars) do
            if c.name and first and c.name:lower() == first:lower() and not c.full then c.full = name end
        end
    end
end

function M.QuickFill(kind)
    local RT, p = ns.Routine, frame.send
    if not RT then return end
    wipe(basket)
    local key = RT.Bank()
    if kind ~= "crafts" then
        -- Le crafteur choisi dans "To" s'il en est un, sinon le premier crafteur qui attend des composants.
        key = nil
        local typed = p.to:GetText() or ""
        for _, k in ipairs(ns.Queue.Crafters()) do
            if RT.CharName(k) == typed then key = k end
        end
        if not key then
            for _, k in ipairs(ns.Queue.Crafters()) do
                if k ~= ns.Ledger.CharKey() and #RT.BagStacks(RT.ReagentsWant(k)) > 0 then key = k; break end
            end
        end
    end
    local want = kind == "crafts" and RT.CraftsWant() or (key and RT.ReagentsWant(key) or {})
    -- Piles entières qui tiennent dans la quantité voulue (même règle que la Routine).
    for _, st in ipairs(RT.BagStacks(want)) do basket[st.id] = (basket[st.id] or 0) + st.count end
    if key then p.to:SetText(RT.CharName(key) or "") end
    p.status:SetText(next(basket) and "" or (kind == "crafts" and "Nothing to send to your bank." or "Your crafter needs nothing from these bags."))
    M.DrawSend()
end

local DrawSendInner
function M.DrawSend()
    local ok, err = pcall(DrawSendInner)
    if not ok and frame and frame.send then
        frame.send.status:SetText(Tr("|cffed5c52") .. tostring(err):gsub("^.-:%d+: ", "") .. "|r")
        frame.send.go.text:SetText(Tr("Send")); frame.send.go:SetDisabled(false)
    end
end
function DrawSendInner()
    local p = frame and frame.send
    if not p or not p:IsShown() then return end
    p.items = BagItems()
    p.stackOf = {}
    for _, st in ipairs(ns.Routine and ns.Routine.BagStacks(basket) or {}) do p.stackOf[st.id] = (p.stackOf[st.id] or 0) + 1 end
    p.offset = math.min(p.offset, math.max(0, #p.items - #p.rows))
    for i, r in ipairs(p.rows) do
        local it = p.items[p.offset + i]
        r.item = it
        if it then
            local sel = basket[it.id]
            r.check:SetShown(sel ~= nil)
            r.icon:SetTexture(it.icon or ns.GetItemIcon(it.id))
            local qc = ITEM_QUALITY_COLORS and it.quality and ITEM_QUALITY_COLORS[it.quality]
            r.name:SetText(it.name)
            if qc then r.name:SetTextColor(qc.r, qc.g, qc.b) else r.name:SetTextColor(unpack(C.text)) end
            local st = sel and p.stackOf and p.stackOf[it.id]
            r.count:SetText((sel and sel < it.count and ("|cffe0a83d" .. sel .. "|r / " .. it.count) or ("×" .. it.count))
                .. (st and ("  |cff8a877f· " .. st .. (st > 1 and " slots" or " slot") .. "|r") or ""))
            r:SetAlpha(sel and 1 or 0.8)
            r:Show()
        else
            r:Hide()
        end
    end
    p.empty:SetShown(#p.items == 0)
    local extra = #p.items - #p.rows
    if extra > 0 then
        local below = #p.items - p.offset - #p.rows
        p.more:SetText(below > 0 and (Tr("%d more below · scroll")):format(below) or "scroll up for more")
        local h = p.track:GetHeight() or 0
        local frac = #p.rows / #p.items
        p.thumb:SetHeight(math.max(12, h * frac))
        p.thumb:ClearAllPoints()
        p.thumb:SetPoint("TOP", p.track, "TOP", 0, -(h - math.max(12, h * frac)) * (p.offset / extra))
    else
        p.more:SetText("")
    end
    p.track:SetShown(extra > 0); p.thumb:SetShown(extra > 0)
    -- Destinataires rapides : banque, crafteur, puis vos autres persos.
    local RT = ns.Routine
    local me = ns.Ledger.CharKey()
    local keys, seen = {}, {}
    local function Add(k) if k and k ~= me and ns.db.chars[k] and not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
    Add(RT and RT.Bank())
    for _, k in ipairs(ns.Queue.Crafters()) do Add(k) end
    for k in pairs(ns.db.chars) do Add(k) end
    for i, b in ipairs(p.chips) do
        local k = keys[i]
        if k then
            local name = RT and RT.CharName(k) or ns.db.chars[k].name
            local role = (RT and k == RT.Bank()) and " (bank)" or ns.Queue.IsCrafter(k) and " (crafter)" or ""
            b.name = name
            b.text:SetText(name)
            b.tooltip = role ~= "" and (name .. role) or name
            b:SetSelected((p.to:GetText() or "") == name)
            b:Show()
        else
            b:Hide()
        end
    end
    local n, stacks = 0, 0
    for id, q in pairs(basket) do n = n + q; stacks = stacks + 1 end
    local money = (tonumber(p.gold:GetText() or "") or 0) * 10000 + (tonumber(p.silver:GetText() or "") or 0) * 100
    -- Pièces jointes = piles dans les sacs (12 par courrier).
    local MAX = ATTACHMENTS_MAX_SEND or 12
    local slots = ns.Routine and ns.Routine.BagStacks(basket) or {}
    local att = #slots
    local mailsN = math.max(1, math.ceil(att / MAX))
    local inLast = att - (mailsN - 1) * MAX
    local left = MAX - inLast
    if stacks == 0 and money == 0 then
        p.summary:SetText((Tr("|cff615f5cPick items on the right, or use Quick fill.|r\n\nAttachments  |cffece6d60 / %d|r")):format(MAX))
    else
        local col = left == 0 and "|cffe0a83d" or "|cffece6d6"
        p.summary:SetText((Tr("%d item%s (%d kind%s)%s\n\nAttachments  %s%d / %d|r%s\n%s")):format(
            n, n == 1 and "" or "s", stacks, stacks == 1 and "" or "s",
            money > 0 and ("  +  " .. ns.FormatMoney(money, { iconSize = 11 })) or "",
            col, inLast, MAX, mailsN > 1 and ("  in mail " .. mailsN) or "",
            mailsN > 1 and (Tr("|cffe0a83d%d mails|r · %d attachments in total")):format(mailsN, att)
                or (left > 0 and (Tr("|cff5cd173%d slot%s left|r in this mail")):format(left, left == 1 and "" or "s") or "|cffe0a83dmail full|r: more goes in a 2nd mail")))
    end
    -- Barre de remplissage du courrier en cours.
    p.bar:SetWidth(math.max(1, p.barBg:GetWidth() * (att == 0 and 0 or inLast / MAX)))
    p.bar:SetShown(att > 0)
    local busy = ns.Routine and ns.Routine.IsSending()
    p.go.text:SetText(busy and "Sending…" or ((p.to:GetText() or "") ~= "" and ("Send to " .. p.to:GetText()) or "Send"))
    p.go:SetDisabled(busy or (stacks == 0 and money == 0) or (p.to:GetText() or "") == "")
end

function M.DoSend()
    local p = frame.send
    local name = (p.to:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local money = (tonumber(p.gold:GetText() or "") or 0) * 10000 + (tonumber(p.silver:GetText() or "") or 0) * 100
    if money > GetMoney() then p.status:SetText(Tr("|cffed5c52Not enough gold.|r")); return end
    local want = {}
    for id, q in pairs(basket) do want[id] = q end
    if ns.Routine.SendTo(name, want, "items", money > 0 and money or nil) then
        p.gold:SetText(""); p.silver:SetText("")
    end
    M.DrawSend()
end

function M.OnSent(msg, name)
    Remember(name)
    wipe(basket)
    if frame and frame.send then frame.send.status:SetText(msg); M.DrawSend() end
end
function M.SendStatus(text)
    if frame and frame.send and frame.send:IsShown() and text then
        frame.send.status:SetText(text)
        C_Timer.After(0, M.DrawSend) -- le bouton ne reste pas sur "Sending…"
    end
end

function M.SetTab(tab)
    if not frame then return end
    for k, t in pairs(frame.tabs) do t:SetSelected(k == tab) end
    frame.send:SetShown(tab == "send")
    if tab == "send" then
        frame.send.status:SetText("")
        M.DrawSend()
    else
        M.Refresh()
    end
end

-- ------------------------------------------------------------ événements
local ev = CreateFrame("Frame")
for _, e in ipairs({ "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "UI_ERROR_MESSAGE", "BAG_UPDATE" }) do
    pcall(ev.RegisterEvent, ev, e)
end
local queued
ev:SetScript("OnEvent", function(_, event, ...)
    if not ns.db then return end
    if event == "MAIL_SHOW" then
        mailOpen = true
        lastCheck = GetTime()
        sessionStart = GetMoney()
        if ns.db.settings.mailOverlay ~= false then
            M.ShowOverlay()
            if frame then SetStatus("") end
        end
    elseif event == "MAIL_CLOSED" then
        mailOpen = false
        if run then Finish("Mailbox closed, collection interrupted.") end
        if frame then frame:Hide(); if frame.reopen then frame.reopen:Hide() end end
        BlizzardVisible(true)
    elseif event == "UI_ERROR_MESSAGE" then
        local a, b = ...
        local msg = type(b) == "string" and b or a
        if run and (msg == ERR_INV_FULL or msg == ERR_ITEM_MAX_COUNT) then run.bagsFull = true end
    elseif (event == "MAIL_INBOX_UPDATE" or event == "BAG_UPDATE") and run then
        M.Poke() -- la récupération avance dès que le serveur répond, et rafraîchit elle-même
    elseif (event == "MAIL_INBOX_UPDATE" or event == "BAG_UPDATE") and frame and frame:IsShown() then
        if queued then return end
        queued = true
        C_Timer.After(0.15, function()
            queued = false
            if frame.send:IsShown() then M.DrawSend() else M.Refresh(true) end
        end)
    end
end)
