-- ImpotPointGouv: "Today" window, the crafts worth doing right now, by profession.
-- The same file keeps the daily helpers other windows use: sending by mail (mailbox), the Auctionator
-- shopping list, and the vendor bar (sell what pays more at a vendor, buy the queue's reagents).
local _, ns = ...
local Tr = ns.L
local T, P, Q, I = ns.Theme, ns.Prices, ns.Queue, ns.Inventory
local C = T.C
local RT = {}
ns.Today = RT
ns.Routine = RT -- older name, still used by the mailbox

local W, H, ROWS = 460, 520, 16
local frame
local mailOpen, ahOpen, merchantOpen = false, false, false

-- ------------------------------------------------------------ roles
local function Me() return UnitGUID("player") end
function RT.Bank() return ns.db.settings.bankChar end
local function CharName(key)
    if not key then return nil end
    local c = ns.db.chars[key]
    local over = ns.db.settings.mailNames and ns.db.settings.mailNames[key]
    -- A full name (first + last name) always wins over a first name alone.
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

-- ------------------------------------------------------------ sending by mail
local sending

local function BagStacks(want)
    local stacks, left = {}, {}
    for id, n in pairs(want) do if n > 0 then left[id] = n end end
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + 1)
    for bag = 0, last do
        local n = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            -- Only whole stacks that fit in what we want to send (the rest is kept).
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
-- Splits the partial stacks into free slots one at a time (the game may refuse a second split
-- while the first one is still locked), waits until each shows in its slot, then sends.
local function DoSplits(cur, splits, free)
    if CursorHasItem and CursorHasItem() then ClearCursor() end
    RT.Status(Tr("Splitting stacks…"))
    local i, tries, target = 0, 0, nil
    local function Fail()
        if CursorHasItem and CursorHasItem() then ClearCursor() end
        sending = nil
        RT.Status(Tr("|cffed5c52The game did not split the stack in time: nothing was sent. Try again.|r"))
        RT.Refresh()
    end
    local Check
    local function Next()
        i, tries = i + 1, 0
        local sp = splits[i]
        if not sp then SendBatch(); return end
        local to = free[i]
        C_Container.SplitContainerItem(sp.bag, sp.slot, sp.count)
        C_Container.PickupContainerItem(to.bag, to.slot)
        target = { bag = to.bag, slot = to.slot, id = sp.id, count = sp.count }
        C_Timer.After(0.2, Check)
    end
    function Check()
        if sending ~= cur then return end
        local info = C_Container.GetContainerItemInfo(target.bag, target.slot)
        if info and info.itemID == target.id and (info.stackCount or 1) == target.count and not info.isLocked then
            cur.stacks[#cur.stacks + 1] = target
            Next()
        elseif tries < 15 then
            tries = tries + 1
            C_Timer.After(0.2, Check)
        else
            Fail()
        end
    end
    Next()
end

function SendBatch()
    if not sending then return end
    if not mailOpen then RT.Status(Tr("Mailbox closed: sending stopped.")); sending = nil; return end
    if #sending.stacks == 0 and not (sending.money and sending.money > 0) then
        -- Summary: what was sent, item by item.
        local parts = {}
        for _, id in ipairs(sending.order) do
            parts[#parts + 1] = ("%d× %s"):format(sending.sent[id], P.Name(id))
        end
        if sending.moneySent then parts[#parts + 1] = ns.FormatMoney(sending.moneySent, { iconSize = 10 }) end
        local msg = (Tr("Sent to %s (%d mail%s): %s")):format(sending.name, sending.mails, sending.mails == 1 and "" or "s",
            #parts > 0 and table.concat(parts, ", ") or "nothing")
        if ns.Mail and ns.Mail.OnSent then ns.Mail.OnSent(msg, sending.name) end
        if MailFrameTab_OnClick then pcall(MailFrameTab_OnClick, nil, 1) end -- back to the inbox
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
    -- The game neither confirmed nor refused: unlock instead of staying on "Sending…".
    C_Timer.After(8, function()
        if sending == cur and cur.waiting and cur.batch == batch then
            sending = nil
            RT.Status((Tr("|cffed5c52No answer from the mailbox for %s: check your sent mail (wrong name?), then try again.|r")):format(cur.name))
            if ClearSendMail then ClearSendMail() end
            RT.Refresh()
        end
    end)
end

-- Generic send (also used by the mailbox "Send" tab): want = { [id] = quantity }, money in copper.
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

-- Groups stacks per item for the preview.
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
    if not name then RT.Status(Tr("|cffed5c52Unknown recipient: add that character on the Characters page.|r")); return end
    local stacks = BagStacks(want)
    if #stacks == 0 then RT.Status(Tr("Nothing to send: ") .. what .. Tr(" not found in your bags.")); return end
    -- Preview: you see and check what goes out.
    local rows = RowsFrom(stacks)
    if not ns.Preview or not ns.Preview.Show(rows, { title = Tr("Send to ") .. name, sub = what, confirm = Tr("Send") }, function(chosen)
        local w = {}
        for _, r in ipairs(chosen) do w[r.id] = r.qty end
        RT.SendTo(name, w, what)
    end) then
        RT.SendTo(name, want, what)
    end
end

-- Bank -> crafter: the materials the crafter is missing for the queue.
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

-- What THIS character can send to the bank: crafts of THEIR professions,
-- and disenchanting materials only if they can disenchant.
-- Crafting material (cloth, bolts, cured leather, bars…): "Trade Goods" class.
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
            -- Only finished items: crafted materials (bolts…) stay for your next crafts.
            for _, r in pairs(recipes) do if r.p and not IsMaterial(r.p) then want[r.p] = math.huge end end
        end
    end
    -- Intermediate products (bolts of cloth, cured leather…): used by your own recipes, kept.
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

-- Crafter -> bank: everything that sells (recipe crafts + disenchanting materials),
-- except what the queue still needs.
-- Best outlet for a craft: "ah" | "vendor" | "de" (nil if it is not a known craft).
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
    -- Keeps what the queue still needs + your "keep" reserve; sends the rest.
    for id in pairs(want) do
        local hold = (keep[id] or 0) + (ns.Keep and ns.Keep.Get(id) or 0)
        if hold > 0 then want[id] = math.max(0, ns.GetItemCount(id) - hold) end
    end
    -- What pays more at the vendor or disenchanted stays here: only AH sales go through the bank.
    for id in pairs(want) do
        local ch = ChannelOf(id)
        if ch == "vendor" or ch == "de" then want[id] = nil end
    end
    return want
end

-- ------------------------------------------------------------ selling to the vendor
-- Crafts whose best outlet is the vendor (minus the "keep" reserve).
-- Materials of your recipes (all known professions): never sold to the vendor by the addon.
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
                -- Bought at the AH to resell to the vendor (vendor flip).
                local fb = ns.db.flipBought and ns.db.flipBought[info.itemID]
                if fb and fb > 0 then want[info.itemID] = math.max(want[info.itemID], fb) end
                -- Expired 3 times in a row at the AH (or lost deposits > gain): the vendor is better.
                if not info.isBound and not reagents[info.itemID] and ns.Track then
                    local adv = ns.Track.PostAdvice((info.hyperlink and info.hyperlink:match("%[(.-)%]")) or ns.GetItemInfo(info.itemID), info.itemID)
                    if adv and adv.vendor then
                        want[info.itemID] = math.max(want[info.itemID], ns.GetItemCount(info.itemID) - (ns.Keep and ns.Keep.Get(info.itemID) or 0))
                    end
                end
                -- Unchecked once in the vendor list: you keep it, never proposed again.
                if RT.VendorKept()[info.itemID] then want[info.itemID] = 0 end
            end
        end
    end
    return want
end
if ns.Profile then VendorWant = ns.Profile.Wrap("Today:VendorWant", VendorWant) end
-- What a vendor would take, computed once per bag change (the vendor bar, Sell and the buttons share it).
local vendorCache
local function VendorWantCached()
    if not vendorCache then vendorCache = VendorWant() end
    return vendorCache
end

-- Items you unchecked in the vendor list: kept for good (Settings > Data to forget them).
function RT.VendorKept()
    ns.db.settings.vendorKeep = ns.db.settings.vendorKeep or {}
    return ns.db.settings.vendorKeep
end

local selling
function RT.SellToVendor(only)
    if selling or not merchantOpen then return end
    local stacks = BagStacks(VendorWant())
    if #stacks == 0 then RT.Status(Tr("Nothing to sell to the vendor.")); return end
    if not only and ns.Preview then
        local rows = RowsFrom(stacks, function(id, q) return (P.VendorSell(id) or 0) * q end)
        ns.Preview.Show(rows, { title = Tr("Sell to this vendor"),
            sub = Tr("Worth more here than at the AH. Uncheck what you keep: it won't be proposed again."),
            confirm = Tr("Sell"), allowNone = true, noneLabel = Tr("Keep them") },
            function(chosen)
                local set, kept = {}, 0
                for _, r in ipairs(chosen) do set[r.id] = true end
                for _, r in ipairs(rows) do
                    if not set[r.id] then RT.VendorKept()[r.id] = true; kept = kept + 1 end
                end
                if kept > 0 then RT.Status((Tr("%d item%s kept: not proposed at the vendor again (Settings > Data to undo).")):format(kept, kept == 1 and "" or "s")) end
                if next(set) then RT.SellToVendor(set) else RT.UpdateMerchantBar(); RT.Refresh() end
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

-- ------------------------------------------------------------ Today: what is worth crafting right now
-- One list, by profession: the recipes your characters know that are profitable at current prices and
-- that the market actually buys (Queue's demand check). For each, who can make it and how many times
-- with the materials they hold.

-- Compact amount for the narrow columns: "1.6 g", "37 s", "8 c" (optionally signed and colored).
local function Short(v, sign)
    local txt = ns.FormatMoneyAxis(v or 0)
    if sign and (v or 0) > 0 then txt = "+" .. txt end
    if sign then txt = ((v or 0) > 0 and "|cff5cd173" or (v or 0) < 0 and "|cffed5c52" or "") .. txt .. "|r" end
    return txt
end

local function Colored(key)
    local name = CharName(key) or "?"
    local c = ns.db.chars[key]
    local r, g, b = ns.ClassColor(c and c.class)
    return ("|cff%02x%02x%02x%s|r"):format(math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), name)
end

-- Characters who know a profession.
local function Knowers(prof)
    local out = {}
    for key in pairs(ns.db.profChars and ns.db.profChars[prof] or {}) do
        if ns.db.chars[key] then out[#out + 1] = key end
    end
    table.sort(out)
    return out
end

-- How many crafts a character's materials allow (bags + bank). Vendor materials never limit it.
-- nil when every material comes from a vendor.
local function CanMake(rec, key)
    local n
    for _, rg in ipairs(rec.reagents or {}) do
        if rg.id and (rg.n or 0) > 0 and not P.IsVendorItem(rg.id) then
            local k = math.floor(I.CharCount(key, rg.id) / rg.n)
            n = n and math.min(n, k) or k
        end
    end
    return n
end

-- Evaluating every recipe is the expensive part (a few hundred ms): done once, then again only when
-- prices, recipes or settings change. Bag changes only recount what you can make.
local evalCache
local function Candidates(prof)
    evalCache = evalCache or {}
    if evalCache[prof] then return evalCache[prof] end
    local rules = ns.Craft.Rules()
    local out = {}
    for _, rec in ipairs(Q.RecipesOf(prof)) do
        local ev = ns.Craft.GetEval(rec)
        if rec.pid and not rec.enchant and ev and ev.profit and not ev.unsold and not ev.whiteGear and not ev.infoPending
            and ev.profit >= (rules.minProfit or 0) and (ev.margin or 0) * 100 >= (rules.minMargin or 0) then
            local verdict, perDay, demand = Q.DemandVerdict(rec, ev, rules)
            if verdict == "queue" then out[#out + 1] = { rec = rec, ev = ev, perDay = perDay, demand = demand } end
        end
    end
    evalCache[prof] = out
    return out
end
function RT.ResetProfitable() evalCache = nil end
-- Prices (scan), recipes (a profession window read) and settings (minimum profit, margin, demand, Master Chef).
for _, e in ipairs({ "PRICES_CHANGED", "LEDGER_READY", "RECIPES_CHANGED", "SETTINGS_CHANGED" }) do
    ns.On(e, function() evalCache = nil; RT.Refresh() end)
end

-- { { prof, who = {keys}, rows = { { rec, ev, perDay, demand, key, can } }, best }, ... } best first.
function RT.Profitable()
    local groups = {}
    for prof in pairs(ns.db.recipes or {}) do
        local who = Knowers(prof)
        if #who > 0 then
            local rows = {}
            for _, c in ipairs(Candidates(prof)) do
                -- The character who can make it the most times (vendor-only materials: no limit).
                local bestKey, bestN = who[1], nil
                for _, k in ipairs(who) do
                    local n = CanMake(c.rec, k)
                    if n == nil then bestKey, bestN = k, nil; break end
                    if not bestN or n > bestN then bestKey, bestN = k, n end
                end
                rows[#rows + 1] = { rec = c.rec, ev = c.ev, perDay = c.perDay or c.ev.profit, demand = c.demand, key = bestKey, can = bestN }
            end
            if #rows > 0 then
                -- What you can make right now first (vendor materials count as available), then the rest.
                table.sort(rows, function(a, b)
                    local ca, cb = a.can == nil or a.can > 0, b.can == nil or b.can > 0
                    if ca ~= cb then return ca end
                    return (a.perDay or 0) > (b.perDay or 0)
                end)
                groups[#groups + 1] = { prof = prof, who = who, rows = rows, best = rows[1].perDay or 0 }
            end
        end
    end
    table.sort(groups, function(a, b) return a.best > b.best end)
    return groups
end
if ns.Profile then RT.Profitable = ns.Profile.Wrap("Today:Profitable", RT.Profitable) end

-- ------------------------------------------------------------ interface
function RT.Status(text)
    if frame then frame.status:SetText(text or "") end
    if ns.Mail and ns.Mail.SendStatus then ns.Mail.SendStatus(text) end
end

local Draw -- defined after Build
local function Build()
    frame = CreateFrame("Frame", "ImpotPointGouvToday", UIParent)
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
    if T.CloseOnEscape then T.CloseOnEscape(frame) end -- Esc without Blizzard's tables (#33)
    frame:SetToplevel(true)

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ns.MEDIA .. "icon.tga"); icon:SetSize(26, 26); icon:SetPoint("TOPLEFT", 14, -12)
    local title = T.Text(frame, 15, { bold = true, text = Tr("Today") }); title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, 1)
    frame.sub = T.Text(frame, 11, { color = C.muted }); frame.sub:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 8, -2)
    frame.sub:SetWidth(W - 100)
    local close = T.CloseButton(frame, function() frame:Hide() end); close:SetPoint("TOPRIGHT", -8, -10)

    local card = CreateFrame("Frame", nil, frame)
    T.Surface(card, C.surface, 10)
    card:SetPoint("TOPLEFT", 12, -50); card:SetPoint("BOTTOMRIGHT", -12, 36)
    local heads = { { Tr("Can make"), 290 }, { Tr("Profit"), 360 }, { Tr("Per day"), W - 24 - 10 } }
    for _, h in ipairs(heads) do
        local t = T.Text(card, 10, { bold = true, color = C.faint, justify = "RIGHT", text = h[1] })
        t:SetPoint("TOPRIGHT", card, "TOPLEFT", h[2], -10); t:SetWidth(70)
    end
    frame.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Frame", nil, card)
        r:SetHeight(24)
        r:SetPoint("TOPLEFT", 8, -28 - (i - 1) * 24); r:SetPoint("TOPRIGHT", -8, -28 - (i - 1) * 24)
        r:EnableMouse(true)
        r.hl = T.Rounded(r, { 1, 1, 1, 0 }, 5, "BACKGROUND", 2)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(18, 18); r.icon:SetPoint("LEFT", 6, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.name = T.Text(r, 12); r.name:SetPoint("LEFT", 30, 0); r.name:SetWidth(210)
        r.can = T.Text(r, 12, { justify = "RIGHT" }); r.can:SetPoint("RIGHT", r, "LEFT", 282, 0); r.can:SetWidth(60)
        r.profit = T.Text(r, 11, { justify = "RIGHT" }); r.profit:SetPoint("RIGHT", r, "LEFT", 352, 0); r.profit:SetWidth(66)
        r.day = T.Text(r, 11, { justify = "RIGHT", color = C.muted }); r.day:SetPoint("RIGHT", -2, 0); r.day:SetWidth(66)
        r:SetScript("OnEnter", function(self)
            local d = self.data
            if not d or not d.rec then return end
            self.hl:SetColor({ 1, 1, 1, 0.04 })
            T.ItemTooltip(self, d.rec.pid)
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine(Tr("Profit per craft"), ns.FormatMoney(d.ev.profit, { sign = true, color = true, iconSize = 11 }), 0.7, 0.7, 0.7)
            if d.demand then GameTooltip:AddDoubleLine(Tr("Sold per day (market)"), ("%.1f"):format(d.demand), 0.7, 0.7, 0.7, 1, 1, 1) end
            if d.perDay then GameTooltip:AddDoubleLine(Tr("Expected profit per day"), ns.FormatMoney(d.perDay, { iconSize = 11 }), 0.7, 0.7, 0.7, 1, 1, 1) end
            GameTooltip:AddDoubleLine(Tr("Sells at"), ns.ChannelLabel(d.ev.channel), 0.7, 0.7, 0.7, 1, 1, 1)
            if d.key then GameTooltip:AddDoubleLine(Tr("Crafted by"), Colored(d.key), 0.7, 0.7, 0.7) end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function(self) self.hl:SetColor({ 1, 1, 1, 0 }); GameTooltip:Hide() end)
        frame.rows[i] = r
    end
    frame.empty = T.Text(card, 12, { color = C.faint, justify = "CENTER", wrap = true })
    frame.empty:SetPoint("CENTER", 0, 0); frame.empty:SetWidth(W - 80)
    frame.off = 0
    card:EnableMouseWheel(true)
    card:SetScript("OnMouseWheel", function(_, d)
        frame.off = math.max(0, math.min(math.max(0, #(frame.lines or {}) - ROWS), frame.off - d * 2)); Draw()
    end)

    frame.status = T.Text(frame, 11, { color = C.muted, wrap = false })
    frame.status:SetPoint("BOTTOMLEFT", 16, 14); frame.status:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
    frame:SetScript("OnShow", function() frame.lines = nil; Draw() end)
    frame:Hide()
end

-- The list, flattened: a header line per profession, then its crafts.
local function Lines()
    local lines = {}
    for _, g in ipairs(RT.Profitable()) do
        local names = {}
        for _, k in ipairs(g.who) do names[#names + 1] = Colored(k) end
        lines[#lines + 1] = { head = true, text = Tr(g.prof) .. "   |cff8a877f" .. table.concat(names, ", ") .. "|r" }
        for _, row in ipairs(g.rows) do lines[#lines + 1] = row end
    end
    return lines
end

Draw = function()
    if not frame or not frame:IsShown() then return end
    if not frame.lines then frame.lines = Lines() end
    local lines = frame.lines
    local last = ns.db.scan and ns.db.scan[ns.Realm()] and ns.db.scan[ns.Realm()].lastFull
    frame.sub:SetText(Tr("Profitable crafts right now") .. (last and ("   ·   " .. (Tr("prices from %s ago")):format(ns.Prices.Ago(time() - last))) or ""))
    frame.off = math.min(frame.off, math.max(0, #lines - ROWS))
    for i, r in ipairs(frame.rows) do
        local d = lines[frame.off + i]
        r.data = d
        if not d then
            r:Hide()
        elseif d.head then
            r.icon:Hide(); r:SetAlpha(1)
            r.name:SetPoint("LEFT", 8, 0); r.name:SetWidth(W - 60)
            r.name:SetText("|cffe0a83d" .. d.text .. "|r")
            r.can:SetText(""); r.profit:SetText(""); r.day:SetText("")
            r:Show()
        else
            r.icon:Show(); r.icon:SetTexture(d.rec.icon or ns.GetItemIcon(d.rec.pid) or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.name:SetPoint("LEFT", 30, 0); r.name:SetWidth(210)
            r.name:SetText(d.rec.name)
            r:SetAlpha((d.can == nil or d.can > 0) and 1 or 0.5) -- missing materials: dimmed
            r.can:SetText(d.can == nil and "|cff8a877f" .. Tr("vendor") .. "|r" or d.can > 0 and ("×" .. d.can) or "|cff615f5c0|r")
            r.profit:SetText(Short(d.ev.profit, true))
            r.day:SetText(Short(d.perDay))
            r:Show()
        end
    end
    frame.empty:SetShown(#lines == 0)
    frame.empty:SetText(next(ns.db.recipes or {}) and Tr("Nothing profitable that sells right now. Scan the AH for fresh prices, or come back later.")
        or Tr("Open each of your professions once so the addon knows your recipes."))
end
RT.Draw = Draw

-- Something changed (bags, prices, recipes): rebuild the list shortly, once.
function RT.Refresh()
    vendorCache = nil
    if not frame or not frame:IsShown() then return end
    if frame.pending then return end
    frame.pending = true
    C_Timer.After(0.3, function()
        frame.pending = false
        if frame:IsShown() then frame.lines = nil; Draw() end
    end)
end

function RT.Toggle()
    if not frame then Build() end
    frame:SetShown(not frame:IsShown())
    if frame:IsShown() then frame:Raise() end
end

function RT.Show()
    if not frame then Build() end
    frame.lines = nil
    frame:Show(); frame:Raise()
    Draw()
end

-- ------------------------------------------------------------ vendor bar
-- Docked to the vendor: buy the queue's materials, sell what is worth more here. Each button opens the preview.
local mbar
function RT.UpdateMerchantBar()
    if not MerchantFrame or not MerchantFrame:IsShown() or not ns.db then if mbar then mbar:Hide() end; return end
    if not mbar then
        mbar = CreateFrame("Frame", nil, MerchantFrame)
        mbar:SetSize(10, 36)
        mbar:SetPoint("BOTTOMLEFT", MerchantFrame, "TOPLEFT", 60, 4)
        mbar:SetFrameLevel((MerchantFrame:GetFrameLevel() or 1) + 10)
        T.Surface(mbar, C.window, 10, { 1, 1, 1, 0.09 })
        local icon = mbar:CreateTexture(nil, "ARTWORK"); icon:SetTexture(ns.MEDIA .. "icon.tga")
        icon:SetSize(20, 20); icon:SetPoint("LEFT", 8, 0)
        mbar.buy = T.Button(mbar, "", 200, 26, function() Q.BuyVendorNeeds(false) end)
        mbar.buy:SetPoint("LEFT", icon, "RIGHT", 8, 0)
        mbar.buy.tooltip = Tr("Reagents your craft queue still needs, at this vendor's price. You confirm the list first.")
        mbar.sell = T.Button(mbar, "", 200, 26, function() RT.SellToVendor() end)
        mbar.sell.tooltip = Tr("Crafts worth more at the vendor than at the AH, your vendor flips, and items that keep expiring at the AH. You confirm the list first.")
    end
    local nb = Q.VendorNeedCount()
    local ns2 = 0
    for _, st in ipairs(BagStacks(VendorWantCached())) do ns2 = ns2 + st.count end
    mbar.buy:SetShown(nb > 0); mbar.sell:SetShown(ns2 > 0 and not selling)
    mbar.buy.text:SetText((Tr("Buy queue reagents (%d)")):format(nb))
    mbar.sell.text:SetText((Tr("Sell to vendor (%d)")):format(ns2))
    mbar.sell:ClearAllPoints()
    if nb > 0 then mbar.sell:SetPoint("LEFT", mbar.buy, "RIGHT", 6, 0) else mbar.sell:SetPoint("LEFT", mbar, "LEFT", 36, 0) end
    local w = 36 + (nb > 0 and 206 or 0) + (ns2 > 0 and 206 or 0) + 4
    mbar:SetWidth(w)
    mbar:SetShown(nb > 0 or ns2 > 0)
end

-- Is there anything to send from this character?
function RT.HasSomethingToSend()
    local me, bank, crafter = Me(), RT.Bank(), Q.Crafter()
    if bank and me ~= bank then
        if #BagStacks(CraftsWant()) > 0 then return true end
    end
    if crafter and me ~= crafter and next(ns.db.queue or {}) then return true end
    return false
end

-- ------------------------------------------------------------ events
local ev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(ev, "Today") end
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SEND_SUCCESS",
    "MAIL_FAILED", "BAG_UPDATE_DELAYED", "MERCHANT_SHOW", "MERCHANT_CLOSED", "UI_ERROR_MESSAGE" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, ...)
    if not ns.db then return end
    if event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
    elseif event == "MERCHANT_SHOW" then
        merchantOpen = true
        vendorCache = nil
        C_Timer.After(0.3, RT.UpdateMerchantBar)
    elseif event == "MERCHANT_CLOSED" then
        merchantOpen = false; RT.Refresh()
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ahOpen = false; RT.Refresh()
    elseif event == "MAIL_SHOW" then
        mailOpen = true
        local c = ns.db.chars[Me()]
        if c then c.lastMail = time() end
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
        -- The game refuses the send (unknown recipient, etc.): show it right away instead of waiting.
        local a, b = ...
        local text = type(b) == "string" and b or (type(a) == "string" and a) or nil
        if sending and sending.waiting and text then
            RT.Status(("|cffed5c52%s (%s)|r"):format(text, sending.name))
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
        vendorCache = nil
        if frame and frame:IsShown() then C_Timer.After(0.3, RT.Refresh) end
        if merchantOpen then C_Timer.After(0.3, RT.UpdateMerchantBar) end
    end
end)
ns.On("INVENTORY_CHANGED", function() RT.Refresh() end)
