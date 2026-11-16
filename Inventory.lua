-- ImpotPointGouv : inventaire de chaque personnage (sacs, banque), banque de bataillon,
-- et objets que vous avez en vente à l'HV. Sert à la liste de courses du craft.
local _, ns = ...
local I = {}
ns.Inventory = I

local function Key() return UnitGUID("player") end

local function DBChar()
    local k = Key()
    if not k then return nil end
    ns.db.inv = ns.db.inv or {}
    ns.db.inv[k] = ns.db.inv[k] or { bags = {}, bank = {}, owned = {} }
    return ns.db.inv[k]
end

local function ContainerItem(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then return info.itemID, info.stackCount or 1 end
        return nil
    end
    if GetContainerItemInfo then
        local _, count, _, _, _, _, link, _, _, id = GetContainerItemInfo(bag, slot)
        return id or ns.Prices.ItemID(link), count or 1
    end
end

local function NumSlots(bag)
    local fn = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    if not fn then return 0 end
    local ok, n = pcall(fn, bag)
    return ok and n or 0
end

local function ScanBags(list, into)
    wipe(into)
    for _, bag in ipairs(list) do
        for slot = 1, NumSlots(bag) do
            local id, count = ContainerItem(bag, slot)
            if id then into[id] = (into[id] or 0) + count end
        end
    end
end

local function BagIDs()
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + 1)
    local t = {}
    for b = 0, last do t[#t + 1] = b end
    return t
end

local function BankIDs()
    local char, account = {}, {}
    local seen = {}
    local function Add(list, id) if id and not seen[id] then seen[id] = true; list[#list + 1] = id end end
    if Enum and Enum.BagIndex then
        for name, id in pairs(Enum.BagIndex) do
            if type(name) == "string" and name:find("AccountBank") then Add(account, id)
            elseif type(name) == "string" and (name:find("Bank") or name:find("Reagentbank")) then Add(char, id) end
        end
    end
    Add(char, BANK_CONTAINER or -1)
    Add(char, REAGENTBANK_CONTAINER or -3)
    local first = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + 1)) + 1
    for b = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do Add(char, b) end
    return char, account
end

function I.ScanBags()
    local c = DBChar()
    if not c then return end
    ScanBags(BagIDs(), c.bags)
    c.t = time()
end

local bankOpen = false
function I.ScanBank()
    local c = DBChar()
    if not c or not bankOpen then return end
    local char, account = BankIDs()
    ScanBags(char, c.bank)
    if #account > 0 then
        ns.db.warband = ns.db.warband or {}
        local tmp = {}
        ScanBags(account, tmp)
        if next(tmp) then ns.db.warband = tmp end
    end
    c.bankT = time()
end

-- ------------------------------------------------------------ requêtes
-- Ce que le personnage connecté a sous la main (sacs + banque + bataillon).
function I.Mine(id)
    local c = DBChar()
    if not c or not id then return 0 end
    return (c.bags[id] or 0) + (c.bank[id] or 0) + ((ns.db.warband or {})[id] or 0)
end

-- Ce qu'un personnage précis possède (sacs + banque), d'après son dernier passage.
function I.CharCount(key, id)
    local c = (ns.db.inv or {})[key]
    if not c or not id then return 0 end
    return (c.bags[id] or 0) + (c.bank[id] or 0)
end

-- Ce que les autres personnages possèdent : total + détail { {nom, qté}, ... }.
function I.Alts(id)
    local me = Key()
    local total, detail = 0, {}
    for key, c in pairs(ns.db.inv or {}) do
        if key ~= me then
            local n = (c.bags[id] or 0) + (c.bank[id] or 0)
            if n > 0 then
                total = total + n
                local ch = ns.db.chars[key]
                detail[#detail + 1] = { (ch and ch.name) or "?", n }
            end
        end
    end
    table.sort(detail, function(a, b) return a[2] > b[2] end)
    return total, detail
end

-- Quantité mise en vente par vous (tous personnages).
function I.Listed(id)
    local total = 0
    for _, c in pairs(ns.db.inv or {}) do total = total + ((c.owned or {})[id] or 0) end
    return total
end

-- Stock total possédé (tous persos, banques, en vente) : pour le réassort.
function I.Stock(id)
    local alts = I.Alts(id)
    return I.Mine(id) + alts + I.Listed(id)
end

-- ------------------------------------------------------------ événements
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
    "PLAYERBANKSLOTS_CHANGED", "PLAYERREAGENTBANKSLOTS_CHANGED", "AUCTION_HOUSE_SHOW", "OWNED_AUCTIONS_UPDATED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
local queued
local function Changed()
    if queued then return end
    queued = true
    C_Timer.After(0.3, function() queued = false; ns.Fire("INVENTORY_CHANGED") end)
end
ev:SetScript("OnEvent", function(_, event)
    if not ns.db then return end
    if event == "PLAYER_ENTERING_WORLD" or event == "BAG_UPDATE_DELAYED" then
        I.ScanBags()
        if bankOpen then I.ScanBank() end
        Changed()
    elseif event == "BANKFRAME_OPENED" then
        bankOpen = true
        C_Timer.After(0.3, function() I.ScanBank(); Changed() end)
    elseif event == "BANKFRAME_CLOSED" then
        I.ScanBank()
        bankOpen = false
    elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYERREAGENTBANKSLOTS_CHANGED" then
        I.ScanBank(); Changed()
    elseif event == "AUCTION_HOUSE_SHOW" then
        if C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions then
            C_Timer.After(0.5, function() pcall(C_AuctionHouse.QueryOwnedAuctions, {}) end)
        end
    elseif event == "OWNED_AUCTIONS_UPDATED" then
        local c = DBChar()
        if not c or not C_AuctionHouse.GetNumOwnedAuctions then return end
        c.owned = {}
        for i = 1, C_AuctionHouse.GetNumOwnedAuctions() do
            local a = C_AuctionHouse.GetOwnedAuctionInfo(i)
            -- status 0 = en vente, 1 = vendu (en attente de courrier)
            if a and a.itemKey and a.itemKey.itemID and (a.status == nil or a.status == 0) then
                c.owned[a.itemKey.itemID] = (c.owned[a.itemKey.itemID] or 0) + (a.quantity or 1)
            end
        end
        Changed()
    end
end)
