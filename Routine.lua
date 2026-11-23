-- ImpotPointGouv : fenêtre "Routine" pour la boucle quotidienne crafteur <-> banque.
--   Crafteur : Queue all -> liste de courses
--   Banque   : liste de courses (cochée au fil des achats) -> export Auctionator -> envoi au crafteur
--   Crafteur : craft / désenchantement -> envoi de tout à la banque
local _, ns = ...
local Tr = ns.L
local T, P, Q, I = ns.Theme, ns.Prices, ns.Queue, ns.Inventory
local C = T.C
local RT = {}
ns.Routine = RT

local W, H, ROWS, QROWS = 460, 640, 7, 4
local frame
local mailOpen, ahOpen, merchantOpen = false, false, false

-- ------------------------------------------------------------ rôles
local function Me() return UnitGUID("player") end
function RT.Bank() return ns.db.settings.bankChar end
local function CharName(key)
    if not key then return nil end
    local c = ns.db.chars[key]
    local over = ns.db.settings.mailNames and ns.db.settings.mailNames[key]
    -- Un nom complet (prénom + nom) l'emporte toujours sur un prénom seul.
    if over and over ~= "" and (over:find(" ") or not (c and c.full)) then return over end
    return c and (c.full or c.name)
end

-- ------------------------------------------------------------ export Auctionator
function RT.ExportAuctionator()
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not api or not api.CreateShoppingList then
        RT.Status(Tr("|cffed5c52Auctionator not found (or too old for shopping list export).|r"))
        return
    end
    local terms = {}
    for _, row in ipairs(Q.Plan().shop) do
        if row.src == "ah" and row.buy > 0 then
            local term
            if api.ConvertToSearchString then
                local ok, res = pcall(api.ConvertToSearchString, "ImpotPointGouv",
                    { searchString = row.name, isExact = true, quantity = row.buy })
                if ok then term = res end
            end
            terms[#terms + 1] = term or ('"' .. row.name .. '"')
        end
    end
    if #terms == 0 then RT.Status(Tr("Nothing to buy at the AH.")); return end
    local listName = "ImpotPointGouv"
    if api.DeleteShoppingList then pcall(api.DeleteShoppingList, "ImpotPointGouv", listName) end
    local ok, err = pcall(api.CreateShoppingList, "ImpotPointGouv", listName, terms)
    if ok then
        RT.Status((Tr("Auctionator list \"%s\" ready (%d items): Auctionator > Shopping > search it.")):format(listName, #terms))
    else
        RT.Status(Tr("|cffed5c52Auctionator refused the list:|r ") .. tostring(err):gsub("^.-:%d+: ", ""))
    end
end

-- ------------------------------------------------------------ envoi par courrier
local sending

local function BagStacks(want)
    local stacks, left = {}, {}
    for id, n in pairs(want) do if n > 0 then left[id] = n end end
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + 1)
    for bag = 0, last do
        local n = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            -- Seulement des piles entières qui tiennent dans ce qu'on veut envoyer (le reste est gardé).
            local cnt = info and (info.stackCount or 1)
            if info and info.itemID and left[info.itemID] and left[info.itemID] >= cnt and not info.isBound then
                stacks[#stacks + 1] = { bag = bag, slot = slot, id = info.itemID, count = cnt }
                left[info.itemID] = left[info.itemID] - cnt
            end
        end
    end
    return stacks
end

-- Whole stacks that fit in `want`, plus, for each item whose quantity is not a sum of whole stacks,
-- one split: { id, count, bag, slot } = take `count` from that stack into a free bag slot.
local function PlanStacks(want)
    local stacks = BagStacks(want)
    local got, used = {}, {}
    for _, st in ipairs(stacks) do
        got[st.id] = (got[st.id] or 0) + st.count
        used[st.bag .. ":" .. st.slot] = true
    end
    local splits = {}
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + 1)
    for id, n in pairs(want) do
        local rest = n - (got[id] or 0)
        if rest > 0 then
            for bag = 0, last do
                local found
                for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
                    local info = C_Container.GetContainerItemInfo(bag, slot)
                    if info and info.itemID == id and not info.isBound and not used[bag .. ":" .. slot]
                        and (info.stackCount or 1) > rest then
                        splits[#splits + 1] = { id = id, count = rest, bag = bag, slot = slot }
                        found = true
                        break
                    end
                end
                if found then break end
            end
        end
    end
    return stacks, splits
end

-- Empty slots in general-purpose bags (where a split stack can go).
local function FreeBagSlots()
    local free = {}
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + 1)
    for bag = 0, last do
        local _, bagType = C_Container.GetContainerNumFreeSlots(bag)
        if bagType == nil or bagType == 0 then
            for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
                if not C_Container.GetContainerItemInfo(bag, slot) then free[#free + 1] = { bag = bag, slot = slot } end
            end
        end
    end
    return free
end

local SendBatch

-- Splits the partial stacks into free slots, waits until the game shows them, then sends.
local function DoSplits(cur, splits, free)
    if CursorHasItem and CursorHasItem() then ClearCursor() end
    local targets = {}
    for i, sp in ipairs(splits) do
        local to = free[i]
        C_Container.SplitContainerItem(sp.bag, sp.slot, sp.count)
        C_Container.PickupContainerItem(to.bag, to.slot)
        targets[#targets + 1] = { bag = to.bag, slot = to.slot, id = sp.id, count = sp.count }
    end
    RT.Status(Tr("Splitting stacks…"))
    local tries = 0
    local function Check()
        if sending ~= cur then return end
        local ready = true
        for _, t in ipairs(targets) do
            local info = C_Container.GetContainerItemInfo(t.bag, t.slot)
            if not (info and info.itemID == t.id and (info.stackCount or 1) == t.count and not info.isLocked) then ready = false end
        end
        if ready then
            for _, t in ipairs(targets) do cur.stacks[#cur.stacks + 1] = t end
            SendBatch()
        elseif tries < 15 then
            tries = tries + 1
            C_Timer.After(0.2, Check)
        else
            if CursorHasItem and CursorHasItem() then ClearCursor() end
            sending = nil
            RT.Status(Tr("|cffed5c52The game did not split the stack in time: nothing was sent. Try again.|r"))
            RT.Refresh()
        end
    end
    C_Timer.After(0.2, Check)
end

function SendBatch()
    if not sending then return end
    if not mailOpen then RT.Status(Tr("Mailbox closed: sending stopped.")); sending = nil; return end
    if #sending.stacks == 0 and not (sending.money and sending.money > 0) then
        -- Récapitulatif : ce qui est parti, objet par objet.
        local parts = {}
        for _, id in ipairs(sending.order) do
            parts[#parts + 1] = ("%d× %s"):format(sending.sent[id], P.Name(id))
        end
        if sending.moneySent then parts[#parts + 1] = ns.FormatMoney(sending.moneySent, { iconSize = 10 }) end
        local msg = (Tr("Sent to %s (%d mail%s): %s")):format(sending.name, sending.mails, sending.mails == 1 and "" or "s",
            #parts > 0 and table.concat(parts, ", ") or "nothing")
        if ns.Mail and ns.Mail.OnSent then ns.Mail.OnSent(msg, sending.name) end
        if MailFrameTab_OnClick then pcall(MailFrameTab_OnClick, nil, 1) end -- retour à la réception
        ns.Print(msg)
        RT.Status(msg)
        sending = nil
        RT.Refresh()
        return
    end
    if MailFrameTab_OnClick and SendMailFrame and not SendMailFrame:IsShown() then pcall(MailFrameTab_OnClick, nil, 2) end
    if ClearSendMail then ClearSendMail() end
    local max = ATTACHMENTS_MAX_SEND or 12
    local attached = 0
    while attached < max and #sending.stacks > 0 do
        local st = table.remove(sending.stacks, 1)
        local info = C_Container.GetContainerItemInfo(st.bag, st.slot)
        if info and info.itemID == st.id then
            C_Container.PickupContainerItem(st.bag, st.slot)
            attached = attached + 1
            ClickSendMailItemButton(attached)
            if CursorHasItem and CursorHasItem() then ClearCursor(); attached = attached - 1
            else
                local n = info.stackCount or 1
                if not sending.sent[st.id] then sending.sent[st.id] = 0; sending.order[#sending.order + 1] = st.id end
                sending.sent[st.id] = sending.sent[st.id] + n
            end
        end
    end
    local money = sending.money
    if money and money > 0 and SetSendMailMoney then SetSendMailMoney(money); sending.money = nil; sending.moneySent = money end
    if attached == 0 and not money then SendBatch(); return end
    local cur = sending
    cur.waiting = true
    cur.batch = (cur.batch or 0) + 1
    local batch = cur.batch
    RT.Status((Tr("Sending to %s… (%d stack(s) left)")):format(cur.name, #cur.stacks))
    SendMail(cur.name, "ImpotPointGouv", "")
    -- Le jeu n'a ni confirmé ni refusé : on débloque au lieu de rester sur "Sending…".
    C_Timer.After(8, function()
        if sending == cur and cur.waiting and cur.batch == batch then
            sending = nil
            RT.Status((Tr("|cffed5c52No answer from the mailbox for %s: check your sent mail (wrong name?), then try again.|r")):format(cur.name))
            if ClearSendMail then ClearSendMail() end
            RT.Refresh()
        end
    end)
end

-- Envoi générique (aussi utilisé par l'onglet "Send" de la boîte aux lettres) : want = { [id] = quantité }, money en cuivre.
function RT.SendTo(name, want, what, money)
    if sending then RT.Status(Tr("Already sending…")); return false end
    if not mailOpen then RT.Status(Tr("Open a mailbox first.")); return false end
    if not name or name == "" then RT.Status(Tr("|cffed5c52Unknown recipient.|r")); return false end
    local stacks, splits = PlanStacks(want or {})
    if #stacks == 0 and #splits == 0 and not (money and money > 0) then RT.Status(Tr("Nothing to send: ") .. (what or "items") .. Tr(" not found in your bags.")); return false end
    local free = #splits > 0 and FreeBagSlots() or {}
    if #free < #splits then
        RT.Status((Tr("|cffed5c52Free %d bag slot(s) to send part of a stack.|r")):format(#splits))
        return false
    end
    sending = { name = name, stacks = stacks, mails = 0, sent = {}, order = {}, money = money }
    if #splits > 0 then DoSplits(sending, splits, free) else SendBatch() end
    return true
end
function RT.IsSending() return sending ~= nil end
RT.BagStacks = function(want) return BagStacks(want) end
RT.PlanStacks = function(want) return PlanStacks(want) end
RT.CharName = function(key) return CharName(key) end

-- Regroupe des piles par objet pour l'aperçu.
local function RowsFrom(stacks, valueFn)
    local by, rows = {}, {}
    for _, st in ipairs(stacks) do
        local r = by[st.id]
        if not r then r = { id = st.id, qty = 0 }; by[st.id] = r; rows[#rows + 1] = r end
        r.qty = r.qty + st.count
    end
    if valueFn then for _, r in ipairs(rows) do r.value = valueFn(r.id, r.qty) end end
    table.sort(rows, function(a, b) return ns.Prices.Name(a.id) < ns.Prices.Name(b.id) end)
    return rows
end

local function StartSend(targetKey, want, what)
    if targetKey == Me() then RT.Status(Tr("That's this character: nothing to send.")); return end
    local name = CharName(targetKey)
    if not name then RT.Status(Tr("|cffed5c52Unknown recipient: set the character name below.|r")); return end
    local stacks = BagStacks(want)
    if #stacks == 0 then RT.Status(Tr("Nothing to send: ") .. what .. Tr(" not found in your bags.")); return end
    -- Aperçu : vous voyez et cochez ce qui part.
    local rows = RowsFrom(stacks)
    if not ns.Preview or not ns.Preview.Show(rows, { title = Tr("Send to ") .. name, sub = what, confirm = Tr("Send") }, function(chosen)
        local w = {}
        for _, r in ipairs(chosen) do w[r.id] = r.qty end
        RT.SendTo(name, w, what)
    end) then
        RT.SendTo(name, want, what)
    end
end

-- Banque -> crafteur : les compos qui manquent au crafteur pour la file.
local function ReagentsWant(crafter)
    local want = {}
    if not crafter then return want end
    for _, row in ipairs(Q.Plan(crafter).shop) do
        if row.src ~= "craft" then
            want[row.id] = math.max(0, row.need - I.CharCount(crafter, row.id))
        end
    end
    return want
end

function RT.SendReagents(crafter)
    crafter = crafter or Q.Crafter()
    if not crafter then RT.Status(Tr("No crafter: queue recipes on your crafter first.")); return end
    StartSend(crafter, ReagentsWant(crafter), "reagents")
end

-- Ce que CE personnage peut envoyer à la banque : créations de SES métiers,
-- et compos de désenchantement seulement s'il sait désenchanter.
-- Matériau d'artisanat (tissu, rouleaux, cuir traité, barres…) : classe "Trade Goods".
local function IsMaterial(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f then return false end
    local ok, _, _, _, _, _, classID = pcall(f, id)
    return ok and classID == 7
end
RT.IsMaterial = IsMaterial

local function MySendables()
    local me, want = Me(), {}
    for prof, recipes in pairs(ns.db.recipes) do
        local mine = ns.db.profChars and ns.db.profChars[prof] and ns.db.profChars[prof][me]
        if mine then
            -- Seulement les objets finis : les matériaux fabriqués (rouleaux…) restent pour vos prochains crafts.
            for _, r in pairs(recipes) do if r.p and not IsMaterial(r.p) then want[r.p] = math.huge end end
        end
    end
    -- Produits intermédiaires (rouleaux de tissu, cuir traité…) : ils servent à vos propres recettes, on les garde.
    for prof, recipes in pairs(ns.db.recipes) do
        local mine = ns.db.profChars and ns.db.profChars[prof] and ns.db.profChars[prof][me]
        if mine then
            for _, r in pairs(recipes) do
                for _, rg in ipairs(r.r or {}) do if rg[1] then want[rg[1]] = nil end end
            end
        end
    end
    local knowsDE = (IsPlayerSpell and IsPlayerSpell(13262)) or false
    if knowsDE then
        for _, id in ipairs(P.DE_MATS) do want[id] = math.huge end
    end
    return want
end
RT.MySendables = MySendables

-- Crafteur -> banque : tout ce qui se vend (créations de recettes + compos de désenchantement),
-- sauf ce qui sert encore à la file.
-- Meilleur débouché d'une création : "ah" | "vendor" | "de" (nil si ce n'est pas une création connue).
local function ChannelOf(id)
    local saved, prof, name = ns.Craft.ProducerOf(id)
    if not saved then return nil end
    local rec = Q.FindRecipe and Q.FindRecipe(prof, name)
    return rec and ns.Craft.GetEval(rec).channel or nil
end
RT.ChannelOf = ChannelOf

local function CraftsWant()
    local keep = {}
    for _, row in ipairs(Q.Plan().shop) do keep[row.id] = row.need end
    local want = MySendables()
    -- Garde ce que la file demande encore + votre réserve "keep" ; envoie le reste.
    for id in pairs(want) do
        local hold = (keep[id] or 0) + (ns.Keep and ns.Keep.Get(id) or 0)
        if hold > 0 then want[id] = math.max(0, ns.GetItemCount(id) - hold) end
    end
    -- Ce qui rapporte plus au marchand ou désenchanté reste ici : seule la vente HV passe par la banque.
    for id in pairs(want) do
        local ch = ChannelOf(id)
        if ch == "vendor" or ch == "de" then want[id] = nil end
    end
    return want
end

-- ------------------------------------------------------------ vente au marchand
-- Créations dont le meilleur débouché est le marchand (moins la réserve "keep").
-- Composants de vos recettes (tous métiers connus) : jamais vendus au marchand par l'addon.
local function ReagentSet()
    local set = {}
    for _, recipes in pairs(ns.db.recipes or {}) do
        for _, r in pairs(recipes) do
            for _, rg in ipairs(r.r or {}) do if rg[1] then set[rg[1]] = true end end
        end
    end
    return set
end

local function VendorWant()
    local want = {}
    local reagents = ReagentSet()
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + 1)
    for bag = 0, last do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and want[info.itemID] == nil then
                want[info.itemID] = (ChannelOf(info.itemID) == "vendor" and not reagents[info.itemID] and not IsMaterial(info.itemID))
                    and math.max(0, ns.GetItemCount(info.itemID) - (ns.Keep and ns.Keep.Get(info.itemID) or 0)) or 0
                -- Achetés à l'HV pour revendre au marchand (vendor flip).
                local fb = ns.db.flipBought and ns.db.flipBought[info.itemID]
                if fb and fb > 0 then want[info.itemID] = math.max(want[info.itemID], fb) end
                -- Expiré 3 fois de suite à l'HV (ou dépôts perdus > gain) : mieux vaut le marchand.
                if not info.isBound and not reagents[info.itemID] and ns.Track then
                    local adv = ns.Track.PostAdvice((info.hyperlink and info.hyperlink:match("%[(.-)%]")) or ns.GetItemInfo(info.itemID), info.itemID)
                    if adv and adv.vendor then
                        want[info.itemID] = math.max(want[info.itemID], ns.GetItemCount(info.itemID) - (ns.Keep and ns.Keep.Get(info.itemID) or 0))
                    end
                end
            end
        end
    end
    return want
end

local selling
function RT.SellToVendor(only)
    if selling or not merchantOpen then return end
    local stacks = BagStacks(VendorWant())
    if #stacks == 0 then RT.Status(Tr("Nothing to sell to the vendor.")); return end
    if not only and ns.Preview then
        local rows = RowsFrom(stacks, function(id, q) return (P.VendorSell(id) or 0) * q end)
        ns.Preview.Show(rows, { title = Tr("Sell to this vendor"), sub = Tr("Worth more here than at the AH. Uncheck what you keep."), confirm = Tr("Sell") },
            function(chosen)
                local set = {}
                for _, r in ipairs(chosen) do set[r.id] = true end
                RT.SellToVendor(set)
            end)
        return
    end
    if only then
        local f = {}
        for _, st in ipairs(stacks) do if only[st.id] then f[#f + 1] = st end end
        stacks = f
    end
    selling = { stacks = stacks, sold = {}, order = {} }
    local function Step()
        if not selling then return end
        if not merchantOpen then RT.Status(Tr("Vendor closed: selling stopped.")); selling = nil; return end
        local st = table.remove(selling.stacks, 1)
        if not st then
            local parts = {}
            for _, id in ipairs(selling.order) do parts[#parts + 1] = ("%d× %s"):format(selling.sold[id], P.Name(id)) end
            local msg = "Sold to vendor: " .. table.concat(parts, ", ")
            ns.Print(msg); RT.Status(msg)
            selling = nil
            RT.UpdateMerchantBar()
            RT.Refresh()
            return
        end
        local info = C_Container.GetContainerItemInfo(st.bag, st.slot)
        if info and info.itemID == st.id then
            C_Container.UseContainerItem(st.bag, st.slot)
            if not selling.sold[st.id] then selling.sold[st.id] = 0; selling.order[#selling.order + 1] = st.id end
            selling.sold[st.id] = selling.sold[st.id] + (info.stackCount or 1)
            local fb = ns.db.flipBought and ns.db.flipBought[st.id]
            if fb then
                fb = fb - (info.stackCount or 1)
                ns.db.flipBought[st.id] = fb > 0 and fb or nil
            end
        end
        C_Timer.After(0.2, Step)
    end
    Step()
end

RT.CraftsWant = function() return CraftsWant() end
RT.ReagentsWant = function(c) return ReagentsWant(c) end

function RT.SendCrafts()
    local bank = RT.Bank()
    if not bank then RT.Status(Tr("Set your bank character first (Characters page: click \"Bank\").")); return end
    StartSend(bank, CraftsWant(), "crafted items / enchanting mats")
end

-- Nombre d'objets que chaque bouton d'envoi enverrait maintenant.
local function Pending(want)
    local n = 0
    for _, st in ipairs(BagStacks(want)) do n = n + st.count end
    return n
end

-- ------------------------------------------------------------ interface
function RT.Status(text)
    if frame then frame.status:SetText(text or "") end
    if ns.Mail and ns.Mail.SendStatus then ns.Mail.SendStatus(text) end
end

local function Build()
    frame = CreateFrame("Frame", "ImpotPointGouvRoutine", UIParent)
    frame:SetSize(W, H)
    frame:SetPoint("CENTER", 250, 0)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    T.Surface(frame, C.window, 14, { 1, 1, 1, 0.09 })
    tinsert(UISpecialFrames, "ImpotPointGouvRoutine")
    frame:SetToplevel(true)
    if ns.Setup then ns.Setup.AttachBanner(frame) end

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ns.MEDIA .. Tr("icon.tga")); icon:SetSize(26, 26); icon:SetPoint("TOPLEFT", 14, -12)
    local title = T.Text(frame, 15, { bold = true, text = Tr("Routine") }); title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, 1)
    frame.roles = T.Text(frame, 12, { bold = true, color = C.muted }); frame.roles:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 8, -2)
    local close = T.CloseButton(frame, function() frame:Hide() end); close:SetPoint("TOPRIGHT", -8, -10)

    frame.queueAll = T.Button(frame, Tr("Auto-fill all professions"), 180, 26, function()
        Q.AutoQueue(true); RT.Refresh()
    end)
    frame.queueAll:SetPoint("TOPLEFT", 12, -50)
    frame.queueAll.tooltip = Tr("Queues the profitable recipes of every profession of this character (open each profession once so the addon knows its recipes).")
    frame.setBank = T.Button(frame, Tr("This is my bank"), 130, 26, function()
        ns.db.settings.bankChar = Me(); RT.Refresh()
    end)
    frame.setBank:SetPoint("LEFT", frame.queueAll, "RIGHT", 6, 0)
    frame.clear = T.Button(frame, Tr("Clear queue"), 100, 26, function() Q.Clear(); RT.Refresh() end)
    frame.clear:SetPoint("LEFT", frame.setBank, "RIGHT", 6, 0)

    -- À crafter
    local qc = CreateFrame("Frame", nil, frame)
    T.Surface(qc, C.surface, 10)
    qc:SetPoint("TOPLEFT", 12, -86); qc:SetPoint("TOPRIGHT", -12, -86)
    qc:SetHeight(36 + QROWS * 22)
    local qt = T.Text(qc, 12, { bold = true, text = Tr("To craft") }); qt:SetPoint("TOPLEFT", 14, -10)
    frame.qsum = T.Text(qc, 11, { color = C.muted, justify = "RIGHT" }); frame.qsum:SetPoint("TOPRIGHT", -12, -11)
    frame.qrows = {}
    for i = 1, QROWS do
        local r = CreateFrame("Frame", nil, qc)
        r:SetHeight(22)
        r:SetPoint("TOPLEFT", 8, -30 - (i - 1) * 22); r:SetPoint("TOPRIGHT", -8, -30 - (i - 1) * 22)
        r:EnableMouse(true)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(18, 18); r.icon:SetPoint("LEFT", 22, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.name = T.Text(r, 12); r.name:SetPoint("LEFT", 46, 0); r.name:SetWidth(178)
        r.keep = ns.Keep.Button(r); r.keep:SetPoint("LEFT", 226, 0)
        r.count = T.Text(r, 12, { bold = true, justify = "RIGHT" }); r.count:SetPoint("RIGHT", r, "LEFT", 302, 0); r.count:SetWidth(30)
        r.profit = T.Text(r, 11, { justify = "RIGHT" }); r.profit:SetPoint("RIGHT", -4, 0)
        r.chan = T.Text(r, 10, { bold = true, justify = "LEFT" }); r.chan:SetPoint("LEFT", r, "LEFT", 308, 0)
        r:SetScript("OnEnter", function(self)
            local c = self.craft
            if not c or not c.rec.pid then return end
            T.ItemTooltip(self, c.rec.pid)
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine(Tr("Profession"), c.prof, 0.7, 0.7, 0.7, 1, 1, 1)
            if c.ev and c.ev.profit then
                GameTooltip:AddDoubleLine(Tr("Profit per craft"), ns.FormatMoney(c.ev.profit, { sign = true, color = true, iconSize = 11 }), 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        frame.qrows[i] = r
    end
    frame.qempty = T.Text(qc, 12, { color = C.faint, justify = "CENTER", text = Tr("Nothing queued.") })
    frame.qempty:SetPoint("CENTER", 0, -10)
    frame.qoff = 0
    qc:EnableMouseWheel(true)
    qc:SetScript("OnMouseWheel", function(_, d)
        frame.qoff = math.max(0, math.min(math.max(0, (frame.nq or 0) - QROWS), frame.qoff - d)); RT.Refresh()
    end)

    -- Liste de courses
    local list = CreateFrame("Frame", nil, frame)
    T.Surface(list, C.surface, 10)
    list:SetPoint("TOPLEFT", qc, "BOTTOMLEFT", 0, -10); list:SetPoint("TOPRIGHT", qc, "BOTTOMRIGHT", 0, -10)
    list:SetHeight(46 + ROWS * 24)
    local lt = T.Text(list, 12, { bold = true, text = Tr("Shopping list") }); lt:SetPoint("TOPLEFT", 14, -10)
    frame.sum = T.Text(list, 11, { color = C.muted, justify = "RIGHT" }); frame.sum:SetPoint("TOPRIGHT", -12, -11)
    local cols = { { "Need", 230 }, { "Here", 275 }, { "Others", 325 }, { "Buy", 370 } }
    for _, c in ipairs(cols) do
        local h = T.Text(list, 10, { bold = true, color = C.faint, justify = "RIGHT", text = c[1] })
        h:SetPoint("TOPRIGHT", list, "TOPLEFT", c[2], -30); h:SetWidth(50)
    end
    frame.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Frame", nil, list)
        r:SetHeight(24)
        r:SetPoint("TOPLEFT", 8, -44 - (i - 1) * 24); r:SetPoint("TOPRIGHT", -8, -44 - (i - 1) * 24)
        r:EnableMouse(true)
        r.check = r:CreateTexture(nil, "ARTWORK"); r.check:SetSize(16, 16); r.check:SetPoint("LEFT", 2, 0)
        r.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(18, 18); r.icon:SetPoint("LEFT", 22, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.name = T.Text(r, 12); r.name:SetPoint("LEFT", 46, 0); r.name:SetWidth(160)
        local function Col(x) local t = T.Text(r, 12, { justify = "RIGHT" }); t:SetPoint("RIGHT", r, "LEFT", x - 8, 0); t:SetWidth(46); return t end
        r.need, r.here, r.others, r.buy = Col(230), Col(275), Col(325), Col(370)
        r.src = T.Text(r, 10, { bold = true }); r.src:SetPoint("LEFT", 372, 0)
        r:SetScript("OnEnter", function(self)
            if not self.row then return end
            T.ItemTooltip(self, self.row.id)
            GameTooltip:AddLine(" ")
            for _, d in ipairs(self.row.detail or {}) do GameTooltip:AddDoubleLine(d[1], d[2], 0.7, 0.7, 0.7, 1, 1, 1) end
            local mx = self.row.src == "ah" and Q.MaxPrice(self.row.id)
            if mx then GameTooltip:AddDoubleLine(Tr("Buy at most at"), ns.FormatMoney(mx, { iconSize = 11 }) .. Tr(" each"), 0.88, 0.66, 0.24, 1, 1, 1) end
            local ev = self.row.src == "ah" and Q.BreakEven(self.row.id)
            if ev then GameTooltip:AddDoubleLine(Tr("You lose money above"), ns.FormatMoney(ev, { iconSize = 11 }) .. Tr(" each"), 0.93, 0.36, 0.32, 1, 1, 1) end
            local vb = P.VendorBuy(self.row.id)
            if vb and P.IsVendorItem(self.row.id) then
                GameTooltip:AddDoubleLine(Tr("Vendor price"), ns.FormatMoney(vb, { iconSize = 11 }), 0.7, 0.7, 0.7, 1, 1, 1)
                if self.row.cheaper then GameTooltip:AddLine(Tr("Cheaper at the AH right now: never bought above the vendor price."), 0.36, 0.82, 0.45, true) end
            end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        frame.rows[i] = r
    end
    frame.empty = T.Text(list, 12, { color = C.faint, justify = "CENTER", wrap = true,
        text = Tr("Nothing to buy.") })
    frame.empty:SetPoint("CENTER", 0, -10); frame.empty:SetWidth(360)
    frame.off = 0
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, d)
        frame.off = math.max(0, math.min(math.max(0, (frame.n or 0) - ROWS), frame.off - d)); RT.Refresh()
    end)

    -- Destinataire (nom modifiable si le nom court ne suffit pas pour le courrier)
    local nameLbl = T.Text(frame, 11, { color = C.muted, text = Tr("Send to:") })
    frame.nameLbl = nameLbl
    nameLbl:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 4, -12)
    local eb = CreateFrame("EditBox", nil, frame)
    eb:SetSize(150, 22); eb:SetPoint("LEFT", nameLbl, "RIGHT", 8, 0)
    eb:SetAutoFocus(false); eb:SetFontObject(ChatFontNormal)
    T.Surface(eb, C.surface2, 6)
    eb:SetTextInsets(6, 6, 0, 0)
    eb:SetScript("OnEnterPressed", function(self)
        local text = (self:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local key = frame.targetKey
        local me = Me()
        -- Banque pas encore définie (sur le crafteur) : le nom tapé désigne un de vos personnages.
        if not key and Q.IsCrafter(me) and text ~= "" then
            local low = text:lower()
            for k, c in pairs(ns.db.chars) do
                local n = (c.name or ""):lower()
                if k ~= me and n ~= "" and (n == low or n:find(low, 1, true) == 1 or low:find(n, 1, true) == 1) then
                    ns.db.settings.bankChar = k
                    key = k
                    break
                end
            end
        end
        if key and text ~= "" then
            ns.db.settings.mailNames = ns.db.settings.mailNames or {}
            -- Garde le nom complet s'il est plus long que le prénom connu (ex. "Raptout Dupont").
            local ch = ns.db.chars[key]
            local known = ch and (ch.full or ch.name) or ""
            -- Garde ce qui est le plus complet : le texte tapé s'il contient un nom de famille.
            ns.db.settings.mailNames[key] = (text:find(" ") or #text >= #known) and text or known
        end
        self:ClearFocus(); RT.Refresh()
    end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame.nameBox = eb

    -- Suggestions : vos personnages (filtrés par ce qui est tapé).
    local sug = CreateFrame("Frame", nil, frame)
    sug:SetPoint("TOPLEFT", eb, "BOTTOMLEFT", 0, -2)
    sug:SetWidth(220)
    sug:SetFrameLevel((eb:GetFrameLevel() or 1) + 20)
    T.Surface(sug, C.surface2, 6, { 1, 1, 1, 0.12 })
    sug.buttons = {}
    sug:Hide()
    local function Pick(key)
        local me = Me()
        local isCrafter = Q.IsCrafter(me)
        -- Sur le crafteur sans banque définie : choisir un personnage le désigne comme banque.
        if isCrafter and not RT.Bank() and key ~= me then ns.db.settings.bankChar = key end
        frame.targetKey = isCrafter and RT.Bank() or Q.Crafter()
        eb:SetText(CharName(key) or "")
        if frame.targetKey == key then
            ns.db.settings.mailNames = ns.db.settings.mailNames or {}
            ns.db.settings.mailNames[key] = CharName(key)
        end
        sug:Hide(); eb:ClearFocus(); RT.Refresh()
    end
    local function UpdateSuggestions()
        local typed = (eb:GetText() or ""):lower()
        local list = {}
        for key, c in pairs(ns.db.chars) do
            local name = CharName(key) or c.name or "?"
            if key ~= Me() and (typed == "" or name:lower():find(typed, 1, true)) then
                list[#list + 1] = { key = key, name = name, class = c.class, realm = c.realm }
            end
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        for i = 1, math.max(#list, #sug.buttons) do
            local b = sug.buttons[i]
            if not b and list[i] then
                b = CreateFrame("Button", nil, sug)
                b:SetHeight(22)
                b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 22); b:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * 22)
                b.hl = T.Rounded(b, { 1, 1, 1, 0 }, 5, "BACKGROUND", 2)
                b.text = T.Text(b, 12); b.text:SetPoint("LEFT", 8, 0)
                b:SetScript("OnEnter", function(self) self.hl:SetColor({ C.gold[1], C.gold[2], C.gold[3], 0.18 }) end)
                b:SetScript("OnLeave", function(self) self.hl:SetColor({ 1, 1, 1, 0 }) end)
                b:SetScript("OnClick", function(self) Pick(self.key) end)
                sug.buttons[i] = b
            end
            if b then
                local e = list[i]
                if e then
                    b.key = e.key
                    b.text:SetText(e.name)
                    b.text:SetTextColor(ns.ClassColor(e.class))
                    b:Show()
                else
                    b:Hide()
                end
            end
        end
        sug:SetHeight(8 + #list * 22)
        sug:SetShown(#list > 0 and eb:HasFocus())
    end
    eb:SetScript("OnEditFocusGained", UpdateSuggestions)
    eb:SetScript("OnTextChanged", function(_, user) if user then UpdateSuggestions() end end)
    eb:SetScript("OnEditFocusLost", function() C_Timer.After(0.2, function() sug:Hide() end) end)
    eb:SetScript("OnTabPressed", function()
        local first = sug.buttons[1]
        if sug:IsShown() and first and first:IsShown() then Pick(first.key) end
    end)

    frame.status = T.Text(frame, 11, { color = C.muted, wrap = true })
    frame.status:SetPoint("TOPLEFT", nameLbl, "BOTTOMLEFT", 0, -12)
    frame.status:SetPoint("RIGHT", frame, "RIGHT", -16, 0)

    frame.a1 = T.Button(frame, "", 10, 34, nil)
    frame.a1:SetPoint("BOTTOMLEFT", 12, 12); frame.a1:SetPoint("BOTTOMRIGHT", frame, "BOTTOM", -4, 12)
    frame.a2 = T.Button(frame, "", 10, 34, nil)
    frame.a2:SetPoint("BOTTOMLEFT", frame, "BOTTOM", 4, 12); frame.a2:SetPoint("BOTTOMRIGHT", -12, 12)
    frame:SetScript("OnShow", function() RT.Refresh() end)
    frame:Hide()
end

local function SetAction(btn, label, fn, tip)
    if not label then btn:Hide(); return end
    btn.text:SetText(label)
    btn:SetScript("OnClick", function(self) if fn and not self.disabled then fn() end end)
    btn.tooltip = tip
    btn:SetDisabled(false)
    btn:Show()
end

function RT.Refresh()
    if not frame or not frame:IsShown() then return end
    local me, bank, crafter = Me(), RT.Bank(), Q.Crafter()
    local isBank, isCrafter = bank == me, Q.IsCrafter(me)
    local function Colored(key, fallback)
        local name = CharName(key)
        if not name then return "|cffed5c52" .. fallback .. "|r" end
        local c = ns.db.chars[key]
        local r, g, b = ns.ClassColor(c and c.class)
        return (Tr("|cff%02x%02x%02x%s|r")):format(math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), name)
    end
    local names = {}
    for _, k in ipairs(Q.Crafters()) do names[#names + 1] = Colored(k, "?") end
    frame.roles:SetText((Tr("|cffe0a83d%s|r  %s     |cffe0a83dBank|r  %s")):format(#names > 1 and "Crafters" or "Crafter",
        #names > 0 and table.concat(names, ", ") or "|cffed5c52none|r", Colored(bank, "not set")))
    frame.queueAll:SetShown(#Q.MyProfessions() > 0)
    frame.setBank:SetShown(not isBank)

    local plan = Q.Plan()
    -- À crafter (vos recettes ; les intermédiaires sont dans les courses, colonne "Craft")
    local list = plan.visible or plan.crafts
    frame.nq = #list
    frame.qoff = math.min(frame.qoff, math.max(0, #list - QROWS))
    for i, r in ipairs(frame.qrows) do
        local c = list[frame.qoff + i]
        r.craft = c
        if c then
            r.icon:SetTexture(c.rec.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.name:SetText(c.inter and ("|cff9ad98c" .. c.name .. Tr("|r  |cff615f5c· reagent|r")) or c.name)
            r.name:SetWidth(c.inter and 220 or 178)
            r.keep:SetItem(not c.inter and c.rec.pid or nil)
            r.count:SetText("×" .. c.n)
            r.chan:SetText(c.inter and "" or ns.ChannelLabel(c.ev.channel))
            r.profit:SetText((c.ev.profit and not c.inter) and
                ns.FormatMoney(c.ev.profit * c.n, { sign = true, color = true, short = true, iconSize = 10 }) or "")
            r:Show()
        else
            r:Hide()
        end
    end
    frame.qempty:SetShown(#plan.crafts == 0)
    frame.qsum:SetText(#plan.crafts > 0 and (Tr("profit %s")):format(
        ns.FormatMoney(plan.profit, { sign = true, color = true, short = true, iconSize = 10 })) or "")

    frame.n = #plan.shop
    frame.off = math.min(frame.off, math.max(0, #plan.shop - ROWS))
    local cost, missing = 0, 0
    for _, row in ipairs(plan.shop) do
        if row.buy > 0 then
            missing = missing + 1
            cost = cost + ((row.src == "vendor" and P.VendorBuy(row.id) or P.AHValue(row.id)) or 0) * row.buy
        end
    end
    for i, r in ipairs(frame.rows) do
        local row = plan.shop[frame.off + i]
        r.row = row
        if row then
            local done = row.buy == 0
            r.check:SetShown(done)
            r.icon:SetTexture(row.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.name:SetText(done and ("|cff8a877f" .. row.name .. "|r") or row.name)
            r.need:SetText(row.need)
            r.here:SetText(row.mine)
            r.others:SetText(row.alts > 0 and ("|cffe0a83d" .. row.alts .. "|r") or "|cff615f5c0|r")
            if row.src == "craft" then
                r.buy:SetText((row.toCraft or 0) > 0 and ("|cff9ad98c" .. row.toCraft .. "|r") or "|cff5cd173✓|r")
                r.check:SetShown((row.toCraft or 0) == 0)
            else
                r.buy:SetText(done and "|cff5cd173✓|r" or ("|cffed5c52" .. row.buy .. "|r"))
            end
            local mx = row.src == "ah" and Q.MaxPrice(row.id)
            local src = row.src == "vendor" and "|cffe0a83dVendor|r" or row.src == "craft" and "|cff9ad98cCraft|r"
                or (mx and ("|cff8cbff2≤" .. ns.FormatMoney(mx, { short = true, iconSize = 9 }) .. "|r") or "|cff8cbff2AH|r")
            r.src:SetText(src)
            r:Show()
        else
            r:Hide()
        end
    end
    frame.empty:SetShown(#plan.shop == 0)
    frame.sum:SetText(#plan.shop > 0 and (missing == 0 and "|cff5cd173all bought|r" or
        (Tr("%d to buy  ·  ≈ %s")):format(missing, ns.FormatMoney(cost, { short = true, iconSize = 10 }))) or "")

    -- Destinataire selon le contexte
    frame.targetKey = isCrafter and bank or crafter
    frame.nameLbl:SetText(isCrafter and "Send to (your bank):" or "Send to (your crafter):")
    if not frame.nameBox:HasFocus() then frame.nameBox:SetText(CharName(frame.targetKey) or "") end

    if merchantOpen then
        local n = Q.VendorNeedCount()
        SetAction(frame.a1, n > 0 and (Tr("Buy vendor reagents (%d)")):format(n) or "No vendor reagents needed here",
            function() Q.BuyVendorNeeds(false); C_Timer.After(0.6, RT.Refresh) end,
            "Buys from this vendor the reagents your craft queue still needs.")
        frame.a1:SetDisabled(n == 0)
        -- Créations qui valent plus chez le marchand qu'à l'HV.
        local sellN = 0
        for _, st in ipairs(BagStacks(VendorWant())) do sellN = sellN + st.count end
        if sellN > 0 and not selling then
            SetAction(frame.a2, (Tr("Sell to vendor (%d)")):format(sellN), RT.SellToVendor,
                "Sells the crafts worth more at the vendor than at the AH, and what you bought as vendor flips. Your keep amounts stay in your bags.")
        else
            SetAction(frame.a2, nil)
        end
    elseif ahOpen then
        frame.a1:SetDisabled(false)
        SetAction(frame.a1, "Send list to Auctionator", RT.ExportAuctionator,
            "Creates an Auctionator shopping list with the exact quantities. Then: Auctionator > Shopping > search it.")
        SetAction(frame.a2, nil) -- l'achat se fait avec "Buy …" dans la barre de l'HV
    elseif mailOpen then
        -- Bouton grisé quand il n'y a rien à envoyer ; sinon le nombre d'objets est affiché.
        local function SendBtn(btn, label, who, fn, tip, want)
            local n = (not sending and who and who ~= Me()) and Pending(want) or 0
            SetAction(btn, n > 0 and ("%s (%d)"):format(label, n) or (sending and "Sending…" or ("Nothing to send to " .. (CharName(who) or "?"))), fn, tip)
            btn:SetDisabled(n == 0)
        end
        if isCrafter then
            SendBtn(frame.a1, (Tr("Send crafts to %s")):format(CharName(bank) or "bank"), bank, RT.SendCrafts,
                "Mails everything you crafted and your enchanting mats to your bank (keeps what the queue still needs and your keep amounts).",
                CraftsWant())
            SetAction(frame.a2, nil)
        else
            -- Banque : un bouton par crafteur qui attend des composants (les 2 premiers ; les autres via l'onglet Send).
            local targets = {}
            for _, k in ipairs(Q.Crafters()) do
                if k ~= me and Pending(ReagentsWant(k)) > 0 then targets[#targets + 1] = k end
            end
            local first = targets[1] or crafter
            SendBtn(frame.a1, (Tr("Send reagents to %s")):format(CharName(first) or "crafter"), first,
                function() RT.SendReagents(first) end, "Mails the reagents this crafter is missing for its queue.",
                ReagentsWant(first))
            if targets[2] then
                local second = targets[2]
                SendBtn(frame.a2, (Tr("Send reagents to %s")):format(CharName(second) or "crafter"), second,
                    function() RT.SendReagents(second) end, "Mails the reagents this crafter is missing for its queue.",
                    ReagentsWant(second))
            elseif isBank or not next(MySendables()) then SetAction(frame.a2, nil)
            else
                SendBtn(frame.a2, (Tr("Send crafts to %s")):format(CharName(bank) or "bank"), bank, RT.SendCrafts,
                    "Mails what this character crafted (and enchanting mats if it can disenchant) to your bank.", CraftsWant())
            end
        end
    else
        SetAction(frame.a1, nil); SetAction(frame.a2, nil)
        if (frame.status:GetText() or "") == "" then
            RT.Status(Tr("Open the AH, a mailbox or a vendor: the matching buttons appear here."))
        end
    end
end

function RT.Toggle()
    if not frame then Build() end
    frame:SetShown(not frame:IsShown())
    if frame:IsShown() then frame:Raise() end
end

-- ------------------------------------------------------------ barre du marchand
-- Collée au marchand : acheter les compos de la file, vendre ce qui vaut plus ici. Chaque bouton ouvre l'aperçu.
local mbar
function RT.UpdateMerchantBar()
    if not MerchantFrame or not MerchantFrame:IsShown() or not ns.db then if mbar then mbar:Hide() end; return end
    if not mbar then
        mbar = CreateFrame("Frame", nil, MerchantFrame)
        mbar:SetSize(10, 36)
        mbar:SetPoint("BOTTOMLEFT", MerchantFrame, "TOPLEFT", 60, 4)
        mbar:SetFrameLevel((MerchantFrame:GetFrameLevel() or 1) + 10)
        T.Surface(mbar, C.window, 10, { 1, 1, 1, 0.09 })
        local icon = mbar:CreateTexture(nil, "ARTWORK"); icon:SetTexture(ns.MEDIA .. Tr("icon.tga"))
        icon:SetSize(20, 20); icon:SetPoint("LEFT", 8, 0)
        mbar.buy = T.Button(mbar, "", 200, 26, function() Q.BuyVendorNeeds(false) end)
        mbar.buy:SetPoint("LEFT", icon, "RIGHT", 8, 0)
        mbar.buy.tooltip = Tr("Reagents your craft queue still needs, at this vendor's price. You confirm the list first.")
        mbar.sell = T.Button(mbar, "", 200, 26, function() RT.SellToVendor() end)
        mbar.sell.tooltip = Tr("Crafts worth more at the vendor than at the AH, your vendor flips, and items that keep expiring at the AH. You confirm the list first.")
    end
    local nb = Q.VendorNeedCount()
    local ns2 = 0
    for _, st in ipairs(BagStacks(VendorWant())) do ns2 = ns2 + st.count end
    mbar.buy:SetShown(nb > 0); mbar.sell:SetShown(ns2 > 0 and not selling)
    mbar.buy.text:SetText((Tr("Buy queue reagents (%d)")):format(nb))
    mbar.sell.text:SetText((Tr("Sell to vendor (%d)")):format(ns2))
    mbar.sell:ClearAllPoints()
    if nb > 0 then mbar.sell:SetPoint("LEFT", mbar.buy, "RIGHT", 6, 0) else mbar.sell:SetPoint("LEFT", mbar, "LEFT", 36, 0) end
    local w = 36 + (nb > 0 and 206 or 0) + (ns2 > 0 and 206 or 0) + 4
    mbar:SetWidth(w)
    mbar:SetShown(nb > 0 or ns2 > 0)
end

-- Y a-t-il quelque chose à envoyer depuis ce personnage ?
function RT.HasSomethingToSend()
    local me, bank, crafter = Me(), RT.Bank(), Q.Crafter()
    if bank and me ~= bank then
        if #BagStacks(CraftsWant()) > 0 then return true end
    end
    if crafter and me ~= crafter and next(ns.db.queue or {}) then return true end
    return false
end

local function AutoShow(anchor, forMail, force)
    if ns.db.settings.routineAuto == false then return end
    -- Seulement sur le crafteur et la banque : jamais en montant de niveau sur un autre perso.
    local me = Me()
    local hasFlips = ns.db.flipBought and next(ns.db.flipBought) ~= nil
    -- Crafteur : seulement s'il a une file en cours (pas en simple leveling).
    local crafting = Q.IsCrafter(me) and #Q.Plan(me).crafts > 0
    if me ~= RT.Bank() and not crafting and not (force and hasFlips) then return end
    -- La boîte aux lettres a ses propres boutons d'envoi (onglet Send) : pas d'ouverture automatique.
    if forMail then return end
    local hasQueue = next(ns.db.queue or {}) ~= nil
    if not force and not hasQueue and not (forMail and RT.HasSomethingToSend()) then return end
    if not frame then Build() end
    if anchor and anchor:IsShown() then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 10, 0)
    end
    frame:Show()
    RT.Refresh()
end

-- ------------------------------------------------------------ événements
local ev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(ev, "Routine") end
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SEND_SUCCESS",
    "MAIL_FAILED", "BAG_UPDATE_DELAYED", "MERCHANT_SHOW", "MERCHANT_CLOSED", "UI_ERROR_MESSAGE" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, ...)
    if not ns.db then return end
    if event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
        C_Timer.After(0.3, function() AutoShow(AuctionHouseFrame or AuctionFrame) end)
    elseif event == "MERCHANT_SHOW" then
        merchantOpen = true
        C_Timer.After(0.3, RT.UpdateMerchantBar)
        C_Timer.After(0.3, function()
            if Q.VendorNeedCount() > 0 then AutoShow(MerchantFrame)
            elseif #BagStacks(VendorWant()) > 0 then AutoShow(MerchantFrame, false, true)
            else RT.Refresh() end
        end)
    elseif event == "MERCHANT_CLOSED" then
        merchantOpen = false; RT.Refresh()
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ahOpen = false; RT.Refresh()
    elseif event == "MAIL_SHOW" then
        mailOpen = true
        local c = ns.db.chars[Me()]
        if c then c.lastMail = time() end
        C_Timer.After(0.3, function() AutoShow(_G.ImpotPointGouvMailFrame or MailFrame, true) end)
    elseif event == "MAIL_CLOSED" then
        mailOpen = false
        if sending then sending = nil; RT.Status(Tr("Mailbox closed: sending stopped.")) end
        RT.Refresh()
    elseif event == "MAIL_SEND_SUCCESS" then
        if sending and sending.waiting then
            sending.waiting = false
            sending.mails = sending.mails + 1
            C_Timer.After(0.6, SendBatch)
        end
    elseif event == "UI_ERROR_MESSAGE" then
        -- Le jeu refuse l'envoi (destinataire inconnu, etc.) : on l'affiche tout de suite au lieu d'attendre.
        local a, b = ...
        local text = type(b) == "string" and b or (type(a) == "string" and a) or nil
        if sending and sending.waiting and text then
            RT.Status((Tr("|cffed5c52%s (%s)|r")):format(text, sending.name))
            sending = nil
            if ClearSendMail then ClearSendMail() end
            RT.Refresh()
        end
    elseif event == "MAIL_FAILED" then
        if sending then
            RT.Status((Tr("|cffed5c52Mail to %s failed (wrong name? not enough gold for postage?).|r")):format(sending.name))
            sending = nil
            if ClearSendMail then ClearSendMail() end
            RT.Refresh()
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        if frame and frame:IsShown() then C_Timer.After(0.3, RT.Refresh) end
        if merchantOpen then C_Timer.After(0.3, RT.UpdateMerchantBar) end
    end
end)
ns.On("INVENTORY_CHANGED", function() RT.Refresh() end)
