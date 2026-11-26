-- ImpotPointGouv: mail rules ("send all my leather to my bank"), like TSM's mailing operations.
-- A rule says what goes to which character, and how many to keep on the sender:
--   ns.db.mailRules = { { what = { kind, ... }, to = charKey, keep = n, off = bool }, ... }
--   kinds: { kind = "type", class = classID, sub = subclassID }   the game's item type (Leather, Food & Drink...)
--          { kind = "crafted" }                                    items your characters crafted
--          { kind = "list", list = index }                         one of your lists (Lists tab, My lists)
--          { kind = "item", id = itemID }                          one item
-- The first rule that matches an item wins (order set by the player); a character never mails itself.
-- The engine has no UI and is tested in tests/run.lua; Mail.lua shows the button and the editor.
local _, ns = ...
local Tr = ns.L
local R = {}
ns.MailRules = R

-- Item types offered in the editor: { label, classID, subclassID }.
R.TYPES = {
    { Tr("Cloth"), 7, 5 }, { Tr("Leather"), 7, 6 }, { Tr("Metal & Stone"), 7, 7 }, { Tr("Meat & fish"), 7, 8 }, { Tr("Herb"), 7, 9 },
    { Tr("Elemental"), 7, 10 }, { Tr("Enchanting"), 7, 12 }, { Tr("Parts"), 7, 1 }, { Tr("Jewelcrafting"), 7, 4 },
    { Tr("Food & Drink"), 0, 5 }, { Tr("Potion"), 0, 1 }, { Tr("Elixir"), 0, 2 }, { Tr("Flask"), 0, 3 },
    { Tr("Item enhancement"), 0, 6 }, { Tr("Bandage"), 0, 7 },
}

function R.List()
    ns.db.mailRules = ns.db.mailRules or {}
    return ns.db.mailRules
end

local function Instant(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f then return nil end
    local ok, _, _, _, _, _, classID, subID = pcall(f, id)
    if ok then return classID, subID end
end

-- Items made by your characters (craft results seen in the loot log), built once per session.
local crafted
function R.Crafted()
    if not crafted then
        crafted = {}
        for _, e in ipairs(ns.db.loot or {}) do
            if e.s == "c" and e.id then crafted[e.id] = true end
        end
    end
    return crafted
end
function R.Reset() crafted = nil end

function R.Matches(what, id)
    if not what or not id then return false end
    if what.kind == "type" then
        local c, s = Instant(id)
        return c == what.class and s == what.sub
    elseif what.kind == "crafted" then
        return R.Crafted()[id] == true
    elseif what.kind == "list" then
        local l = ns.db.lists and ns.db.lists[what.list]
        for _, x in ipairs(l and l.ids or {}) do if x == id then return true end end
        return false
    elseif what.kind == "item" then
        return what.id == id
    end
    return false
end

-- Plain words for a rule's "what".
function R.Label(what)
    if not what then return "?" end
    if what.kind == "type" then
        for _, t in ipairs(R.TYPES) do if t[2] == what.class and t[3] == what.sub then return t[1] end end
        return Tr("Item type")
    elseif what.kind == "crafted" then return Tr("Items I crafted")
    elseif what.kind == "list" then
        local l = ns.db.lists and ns.db.lists[what.list]
        return (Tr("List: %s")):format(l and l.name or "?")
    elseif what.kind == "item" then return ns.Prices.Name(what.id) end
    return "?"
end

-- What this character should mail, per recipient: { [charKey] = { [itemID] = quantity } } and the rule
-- that picked each item. bags: { [itemID] = count } of mailable items (unbound); me: this character.
function R.Plan(bags, me)
    local out, why = {}, {}
    local rules = R.List()
    for id, count in pairs(bags) do
        for i, rule in ipairs(rules) do
            if not rule.off and rule.to and R.Matches(rule.what, id) then
                if rule.to ~= me then
                    local q = count - (rule.keep or 0)
                    if q > 0 then
                        out[rule.to] = out[rule.to] or {}
                        out[rule.to][id] = q
                        why[id] = i
                    end
                end
                break -- first matching rule wins, even if it keeps everything here
            end
        end
    end
    return out, why
end

-- Mailable items in the bags: { [itemID] = count }.
function R.Bags()
    local by = {}
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + 1)
    for bag = 0, last do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isBound then
                by[info.itemID] = (by[info.itemID] or 0) + (info.stackCount or 1)
            end
        end
    end
    return by
end

-- The recipient with the most items to receive, and its items (nil if nothing matches).
function R.Next(me)
    local plan = R.Plan(R.Bags(), me)
    local best, items, n = nil, nil, 0
    for to, list in pairs(plan) do
        local c = 0
        for _ in pairs(list) do c = c + 1 end
        if c > n then best, items, n = to, list, c end
    end
    return best, items, n
end

function R.Add(what, to, keep)
    local list = R.List()
    list[#list + 1] = { what = what, to = to, keep = math.max(0, math.floor(keep or 0)) }
    return #list
end
function R.Move(i, d)
    local list = R.List()
    local j = i + d
    if not list[i] or not list[j] then return end
    list[i], list[j] = list[j], list[i]
end
function R.Remove(i) table.remove(R.List(), i) end

