-- ImpotPointGouv : vendre à l'HV sans autre addon.
-- Bouton "Post" : chaque clic poste l'objet suivant au bon prix (juste sous la concurrence, jamais sous
-- votre coût ni sous le prix marchand). Bouton "Cancel" : annule une de vos annonces coupées.
-- Le jeu exige un clic par mise en vente / annulation : l'addon prépare tout, vous cliquez.
local _, ns = ...
local Tr = ns.L
local T, P, CR = ns.Theme, ns.Prices, ns.Craft
local C = T.C
local S = {}
ns.Sell = S

local AH -- C_AuctionHouse
local prices = {}   -- [id] = { low = autre vendeur le moins cher, own = votre annonce la moins chère, t = time() }
local lookup        -- file de recherches en cours
local posted = {}   -- objets postés pendant cette visite à l'HV
local owned = {}    -- vos annonces actives
local cancelled = {}
local bar, postBtn, cancelBtn

local function Rules()
    local q = CR.Rules()
    if q.postDuration == nil then q.postDuration = 3 end -- 1 court, 2 moyen, 3 long
    if q.postCap == nil then q.postCap = 10 end          -- objets non empilables postés d'un coup
    return q
end
S.Rules = Rules

local function Status(text) if P.Status then P.Status(text) end end
local function Money(v) return ns.FormatMoney(v or 0, { iconSize = 10 }) end

-- ------------------------------------------------------------ que poster ?
local function IsDEMat(id)
    for _, m in ipairs(P.DE_MATS or {}) do if m == id then return true end end
    return false
end

local function Reagents()
    local set = {}
    for _, list in pairs(ns.db.recipes or {}) do
        for _, r in pairs(list) do
            for _, rg in ipairs(r.r or {}) do if rg[1] then set[rg[1]] = true end end
        end
    end
    return set
end

-- Meilleur débouché d'une création connue ("ah" | "vendor" | "de").
local function Channel(id)
    local saved, prof, name = CR.ProducerOf(id)
    if not saved then return nil end
    local rec = ns.Queue.FindRecipe and ns.Queue.FindRecipe(prof, name)
    local ev = rec and CR.GetEval(rec)
    return ev and ev.channel, ev
end

-- Plancher : jamais sous le prix marchand, jamais sous le coût de fabrication.
function S.Floor(id)
    local floor = (P.VendorSell(id) or 0) + 1
    local ch, ev = Channel(id)
    if ev and ev.cost and ev.cost > 0 then
        local made = 1
        local saved = CR.ProducerOf(id)
        if saved and saved.m then made = math.max(1, saved.m) end
        floor = math.max(floor, math.ceil(ev.cost / made))
    end
    return floor
end

-- Objets à poster : créations dont le meilleur débouché est l'HV, et compos de désenchantement.
function S.Candidates()
    local reagents = Reagents()
    local by, list = {}, {}
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + 1)
    for bag = 0, last do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and info.itemID
            if id and not info.isBound then
                if by[id] == nil then
                    local ok = IsDEMat(id) or (not reagents[id] and Channel(id) == "ah")
                    by[id] = ok and { id = id, qty = 0, stacks = {} } or false
                end
                local e = by[id]
                if e then
                    e.qty = e.qty + (info.stackCount or 1)
                    e.stacks[#e.stacks + 1] = { bag = bag, slot = slot, count = info.stackCount or 1 }
                end
            end
        end
    end
    for id, e in pairs(by) do
        if e then
            e.qty = e.qty - (ns.Keep and ns.Keep.Get(id) or 0)
            if e.qty > 0 then
                e.commodity = ns.IsCommodity(id)
                list[#list + 1] = e
            end
        end
    end
    table.sort(list, function(a, b) return P.Name(a.id) < P.Name(b.id) end)
    return list
end

-- Prix de mise en vente, ou nil + raison.
function S.PriceFor(e)
    local p = prices[e.id]
    local floor = S.Floor(e.id)
    if not p then return nil, "checking price…", floor end
    local target
    if p.own and (not p.low or p.own <= p.low) then
        target = p.own                       -- vous êtes déjà le moins cher : on s'aligne sur vous
    elseif p.low then
        target = p.low - 1                   -- 1c sous la concurrence
    else
        target = math.max(P.Market(e.id) or 0, floor * 2) -- personne d'autre en vente
    end
    if target < floor then
        return nil, (Tr("market %s is below your floor %s")):format(Money(target), Money(floor)), floor
    end
    return target, nil, floor
end

-- ------------------------------------------------------------ recherches de prix
local function Ready() return not AH.IsThrottledMessageSystemReady or AH.IsThrottledMessageSystemReady() end

local function NextLookup()
    if not lookup then return end
    lookup.i = lookup.i + 1
    local e = lookup.list[lookup.i]
    if not e then lookup = nil; S.Update(); return end
    local function Send()
        if not lookup or lookup.list[lookup.i] ~= e then return end
        if not Ready() then C_Timer.After(0.2, Send); return end
        lookup.cur = e.id
        local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
        local key
        if not e.commodity and e.stacks and e.stacks[1] and AH.GetItemKeyFromItem and ItemLocation then
            local ok, k = pcall(AH.GetItemKeyFromItem, ItemLocation:CreateFromBagAndSlot(e.stacks[1].bag, e.stacks[1].slot))
            if ok then key = k end
        end
        key = key or AH.MakeItemKey(e.id)
        lookup.key = key
        AH.SendSearchQuery(key, sorts, true)
        local my = lookup.i
        C_Timer.After(5, function()
            if lookup and lookup.i == my and lookup.cur == e.id then
                prices[e.id] = prices[e.id] or { t = time() } -- rien trouvé : personne d'autre ne vend
                lookup.cur = nil
                NextLookup()
            end
        end)
        S.Update()
    end
    Send()
end

function S.Lookup(force)
    AH = C_AuctionHouse
    if not AH or not AH.SendSearchQuery or lookup then return end
    local list = {}
    local seen = {}
    for _, e in ipairs(S.Candidates()) do
        local p = prices[e.id]
        if force or not p or time() - p.t > 120 then list[#list + 1] = e; seen[e.id] = true end
    end
    -- Vos annonces aussi, pour savoir si elles sont coupées.
    for _, a in ipairs(owned) do
        local id = a.itemID
        if id and not seen[id] then
            local p = prices[id]
            if force or not p or time() - p.t > 120 then
                list[#list + 1] = { id = id, commodity = ns.IsCommodity(id) }
                seen[id] = true
            end
        end
    end
    if #list == 0 then S.Update(); return end
    lookup = { list = list, i = 0 }
    NextLookup()
end

local function OnCommodityResults(itemID)
    if not lookup or itemID ~= lookup.cur then return end
    local low, own
    for k = 1, (AH.GetNumCommoditySearchResults(itemID) or 0) do
        local r = AH.GetCommoditySearchResultInfo(itemID, k)
        if r and r.unitPrice then
            local mine = (r.numOwnerItems or 0) > 0 or r.containsOwnerItem
            if mine then own = own or r.unitPrice
            elseif not low then low = r.unitPrice end
            if low and own then break end
        end
    end
    prices[itemID] = { low = low, own = own, t = time() }
    lookup.cur = nil
    C_Timer.After(0.05, NextLookup)
end

local function OnItemResults(itemKey)
    if not lookup or not itemKey or itemKey.itemID ~= lookup.cur then return end
    local low, own
    for k = 1, (AH.GetNumItemSearchResults(itemKey) or 0) do
        local r = AH.GetItemSearchResultInfo(itemKey, k)
        local price = r and (r.buyoutAmount or r.bidAmount)
        if price then
            local mine = r.containsOwnerItem
            if mine then own = own and math.min(own, price) or price
            else low = low and math.min(low, price) or price end
        end
    end
    prices[itemKey.itemID] = { low = low, own = own, t = time() }
    lookup.cur = nil
    C_Timer.After(0.05, NextLookup)
end

-- ------------------------------------------------------------ vos annonces
local function ReadOwned()
    wipe(owned)
    if not AH or not AH.GetNumOwnedAuctions then return end
    for i = 1, AH.GetNumOwnedAuctions() do
        local a = AH.GetOwnedAuctionInfo(i)
        if a and a.status == 0 and a.itemKey and a.buyoutAmount and not cancelled[a.auctionID] then
            owned[#owned + 1] = { auctionID = a.auctionID, itemID = a.itemKey.itemID, qty = a.quantity or 1,
                price = a.buyoutAmount }
        end
    end
end

-- Annonce coupée qui vaut d'être annulée : la différence dépasse 2 dépôts et le nouveau prix reste au-dessus du plancher.
-- (Une annonce annulée revient par courrier : on la repostera à la prochaine visite.)
function S.Undercut()
    local out = {}
    local deposit = Rules().deposit or 100
    for _, a in ipairs(owned) do
        local p = prices[a.itemID]
        if p and p.low and p.low < a.price then
            local newPrice = p.low - 1
            local floor = S.Floor(a.itemID)
            local gainLost = (a.price - newPrice) * a.qty
            if newPrice >= floor and gainLost > deposit * 2 then
                out[#out + 1] = { a = a, newPrice = newPrice }
            end
        end
    end
    return out
end

-- ------------------------------------------------------------ objets qui ne se vendent pas
local function Advice(id) return ns.Track and ns.Track.PostAdvice(P.Name(id), id) end

-- En pause (expiré plusieurs fois de suite) : on ne le propose pas.
local function Blocked(id)
    local a = Advice(id)
    return a and (a.pauseUntil or a.vendor) and a or nil
end

-- Quantité à poster : après un échec, 1 objet (gear) ou la moitié de la pile, pour risquer moins de dépôt.
function S.QtyFor(e)
    local a = Advice(e.id)
    if e.commodity then
        return (a and a.streak >= 1) and math.max(1, math.floor(e.qty / 2)) or e.qty
    end
    return (a and a.streak >= 1) and 1 or math.min(e.qty, Rules().postCap)
end

-- ------------------------------------------------------------ actions (un clic chacune)
function S.NextPost()
    for _, e in ipairs(S.Candidates()) do
        if not posted[e.id] and not Blocked(e.id) then
            local price = S.PriceFor(e)
            if price then return e, price end
        end
    end
end

function S.PostNext()
    AH = C_AuctionHouse
    local e, price = S.NextPost()
    if not e then Status(Tr("Nothing to post right now.")); return end
    local rules = Rules()
    local st = e.stacks[1]
    local loc = ItemLocation:CreateFromBagAndSlot(st.bag, st.slot)
    local qty = S.QtyFor(e)
    if e.commodity then
        AH.PostCommodity(loc, rules.postDuration, qty, price)
    else
        AH.PostItem(loc, rules.postDuration, qty, nil, price)
    end
    posted[e.id] = true
    Status((Tr("Posted %d× %s at %s each.")):format(qty, P.Name(e.id), Money(price)))
    C_Timer.After(1, S.Update)
end

function S.CancelNext()
    AH = C_AuctionHouse
    local u = S.Undercut()[1]
    if not u then Status(Tr("No undercut auction to cancel.")); return end
    cancelled[u.a.auctionID] = true
    AH.CancelAuction(u.a.auctionID)
    Status((Tr("Cancelled %d× %s (was %s, market now %s): it comes back by mail, repost it next time.")):format(
        u.a.qty, P.Name(u.a.itemID), Money(u.a.price), Money(u.newPrice + 1)))
    ReadOwned()
    S.Update()
end

-- ------------------------------------------------------------ boutons de la barre HV
function S.Update()
    if not postBtn then return end
    local cands = S.Candidates()
    local e, price = S.NextPost()
    if lookup then
        postBtn.text:SetText((Tr("Checking prices… %d / %d")):format(lookup.i, #lookup.list))
        postBtn:SetDisabled(true)
    elseif e then
        postBtn.text:SetText((Tr("Post %d× %s · %s")):format(S.QtyFor(e),
            P.Name(e.id), ns.FormatMoney(price, { iconSize = 10, short = true })))
        postBtn:SetDisabled(false)
    else
        postBtn.text:SetText(#cands > 0 and "Nothing worth posting" or "Nothing to post")
        postBtn:SetDisabled(true)
    end
    local under = S.Undercut()
    cancelBtn.text:SetText(#under > 0 and (Tr("Cancel undercut (%d)")):format(#under) or "No undercut")
    cancelBtn:SetDisabled(#under == 0)
end

local function PostTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(Tr("Post at the AH"), 1, 1, 1)
    local any = false
    for _, e in ipairs(S.Candidates()) do
        any = true
        local price, why = S.PriceFor(e)
        local left = ("%s ×%d"):format(P.Name(e.id), e.qty)
        local blocked = Blocked(e.id)
        if posted[e.id] then
            GameTooltip:AddDoubleLine(left, "posted", 0.6, 0.6, 0.6, 0.36, 0.82, 0.45)
        elseif blocked then
            local why, what = ns.Track.AdviceText(blocked)
            GameTooltip:AddDoubleLine(left, what, 0.6, 0.6, 0.6, 0.93, 0.55, 0.32)
            GameTooltip:AddLine("    " .. why, 0.5, 0.5, 0.5)
        elseif price then
            GameTooltip:AddDoubleLine(left, Money(price), 0.85, 0.85, 0.85, 1, 1, 1)
        else
            GameTooltip:AddDoubleLine(left, why or "", 0.6, 0.6, 0.6, 0.93, 0.36, 0.32)
        end
    end
    if not any then GameTooltip:AddLine(Tr("Your crafts that sell best at the AH and your enchanting mats show up here."), 0.7, 0.7, 0.7, true) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(Tr("1c under the cheapest other seller, never under your cost or the vendor price."), 0.6, 0.6, 0.6, true)
    GameTooltip:AddLine(Tr("After an expiry: posts 1 at a time. 2 in a row: paused 1, 2, 4… days. 3: vendor it."), 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

local function CancelTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(Tr("Your undercut auctions"), 1, 1, 1)
    local under = S.Undercut()
    for _, u in ipairs(under) do
        GameTooltip:AddDoubleLine(("%s ×%d"):format(P.Name(u.a.itemID), u.a.qty),
            Money(u.a.price) .. " → " .. Money(u.newPrice), 0.85, 0.85, 0.85, 1, 1, 1)
    end
    if #under == 0 then GameTooltip:AddLine(Tr("None worth cancelling (a cancel loses the deposit)."), 0.7, 0.7, 0.7, true) end
    GameTooltip:Show()
end

ns.On("AH_BAR_READY", function(b)
    if postBtn then return end
    bar = b
    AH = C_AuctionHouse
    if not AH or not AH.PostCommodity then return end
    postBtn = T.Button(b, Tr("Post"), 250, 26, function() S.PostNext() end)
    postBtn:SetScript("OnEnter", function(self) self.hover = true; self:Refresh(); PostTooltip(self) end)
    cancelBtn = T.Button(b, Tr("No undercut"), 150, 26, function() S.CancelNext() end)
    cancelBtn:SetScript("OnEnter", function(self) self.hover = true; self:Refresh(); CancelTooltip(self) end)
    -- Placement : après "Buy …" (ajouté par la file) s'il existe, sinon après Scan.
    C_Timer.After(0, function()
        local anchor = b.buyButton or b.scan
        postBtn:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
        cancelBtn:SetPoint("LEFT", postBtn, "RIGHT", 6, 0)
        if b.LayoutStatus then b.LayoutStatus() end
        S.Update()
    end)
end)

-- ------------------------------------------------------------ événements
local ev = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "COMMODITY_SEARCH_RESULTS_UPDATED",
    "ITEM_SEARCH_RESULTS_UPDATED", "OWNED_AUCTIONS_UPDATED", "BAG_UPDATE_DELAYED", "AUCTION_CANCELED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, a1)
    if not ns.db then return end
    if event == "AUCTION_HOUSE_SHOW" then
        AH = C_AuctionHouse
        wipe(posted); wipe(cancelled)
        C_Timer.After(1.5, function()
            if AH and AH.QueryOwnedAuctions then pcall(AH.QueryOwnedAuctions, {}) end
            C_Timer.After(1, function() S.Lookup() end)
        end)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        lookup = nil
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        OnCommodityResults(a1)
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        OnItemResults(a1)
    elseif event == "OWNED_AUCTIONS_UPDATED" then
        ReadOwned()
        S.Update()
    elseif event == "BAG_UPDATE_DELAYED" or event == "AUCTION_CANCELED" then
        if postBtn and AuctionHouseFrame and AuctionHouseFrame:IsShown() then C_Timer.After(0.3, S.Update) end
    end
end)
