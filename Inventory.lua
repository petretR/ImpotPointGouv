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
    ns.db.inv[k].mail = ns.db.inv[k].mail or {}
    return ns.db.inv[k]
end

local function ContainerItem(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then return info.itemID, info.stackCount or 1, info.isBound end
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

-- Objets liés (non vendables à l'HV) : valorisés au prix marchand seulement.
local function Bound() ns.db.bound = ns.db.bound or {}; return ns.db.bound end

local function ScanBags(list, into)
    wipe(into)
    local bound = Bound()
    for _, bag in ipairs(list) do
        for slot = 1, NumSlots(bag) do
            local id, count, isBound = ContainerItem(bag, slot)
            if id then
                into[id] = (into[id] or 0) + count
                if isBound then bound[id] = true elseif isBound == false then bound[id] = nil end
            end
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

-- ------------------------------------------------------------ courrier
-- Objets dans la boîte aux lettres du personnage (relevé à chaque ouverture).
function I.ScanMail()
    local c = DBChar()
    if not c or not GetInboxNumItems then return end
    local into = {}
    local maxAtt = ATTACHMENTS_MAX_RECEIVE or 16
    for i = 1, GetInboxNumItems() do
        for j = 1, maxAtt do
            local _, id, _, count = GetInboxItem(i, j)
            if id then into[id] = (into[id] or 0) + (count or 1) end
        end
    end
    c.mail, c.mailT = into, time()
    -- Ce qui était "en route" vers ce personnage est maintenant dans sa boîte.
    local me = (UnitName("player") or ""):lower()
    if ns.db.transit then ns.db.transit[me] = nil end
end

-- Objets envoyés à un de vos personnages, pas encore relevés dans sa boîte.
local function OwnCharName(recipient)
    if not recipient then return nil end
    local n = recipient:match("^([^%-]+)") or recipient
    n = n:lower()
    for _, ch in pairs(ns.db.chars or {}) do
        if ch.name and ch.name:lower() == n then return n end
    end
end
local function CaptureSend(recipient)
    local who = OwnCharName(recipient)
    if not who or not GetSendMailItem then return end
    local items = {}
    for j = 1, (ATTACHMENTS_MAX_SEND or 12) do
        local _, id, _, count = GetSendMailItem(j)
        if id then items[id] = (items[id] or 0) + (count or 1) end
    end
    if not next(items) then return end
    ns.db.transit = ns.db.transit or {}
    local t = ns.db.transit[who] or {}
    ns.db.transit[who] = t
    for id, n in pairs(items) do t[id] = (t[id] or 0) + n end
end
if type(SendMail) == "function" then
    -- Juste après l'appel, les pièces jointes sont encore dans la fenêtre d'envoi : on note ce qui part vers vos persos.
    hooksecurefunc("SendMail", function(recipient) pcall(CaptureSend, recipient) end)
end

function I.Mail(id)
    local total = 0
    for _, c in pairs(ns.db.inv or {}) do total = total + ((c.mail or {})[id] or 0) end
    for _, t in pairs(ns.db.transit or {}) do total = total + (t[id] or 0) end
    return total
end

-- Détail par personnage : { {nom, sacs, banque, courrier}, ... }, en vente, en route.
function I.Breakdown(id)
    local rows = {}
    for key, c in pairs(ns.db.inv or {}) do
        local b, k, m = (c.bags or {})[id] or 0, (c.bank or {})[id] or 0, (c.mail or {})[id] or 0
        if b + k + m > 0 then
            local ch = ns.db.chars[key]
            rows[#rows + 1] = { (ch and ch.name) or "?", b, k, m }
        end
    end
    table.sort(rows, function(a, b) return (a[2] + a[3] + a[4]) > (b[2] + b[3] + b[4]) end)
    local transit = 0
    for _, t in pairs(ns.db.transit or {}) do transit = transit + (t[id] or 0) end
    return rows, I.Listed(id), transit, ((ns.db.warband or {})[id] or 0)
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

-- Tout ce que vous possédez, objet par objet : { [id] = { bags, bank, mail, listed, warband, transit, total } }.
function I.AllStock()
    local out = {}
    local function Add(id, field, n)
        if not id or not n or n <= 0 then return end
        local e = out[id]
        if not e then e = { bags = 0, bank = 0, mail = 0, listed = 0, warband = 0, transit = 0, total = 0 }; out[id] = e end
        e[field] = e[field] + n
        e.total = e.total + n
    end
    for _, c in pairs(ns.db.inv or {}) do
        for id, n in pairs(c.bags or {}) do Add(id, "bags", n) end
        for id, n in pairs(c.bank or {}) do Add(id, "bank", n) end
        for id, n in pairs(c.mail or {}) do Add(id, "mail", n) end
        for id, n in pairs(c.owned or {}) do Add(id, "listed", n) end
    end
    for id, n in pairs(ns.db.warband or {}) do Add(id, "warband", n) end
    for _, t in pairs(ns.db.transit or {}) do for id, n in pairs(t) do Add(id, "transit", n) end end
    return out
end
function I.IsBound(id) return (ns.db.bound or {})[id] and true or false end

-- Stock total possédé (tous persos, banques, courrier, en route, en vente) : pour le réassort.
function I.Stock(id)
    local alts = I.Alts(id)
    return I.Mine(id) + alts + I.Listed(id) + I.Mail(id)
end

-- ------------------------------------------------------------ événements
local ev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(ev, "Inventory") end
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
    "PLAYERBANKSLOTS_CHANGED", "PLAYERREAGENTBANKSLOTS_CHANGED", "AUCTION_HOUSE_SHOW", "OWNED_AUCTIONS_UPDATED",
    "MAIL_INBOX_UPDATE", "MAIL_CLOSED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
local queued, mailQueued
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
    elseif event == "MAIL_CLOSED" then
        I.ScanMail(); Changed()
    elseif event == "MAIL_INBOX_UPDATE" then
        -- Pendant une récupération, cet événement arrive à chaque courrier : on regroupe.
        if mailQueued then return end
        mailQueued = true
        C_Timer.After(1.5, function() mailQueued = false; I.ScanMail(); Changed() end)
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

-- Profilage (/ipg perf) : fonctions lourdes appelées hors des événements chronométrés.
if ns.Profile then
    I.ScanBags = ns.Profile.Wrap("Inventory:ScanBags", I.ScanBags)
end
