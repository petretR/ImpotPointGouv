-- ImpotPointGouv: lists of items to watch (raid, pre-BiS, profession leveling, cooldowns, custom lists).
-- * Lists are built from Data.lua; recipe materials are asked from the game
--   (GetRecipeSchematic), otherwise taken from your characters' known recipes, otherwise the fallback table.
-- * For each item: usual price, low/high, volatility, estimated sales, and a verdict
--   (buy / sell / farm). Buying only takes the units under the limit, checked against the live price.
local _, ns = ...
local Tr = ns.L
local P = ns.Prices
local LS = {}
ns.Lists = LS

LS.PROF_NAME = { alch = "Alchemy", bs = "Blacksmithing", ench = "Enchanting", eng = "Engineering",
    lw = "Leatherworking", tail = "Tailoring", cook = "Cooking", fa = "First Aid" }
LS.ROLES = { { "tank", "Tank" }, { "melee", "Melee" }, { "ranged", "Ranged" }, { "caster", "Caster" }, { "heal", "Healer" } }
local ALL_ROLES = { tank = true, melee = true, ranged = true, caster = true, heal = true }

local function Data() return ns.Data or {} end
local function RDB() ns.db.reagents = ns.db.reagents or {}; return ns.db.reagents end

local function Instant(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f or not id then return nil end
    local ok, _, _, _, equipLoc, icon, classID, subID = pcall(f, id)
    if ok then return classID, subID, icon, equipLoc end
end
LS.Instant = Instant

-- ------------------------------------------------------------ recipe materials
-- Items made per craft, read from the game's recipe schematic (known or not).
-- ns.db.made: seen in a profession window (reliable, kept); schMade: asked from the game this session.
local schMade, schTried = {}, {}
local function MadeOf(sch)
    if type(sch) ~= "table" or not sch.outputItemID or not sch.quantityMin or sch.quantityMin <= 0 then return nil end
    return sch.outputItemID, (sch.quantityMin + math.max(sch.quantityMin, sch.quantityMax or 0)) / 2
end
-- Called by the profession window reader for each recipe, learned or not.
function LS.NoteMade(sch)
    local id, m = MadeOf(sch)
    if id then ns.db.made = ns.db.made or {}; ns.db.made[id] = m end
end
local function Schematic(spellID)
    if not spellID or not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeSchematic then return nil end
    schTried[spellID] = true
    local ok, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, spellID, false)
    if not ok or type(sch) ~= "table" then return nil end
    local id, m = MadeOf(sch)
    if id and not schMade[id] then schMade[id] = m end
    return sch
end

local function FromSchematic(spellID)
    local sch = Schematic(spellID)
    if not sch or not sch.reagentSlotSchematics then return nil end
    local out = {}
    local basicType = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
    for _, slot in ipairs(sch.reagentSlotSchematics) do
        local r = slot.reagents and slot.reagents[1]
        if r and r.itemID and (not basicType or slot.reagentType == nil or slot.reagentType == basicType) then
            out[#out + 1] = { r.itemID, slot.quantityRequired or 1 }
        end
    end
    return #out > 0 and out or nil
end

-- Item name -> id, from everything the addon knows (names in the game's language).
local nameIndex
local function NameIndex()
    if nameIndex then return nameIndex end
    nameIndex = {}
    local function Put(id)
        local n = id and ns.GetItemInfo(id)
        if n then nameIndex[n] = id end
    end
    for id, n in pairs(ns.db.items or {}) do nameIndex[n] = id end
    local D = Data()
    for id in pairs(D.items or {}) do Put(id) end
    for _, r in pairs(D.spellReagents or {}) do for _, rg in ipairs(r) do Put(rg[1]) end end
    for _, r in pairs(D.reagents or {}) do for _, rg in ipairs(r) do Put(rg[1]) end end
    for _, rows in pairs(D.level or {}) do for _, row in ipairs(rows) do Put(row[3]) end end
    return nameIndex
end

-- Fallback: the tooltip of the recipe item (pattern, formula…) shows "Reagents: X (2), Y".
local function FromRecipeTooltip(rec)
    if not rec or not C_TooltipInfo or not C_TooltipInfo.GetItemByID then return nil end
    local ok, data = pcall(C_TooltipInfo.GetItemByID, rec)
    if not ok or type(data) ~= "table" or not data.lines then
        ns.RequestItem(rec)
        return nil
    end
    local head = SPELL_REAGENTS and SPELL_REAGENTS:gsub("%%s", ""):gsub("[:：]%s*$", ""):gsub("%s+$", "") or nil
    for _, line in ipairs(data.lines) do
        local t = line.leftText and line.leftText:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        local list = t and ((head and head ~= "" and t:match("^" .. head:gsub("%p", "%%%0") .. "%s*[:：]%s*(.+)$"))
            or t:match("^Reagents%s*:%s*(.+)$") or t:match("^Composants%s*:%s*(.+)$"))
        if list then
            local out, idx, miss = {}, NameIndex(), 0
            for part in (list .. ","):gmatch("%s*(.-)%s*,") do
                local name, n = part:match("^(.-)%s*%((%d+)%)$")
                name = name or part
                local id = idx[name]
                if id then out[#out + 1] = { id, tonumber(n) or 1 } elseif name ~= "" then miss = miss + 1 end
            end
            if #out > 0 and miss == 0 then return out end
            return nil
        end
    end
end

-- Asks the game for the materials of every recipe in the lists. Returns found, total.
-- Recipes already tried this session (schematic then tooltip): do not ask the game again on each pass,
-- every tooltip request loads items and triggers cascading events.
local resolveTried = {}
local lastResolve, sweepRunning = 0, false
-- Number made by the other recipes (intermediates like Cured Rugged Hide), once per session,
-- in batches of 60 so the game does not freeze.
local function SweepSchematics()
    if sweepRunning then return end
    local todo = {}
    for spell, t in pairs(Data().allRecipes or {}) do
        if t[1] ~= 0 and not schTried[spell] and not schMade[t[1]] then todo[#todo + 1] = spell end
    end
    if #todo == 0 then return end
    sweepRunning = true
    local i = 1
    local function Batch()
        local t0 = debugprofilestop and debugprofilestop()
        for k = i, math.min(#todo, i + 59) do Schematic(todo[k]) end
        if t0 and ns.Profile then ns.Profile.Add("Lists:SchematicBatch", debugprofilestop() - t0) end
        i = i + 60
        if i <= #todo then C_Timer.After(0.1, Batch) else sweepRunning = false; LS.dirty = true end
    end
    Batch()
end
function LS.ResolveReagents(force)
    if not force and LS.resolved and GetTime and GetTime() - lastResolve < 30 then
        return LS.resolved.found, LS.resolved.total
    end
    lastResolve = GetTime and GetTime() or 0
    local db, D = RDB(), Data()
    local found, total = 0, 0
    local newFound = false
    local function Try(spell, rec)
        if not spell then return end
        total = total + 1
        if db[spell] or (D.spellReagents and D.spellReagents[spell]) then
            if not schTried[spell] then Schematic(spell) end -- for the number made
            found = found + 1; return
        end
        if resolveTried[spell] then return end
        resolveTried[spell] = true
        local r = FromSchematic(spell) or FromRecipeTooltip(rec)
        if r then db[spell] = r; found = found + 1; newFound = true end
    end
    for _, it in pairs(D.items or {}) do Try(it.s, it.rec) end
    for spell, e in pairs(D.ench or {}) do Try(spell, e.rec) end
    for _, cd in ipairs(D.cooldowns or {}) do Try(cd.s) end
    SweepSchematics()
    LS.resolved = { found = found, total = total, t = time() }
    if newFound or not LS.groups then nameIndex = nil; LS.dirty = true end
    return found, total
end
-- New known recipes (profession window): the missing ones can be tried again.
function LS.RetryReagents() resolveTried = {}; lastResolve = 0 end

-- Product -> materials, from the recipes your characters know (profession window opened).
-- Also keeps the number of items made per craft, as the game shows it.
local productIndex, madeIndex
local function ProductIndex()
    if productIndex then return productIndex end
    productIndex, madeIndex = {}, {}
    for _, recipes in pairs(ns.db.recipes or {}) do
        for _, r in pairs(recipes) do
            if r.p and r.r and #r.r > 0 then
                productIndex[r.p] = r.r
                if r.m and r.m > 0 then madeIndex[r.p] = r.m end
            end
        end
    end
    return productIndex
end

-- Items made per craft, from the recipe data (the smallest if several recipes make it).
local dataMade
local function DataMade(id)
    if not dataMade then
        dataMade = {}
        for _, t in pairs(Data().allRecipes or {}) do
            local out, n = t[1], t[6] or 1
            if out and out ~= 0 and n > 0 and (not dataMade[out] or n < dataMade[out]) then dataMade[out] = n end
        end
    end
    return dataMade[id]
end

-- Number of items made by one craft (e.g. Cured Rugged Hide: 2). The game first (known recipes,
-- then any recipe seen in a profession window, then the schematic asked from the game), otherwise the data, otherwise 1.
-- ------------------------------------------------------------ food buffs (Cooking list filter)
-- Read from the item tooltip ("well fed: +12 Stamina…"), so Forever's own foods work too.
-- Character sheet order.
LS.FOOD_STATS = { { "str", "Strength" }, { "agi", "Agility" }, { "sta", "Stamina" }, { "int", "Intellect" },
    { "spi", "Spirit" }, { "ap", "AP" }, { "sp", "SP" }, { "hp", "HP" }, { "misc", "Misc" } }
local FOOD_WORDS = {
    sta = { "stamina", "endurance" },
    agi = { "agility", "agilité" },
    str = { "strength", "force" },
    int = { "intellect", "intelligence" },
    spi = { "spirit", "esprit" },
    ap = { "attack power", "puissance d'attaque" },
    -- "damage and healing done by spells" counts for both SP and HP.
    sp = { "spell damage", "spell power", "damage and healing", "dégâts des sorts", "puissance des sorts",
        "dégâts et les soins" },
    hp = { "healing done", "healing spells", "healing power", "healing by", "damage and healing",
        "soins prodigués", "puissance de soins", "dégâts et les soins" },
}
local foodTags, scanTip, foodTries, redrawSoon = {}, nil, {}, false
-- The game fills an item's "Use:" line only once its spell is loaded: until then, try again a bit later.
local function RetryLater()
    if redrawSoon or not C_Timer then return end
    redrawSoon = true
    C_Timer.After(1, function()
        redrawSoon = false
        if ns.ListsUI and ns.ListsUI.Soon then ns.ListsUI.Soon() end
    end)
end
local function RequestFood(id)
    if ns.RequestItem then ns.RequestItem(id)
    elseif C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
end
-- A food's buffs ({ sta = true, … }; { misc = true } without a tracked stat), nil while the item loads.
function LS.FoodTags(id)
    if not id then return nil end
    if foodTags[id] then return foodTags[id] end
    if not scanTip then
        if not CreateFrame then return nil end
        scanTip = CreateFrame("GameTooltip", "ImpotPointGouvScanTip", UIParent, "GameTooltipTemplate")
    end
    if not scanTip.SetItemByID or not ns.GetItemInfo(id) then RequestFood(id); return nil end
    scanTip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetItemByID(id)
    local parts = {}
    for i = 2, scanTip:NumLines() or 0 do
        local fs = _G["ImpotPointGouvScanTipTextLeft" .. i]
        local t = fs and fs:GetText()
        if t then parts[#parts + 1] = t:lower() end
    end
    scanTip:Hide()
    local text = " " .. table.concat(parts, " ") .. " "
    local use = ((ITEM_SPELL_TRIGGER_ONUSE or "Use:"):lower()):gsub("[:：%s]+$", "")
    if not text:find(use, 1, true) and not text:find("use:", 1, true) and not text:find("utiliser", 1, true) then
        -- No "Use:" line yet (spell text not loaded). A few tries, then keep what we have (Misc).
        foodTries[id] = (foodTries[id] or 0) + 1
        if foodTries[id] < 10 then RequestFood(id); RetryLater(); return nil end
    end
    local tags, any = {}, false
    for key, words in pairs(FOOD_WORDS) do
        for _, w in ipairs(words) do
            if text:find("%f[%a]" .. w:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1") .. "%f[%A]") then
                tags[key], any = true, true
                break
            end
        end
    end
    if not any then tags.misc = true end
    foodTags[id] = tags
    return tags
end
-- Data saved by a temporary debug command during development: no longer used.
ns.On("DB_READY", function() if ns.db then ns.db.foodDump = nil end end)

-- Does the food have this buff? ("all": everything passes; not loaded yet: only under "all")
function LS.FoodMatch(id, stat)
    if not stat or stat == "all" then return true end
    local t = LS.FoodTags(id)
    return t ~= nil and t[stat] == true
end

function LS.YieldOf(id)
    if not id then return 1 end
    ProductIndex()
    local y = madeIndex[id] or (ns.db.made and ns.db.made[id]) or schMade[id]
    if not y then
        local D = Data()
        local it = D.items and D.items[id]
        local t = it and it.s and D.allRecipes and D.allRecipes[it.s]
        y = (t and t[1] == id and t[6]) or DataMade(id)
    end
    return ((y and y > 0) and y or 1) * ns.YieldBonus(id)
end

-- Readable quantity: whole numbers as is, otherwise at most two decimals (0.5, 0.33).
function LS.FmtQty(n)
    if not n then return "" end
    if math.abs(n - math.floor(n + 0.5)) < 1e-6 then return tostring(math.floor(n + 0.5)) end
    return (("%.2f"):format(n):gsub("0+$", ""))
end

local function IsVendor(id) return P.IsVendorItem and P.IsVendorItem(id) end

-- Materials of a crafted item (without items sold by vendors, unless withVendor), or nil.
function LS.ReagentsOf(id, withVendor)
    local D = Data()
    local it = D.items and D.items[id]
    local r = (it and it.s and (RDB()[it.s] or (D.spellReagents and D.spellReagents[it.s]))) or ProductIndex()[id] or (D.reagents and D.reagents[id])
    if not r then return nil end
    local out = {}
    for _, rg in ipairs(r) do
        if rg[1] and (withVendor or not IsVendor(rg[1])) then out[#out + 1] = rg end
    end
    return out
end

-- ------------------------------------------------------------ building the lists
local function RolesOf(sp)
    local out = {}
    if not sp then return ALL_ROLES end
    local specs = Data().specs or {}
    for idx in sp:gmatch("%d+") do
        local s = specs[tonumber(idx)]
        if s then out[s[3]] = true end
    end
    return next(out) and out or ALL_ROLES
end

local function NewList(key, title, info)
    return { key = key, title = title, info = info, entries = {}, byId = {}, recipes = {} }
end

local function Add(list, id, kind, roles, qty, note)
    if not id then return end
    local e = list.byId[id]
    if not e then
        e = { id = id, kind = kind, roles = {}, uses = 0, qty = 0 }
        list.byId[id] = e
        list.entries[#list.entries + 1] = e
    elseif kind == "product" then
        e.kind = "product"
    end
    e.uses = e.uses + 1
    for r in pairs(roles or ALL_ROLES) do e.roles[r] = true end
    if qty then e.qty = e.qty + qty end
    if note and not e.note then e.note = note end
end

-- Materials (and materials of intermediates, 2 levels) of a product. mult = number of items wanted;
-- a craft that makes several (Cured Rugged Hide ×2) needs proportionally fewer materials.
local function AddMats(list, id, roles, depth, mult)
    local rg = LS.ReagentsOf(id)
    if not rg then return false end
    local crafts = (mult or 1) / LS.YieldOf(id)
    for _, r in ipairs(rg) do
        local n = crafts * (r[2] or 1)
        Add(list, r[1], "mat", roles, n)
        if (depth or 0) < 2 then AddMats(list, r[1], roles, (depth or 0) + 1, n) end
    end
    return true
end

-- Recipe shown in the "by recipe" view: product (or enchant) then its materials (2 levels).
-- mult = number of crafts; quantities are per item made (divided by what the craft makes).
-- Vendor supplies stay in the tree (4th field = true) to count in the cost, without children.
local function Tree(rg, depth, out, mult, flat)
    for _, r in ipairs(rg or {}) do
        if r[1] then
            local n = (mult or 1) * (r[2] or 1)
            if IsVendor(r[1]) then
                out[#out + 1] = { r[1], n, depth, true }
            else
                out[#out + 1] = { r[1], n, depth }
                if depth < 2 and not flat then Tree(LS.ReagentsOf(r[1], true), depth + 1, out, n / LS.YieldOf(r[1])) end
            end
        end
    end
    return out
end

local function AddRecipe(list, rec, rg)
    -- Cooldowns (transmutes…): direct materials only, otherwise the essences "transmute" in a loop.
    rec.mats = Tree(rg or (rec.id and LS.ReagentsOf(rec.id, true)), 1, {}, rec.id and 1 / LS.YieldOf(rec.id) or 1, rec.cd ~= nil)
    rec.name = rec.name or (rec.id and P.Name(rec.id)) or "?"
    list.recipes[#list.recipes + 1] = rec
    for _, m in ipairs(rec.mats) do
        local e = list.byId[m[1]]
        if e then
            e.usedIn = e.usedIn or {}
            if not e.usedIn[rec] then e.usedIn[rec] = m[2]; e.usedInN = (e.usedInN or 0) + 1 end
        end
    end
end
LS.AddRecipe = AddRecipe

local function ArmorBucket(id)
    local classID, subID, _, equipLoc = Instant(id)
    if classID == 2 or equipLoc == "INVTYPE_SHIELD" or equipLoc == "INVTYPE_HOLDABLE" then return "weapon" end
    if classID == 4 and equipLoc ~= "INVTYPE_CLOAK" then
        if subID == 1 then return "cloth" elseif subID == 2 then return "leather"
        elseif subID == 3 then return "mail" elseif subID == 4 then return "plate" end
    end
    return "other"
end

function LS.Build()
    local D = Data()
    productIndex = nil
    local groups = {}

    -- Raid: consumables, enchants, cooldowns
    local consum = NewList("consum", Tr("Consumables"), "Flasks, elixirs, potions, food, weapon oils and stones, armor kits, and what they're made of.")
    local seen = {}
    local function IsGear(id, it)
        if not it.g then return false end
        local classID = Instant(id)
        return classID ~= 0 and classID ~= 7 and classID ~= 8
    end
    LS._IsGear = IsGear
    for id, it in pairs(D.items or {}) do
        if not IsGear(id, it) and not it.low then
            seen[id] = true
            local roles = RolesOf(it.sp)
            Add(consum, id, "product", roles)
            AddMats(consum, id, roles)
            AddRecipe(consum, { id = id, roles = roles })
        end
    end
    for _, id in ipairs(D.raidConsumables or {}) do
        if not seen[id] then
            Add(consum, id, "product", ALL_ROLES); AddMats(consum, id, ALL_ROLES)
            AddRecipe(consum, { id = id, roles = ALL_ROLES })
        end
    end

    local ench = NewList("enchant", Tr("Enchanting"), "Materials of the enchants used by each spec.")
    local nRes = 0
    for spell, e in pairs(D.ench or {}) do
        if not e.low then
            local r = RDB()[spell] or (D.spellReagents and D.spellReagents[spell])
            if r then
                nRes = nRes + 1
                local roles = RolesOf(e.sp)
                for _, rg in ipairs(r) do
                    if not IsVendor(rg[1]) then
                        Add(ench, rg[1], "mat", roles, rg[2])
                        AddMats(ench, rg[1], roles, 1, rg[2])
                    end
                end
                AddRecipe(ench, { spell = spell, name = e.n, roles = roles }, r)
            end
        end
    end
    -- Enchants whose materials the game has not given yet: the usual raid materials.
    if nRes == 0 then
        for _, id in ipairs(D.enchantMats or {}) do Add(ench, id, "mat", ALL_ROLES) end
        ench.info = ench.info .. Tr(" (Showing the usual raid enchanting materials until the game provides the exact recipes.)")
    end

    -- All recipes of a profession (cooking, alchemy): each product with its materials.
    -- Materials: the game first, otherwise the Classic data, otherwise the recipe data (DataRecipes).
    local function ProfList(key, title, info, code)
        local l = NewList(key, title, info)
        l.noRoles = true
        local spells = {}
        for spell, t in pairs(D.allRecipes or {}) do
            if t[2] == code and t[1] ~= 0 then spells[#spells + 1] = spell end
        end
        table.sort(spells)
        for _, spell in ipairs(spells) do
            local t = D.allRecipes[spell]
            local id = t[1]
            local rg = RDB()[spell] or (D.spellReagents and D.spellReagents[spell])
            if not rg then
                rg = {}
                for i = 9, #t, 2 do rg[#rg + 1] = { t[i], t[i + 1] or 1 } end
            end
            Add(l, id, "product", ALL_ROLES)
            for _, m in ipairs(Tree(rg, 1, {}, 1 / LS.YieldOf(id))) do
                if not m[4] then Add(l, m[1], "mat", ALL_ROLES) end -- vendor supplies: not in the shopping list
            end
            AddRecipe(l, { id = id, spell = spell, roles = ALL_ROLES }, rg)
        end
        return l
    end
    local cook = ProfList("all_cook", Tr("Cooking"), Tr("Every cooking recipe and what it's made of."), 6)
    local alch = ProfList("all_alch", Tr("Alchemy"), Tr("Every alchemy recipe and what it's made of."), 4)

    -- Cooldowns, one list per profession: each cooldown with its materials.
    local cdLists, cdBy = {}, {}
    local CD_TITLE = { alch = Tr("Alchemy: transmutes"), tail = Tr("Tailoring: Mooncloth"), lw = Tr("Leatherworking: salt") }
    for _, cd in ipairs(D.cooldowns or {}) do
        local l = cdBy[cd.p]
        if not l then
            l = NewList("cd_" .. cd.p, CD_TITLE[cd.p] or Tr(LS.PROF_NAME[cd.p] or cd.p), "Daily or multi-day crafts: limited supply, steadier margins.")
            l.cd, l.prof = true, cd.p
            cdBy[cd.p] = l
            cdLists[#cdLists + 1] = l
        end
        Add(l, cd.out, "product", ALL_ROLES, nil, cd.n)
        for _, rg in ipairs(cd.r or {}) do Add(l, rg[1], "mat", ALL_ROLES, rg[2]) end
        if cd.item then Add(l, cd.item, "tool", ALL_ROLES, nil, "Tool") end
        AddRecipe(l, { id = cd.out, name = cd.n, roles = ALL_ROLES, cd = cd }, cd.r)
    end
    groups[#groups + 1] = { key = "raid", title = Tr("CONSUMES & ENCHANTS"), lists = { consum, ench, cook, alch } }
    groups[#groups + 1] = { key = "cd", title = Tr("DAILY COOLDOWNS"), lists = cdLists }

    -- Crafted pre-BiS per armor type
    local buckets = {
        cloth = NewList("pb_cloth", Tr("Cloth"), "Crafted pre-raid gear (cloth) and its materials."),
        leather = NewList("pb_leather", Tr("Leather"), "Crafted pre-raid gear (leather) and its materials."),
        mail = NewList("pb_mail", Tr("Mail"), "Crafted pre-raid gear (mail) and its materials."),
        plate = NewList("pb_plate", Tr("Plate"), "Crafted pre-raid gear (plate) and its materials."),
        weapon = NewList("pb_weapon", Tr("Weapons & shields"), "Crafted pre-raid weapons, shields and off-hands."),
        other = NewList("pb_other", Tr("Cloaks, trinkets, relics"), "Crafted cloaks, trinkets, relics and engineering items."),
    }
    for id, it in pairs(D.items or {}) do
        if IsGear(id, it) then
            local b = buckets[ArmorBucket(id)]
            local roles = RolesOf(it.sp)
            Add(b, id, "product", roles)
            AddMats(b, id, roles)
            AddRecipe(b, { id = id, roles = roles })
        end
    end
    groups[#groups + 1] = { key = "prebis", title = Tr("PRE-BIS CRAFTS"),
        lists = { buckets.cloth, buckets.leather, buckets.mail, buckets.plate, buckets.weapon, buckets.other } }

    -- Profession leveling 1-300 (quantities)
    local lv = {}
    for _, prof in ipairs({ "alch", "bs", "ench", "eng", "lw", "tail", "cook", "fa" }) do
        local rows = D.level and D.level[prof]
        if rows then
            local pn = Tr(LS.PROF_NAME[prof])
            local l = NewList("lv_" .. prof, pn .. " 1-300", Tr("Shopping list to level %s to 300 (vendor items left out)."):format(pn))
            l.leveling = true
            for _, row in ipairs(rows) do
                Add(l, row[3], "mat", ALL_ROLES, row[2])
                local e = l.byId[row[3]]
                e.range = e.range and (e.range:find(row[1], 1, true) and e.range or (e.range .. ", " .. row[1])) or row[1]
            end
            lv[#lv + 1] = l
        end
    end
    groups[#groups + 1] = { key = "level", title = Tr("PROFESSION LEVELING"), lists = lv }

    -- Custom lists
    local mine = {}
    for i, cl in ipairs(ns.db.lists or {}) do
        local l = NewList("my_" .. i, cl.name, "Your list. Right-click an item in any list to add it here.")
        l.custom = i
        for _, id in ipairs(cl.ids or {}) do Add(l, id, "mat", ALL_ROLES) end
        mine[#mine + 1] = l
    end
    groups[#groups + 1] = { key = "mine", title = Tr("MY LISTS"), lists = mine, custom = true }

    LS.groups = groups
    LS.byKey = {}
    LS.watch = {}
    for _, g in ipairs(groups) do
        for _, l in ipairs(g.lists) do
            LS.byKey[l.key] = l
            for _, e in ipairs(l.entries) do LS.watch[e.id] = true end
        end
    end
    LS.dirty = false
    return groups
end

-- Item present in a list: its price history is kept.
function LS.IsWatched(id)
    if not LS.watch or LS.dirty then LS.Build() end
    return LS.watch[id] or false
end

function LS.Groups()
    if not LS.groups or LS.dirty then LS.Build() end
    return LS.groups
end
function LS.Get(key) LS.Groups(); return LS.byKey[key] end

-- ------------------------------------------------------------ custom lists
function LS.NewCustom(name)
    ns.db.lists = ns.db.lists or {}
    ns.db.lists[#ns.db.lists + 1] = { name = name or ("My list " .. (#ns.db.lists + 1)), ids = {} }
    LS.dirty = true
    return #ns.db.lists
end
function LS.AddToCustom(i, id)
    local cl = ns.db.lists and ns.db.lists[i]
    if not cl then return end
    for _, x in ipairs(cl.ids) do if x == id then return end end
    cl.ids[#cl.ids + 1] = id
    LS.dirty = true
end
function LS.RemoveFromCustom(i, id)
    local cl = ns.db.lists and ns.db.lists[i]
    if not cl then return end
    for k, x in ipairs(cl.ids) do if x == id then table.remove(cl.ids, k); break end end
    LS.dirty = true
end
function LS.DeleteCustom(i)
    if ns.db.lists and ns.db.lists[i] then table.remove(ns.db.lists, i); LS.dirty = true end
end

-- ------------------------------------------------------------ verdicts
-- Buy limit: under the usual low (20 %) AND 15 % under the median.
function LS.BuyMax(st)
    if not st or not st.med or not st.low then return nil end
    return math.min(st.low, math.floor(st.med * 0.85))
end

function LS.Have(id)
    local I = ns.Inventory
    return I and I.Stock and I.Stock(id) or ns.GetItemCount(id)
end

-- "buy" | "sell" | "farm" | nil, plus a short reason.
function LS.Verdict(e, st)
    if not st or not st.med then
        if e.kind == "product" or e.uses >= 2 then return "farm", "never seen at the AH" end
        return nil, "not scanned yet"
    end
    local cur = st.cur
    if not cur or (st.qty or 0) == 0 then return "farm", "none listed right now" end
    local enough = (st.n or 0) >= 4
    local max = LS.BuyMax(st)
    if enough and max and cur <= max then return "buy", "well under its usual price" end
    if enough and st.high and cur >= st.high and cur >= st.med * 1.1 and LS.Have(e.id) > 0 then
        return "sell", "above its usual price and you have some"
    end
    if (st.cv or 0) > 0.35 and enough then return nil, "unstable price" end
    return nil
end

function LS.Row(e)
    local st = P.Stats(e.id)
    local v, why = LS.Verdict(e, st)
    return { e = e, id = e.id, st = st, verdict = v, why = why }
end

function LS.Deals(list)
    local n = 0
    for _, e in ipairs(list.entries) do
        local st = P.Stats(e.id)
        if LS.Verdict(e, st) == "buy" then n = n + 1 end
    end
    return n
end

-- Cost of a recipe (direct materials, usual price otherwise current) and net value of the product.
-- For each intermediate material (one with its own materials below), compare
-- "buy it" and "craft it", and keep the cheaper. Also returns the detail per row.
function LS.RecipeCost(rec, useNow)
    local mats = rec.mats or {}
    local function Price(id)
        -- Vendor supply: its vendor price, never the AH.
        local v = IsVendor(id) and P.VendorBuy(id)
        if v then return v end
        local st = P.Stats(id)
        return st and ((useNow and st.cur) or st.med or st.cur)
    end
    local detail = {}
    -- "crafted" cost of a row: sum of its direct children (each at its best price)
    local function Best(i)
        local m = mats[i]
        local buy = Price(m[1])
        local buyCost = buy and buy * m[2] or nil
        local craft, craftMissing, j = 0, 0, i + 1
        local hasKids = false
        while mats[j] and mats[j][3] > m[3] do
            if mats[j][3] == m[3] + 1 then
                hasKids = true
                local c = Best(j)
                if c then craft = craft + c else craftMissing = craftMissing + 1 end
            end
            j = j + 1
        end
        local d = { buy = buyCost }
        if hasKids and craftMissing == 0 then d.craft = craft end
        if d.craft and (not d.buy or d.craft < d.buy) then d.best = "craft" else d.best = d.buy and "buy" or nil end
        detail[i] = d
        if d.best == "craft" then return d.craft end
        return d.buy
    end
    local cost, missing, allBuy, allBuyMissing = 0, 0, 0, 0
    for i, m in ipairs(mats) do
        if m[3] == 1 then
            local c = Best(i)
            if c then cost = cost + c else missing = missing + 1 end
            local b = detail[i] and detail[i].buy
            if b then allBuy = allBuy + b else allBuyMissing = allBuyMissing + 1 end
        end
    end
    rec._detail = detail
    rec._allBuy = allBuyMissing == 0 and allBuy or nil
    local value
    if rec.id then
        local st = P.Stats(rec.id)
        local v = st and (st.med or st.cur)
        if v then value = math.floor(v * 0.95) end
    end
    return cost, missing, value
end

-- Cost of a profession leveling list: at the current price and at the usual price.
function LS.LevelCost(list)
    local now, usual, missing = 0, 0, 0
    for _, e in ipairs(list.entries) do
        local st = P.Stats(e.id)
        local q = e.qty or 0
        if st and st.cur then now = now + st.cur * q else missing = missing + 1 end
        if st and st.med then usual = usual + st.med * q end
    end
    return now, usual, missing
end

function LS.IdsOf(list)
    local ids = {}
    for _, e in ipairs(list.entries) do if e.kind ~= "tool" then ids[#ids + 1] = e.id end end
    return ids
end

-- ------------------------------------------------------------ Auctionator (read only)
function LS.ExportAuctionator(list)
    local A = Auctionator and Auctionator.API and Auctionator.API.v1
    if not A or not A.CreateShoppingList then return false, "Auctionator not found." end
    local terms = {}
    for _, e in ipairs(list.entries) do
        local name = ns.GetItemInfo(e.id) or ns.db.items[e.id]
        if name then terms[#terms + 1] = '"' .. name .. '"' end
    end
    local ok, err = pcall(A.CreateShoppingList, "ImpotPointGouv", "IPG - " .. list.title, terms)
    if not ok then return false, tostring(err) end
    return true, #terms
end

-- ------------------------------------------------------------ buying deals (stackables)
-- 1st click: reads the live order book and asks the price of the units under the limit; 2nd click: confirms.
local buy
function LS.Buying() return buy end
local function BuyMsg(t) LS.msg, LS.msgT = t, GetTime(); if P.Status then P.Status(t) end; ns.Fire("LISTS_CHANGED") end

local function AHOpen() return AuctionHouseFrame and AuctionHouseFrame:IsShown() end

function LS.Buy(id)
    local AH = C_AuctionHouse
    if not AH or not AHOpen() then BuyMsg(Tr("Open the auction house to buy.")); return end
    if buy and buy.id == id and buy.stage == "confirm" then
        buy.stage = "wait"
        BuyMsg((Tr("Buying %d× %s…")):format(buy.qty, P.Name(id)))
        AH.ConfirmCommoditiesPurchase(id, buy.qty)
        return
    end
    if buy then return end
    if not ns.IsCommodity(id) then BuyMsg(Tr("Only stackable items can be bought from here: use the AH for gear.")); return end
    local st = P.Stats(id)
    local max = LS.BuyMax(st)
    if not max then BuyMsg(Tr("Not enough price history yet: scan this list a few times first.")); return end
    buy = { id = id, max = max, stage = "book" }
    BuyMsg((Tr("Checking live listings of %s under %s…")):format(P.Name(id), ns.FormatMoney(max, { iconSize = 10 })))
    AH.SendSearchQuery(AH.MakeItemKey(id), { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }, false)
    local my = buy
    C_Timer.After(5, function() if buy == my and buy.stage == "book" then buy = nil; BuyMsg(Tr("No answer from the AH, click again.")) end end)
end

local function EndBuy(msg)
    if buy and buy.stage == "confirm" and C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then
        pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    end
    buy = nil
    if msg then BuyMsg(msg) end
end
LS.CancelBuy = function() EndBuy(Tr("Purchase cancelled.")) end

local bev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(bev, "Lists") end
for _, e in ipairs({ "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
    "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_CLOSED" }) do pcall(bev.RegisterEvent, bev, e) end
bev:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "AUCTION_HOUSE_CLOSED" then if buy then EndBuy() end; return end
    if not buy then return end
    local AH = C_AuctionHouse
    if event == "COMMODITY_SEARCH_RESULTS_UPDATED" and buy.stage == "book" and a1 == buy.id then
        local units, cost = 0, 0
        for k = 1, (AH.GetNumCommoditySearchResults(buy.id) or 0) do
            local r = AH.GetCommoditySearchResultInfo(buy.id, k)
            if r and r.unitPrice and r.quantity and r.unitPrice <= buy.max then
                local mine = r.numOwnerItems or 0
                local q = r.quantity - mine
                if q > 0 then units = units + q; cost = cost + q * r.unitPrice end
            end
        end
        -- Budget safeguard: at most 25 % of the character's gold per purchase.
        local budget = math.floor(GetMoney() * 0.25)
        while units > 0 and cost > budget do
            local avg = cost / units
            local cut = math.max(1, math.ceil((cost - budget) / avg))
            units = units - cut; cost = math.floor(avg * units)
        end
        if units <= 0 then EndBuy((Tr("%s: nothing left under %s (or over your budget).")):format(P.Name(buy.id), ns.FormatMoney(buy.max, { iconSize = 10 }))); return end
        buy.qty, buy.stage = units, "price"
        AH.StartCommoditiesPurchase(buy.id, units)
    elseif event == "COMMODITY_PRICE_UPDATED" and buy.stage == "price" then
        local total = a2
        if not total or total / buy.qty > buy.max then
            EndBuy((Tr("%s: the price moved above your limit, nothing bought.")):format(P.Name(buy.id)))
            return
        end
        buy.stage, buy.total = "confirm", total
        BuyMsg((Tr("Buy %d× %s for %s (%s each, limit %s)? Click Confirm.")):format(buy.qty, P.Name(buy.id),
            ns.FormatMoney(total, { iconSize = 10 }), ns.FormatMoney(math.floor(total / buy.qty), { iconSize = 10 }),
            ns.FormatMoney(buy.max, { iconSize = 10 })))
    elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
        EndBuy(Tr("Not available anymore."))
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" and buy.stage == "wait" then
        local msg = (Tr("Bought %d× %s for %s.")):format(buy.qty, P.Name(buy.id), ns.FormatMoney(buy.total or 0, { iconSize = 10 }))
        buy = nil
        BuyMsg(msg)
    elseif event == "COMMODITY_PURCHASE_FAILED" and buy.stage == "wait" then
        EndBuy(Tr("Purchase failed (price changed or not enough gold)."))
    end
end)

-- ------------------------------------------------------------ recharges
local function CDDB()
    ns.db.cds = ns.db.cds or {}
    local key = ns.Ledger and ns.Ledger.CharKey()
    if not key then return nil end
    ns.db.cds[key] = ns.db.cds[key] or {}
    return ns.db.cds[key]
end

-- Updates the logged-in character's cooldown state: { [name] = readyAt }.
function LS.UpdateCooldowns()
    local db = CDDB()
    if not db then return end
    for _, cd in ipairs(Data().cooldowns or {}) do
        local known, start, dur
        if cd.s and IsPlayerSpell and IsPlayerSpell(cd.s) then
            known = true
            local f = (C_Spell and C_Spell.GetSpellCooldown) and function(s)
                local i = C_Spell.GetSpellCooldown(s); return i and i.startTime, i and i.duration end or GetSpellCooldown
            start, dur = f(cd.s)
        elseif cd.item and ns.GetItemCount(cd.item) > 0 then
            known = true
            local f = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
            if f then start, dur = f(cd.item) end
        end
        if known then
            local left = (start and dur and start > 0 and dur > 1.5) and (start + dur - GetTime()) or 0
            db[cd.n] = time() + math.max(0, math.floor(left))
        end
    end
end

-- Estimated gain of a cooldown: AH value of the product (after commission) − materials (usual price).
function LS.CooldownGain(cd)
    local out = P.Stats(cd.out)
    local value = out and (out.med or out.cur)
    if not value then return nil end
    local cost = 0
    for _, rg in ipairs(cd.r or {}) do
        local st = P.Stats(rg[1])
        local p = st and (st.med or st.cur)
        if not p then return nil end
        cost = cost + p * (rg[2] or 1)
    end
    return math.floor(value * 0.95) - cost
end

-- Cooldowns of all characters: { {char, cd, readyAt, gain}, ... } sorted (ready first).
function LS.CooldownBoard()
    local out = {}
    local byName = {}
    for _, cd in ipairs(Data().cooldowns or {}) do byName[cd.n] = cd end
    for key, list in pairs(ns.db.cds or {}) do
        local ch = ns.db.chars[key]
        for name, readyAt in pairs(list) do
            local cd = byName[name]
            if cd then out[#out + 1] = { char = ch and ch.name or "?", cd = cd, readyAt = readyAt, gain = LS.CooldownGain(cd) } end
        end
    end
    table.sort(out, function(a, b)
        local ra, rb = a.readyAt <= time(), b.readyAt <= time()
        if ra ~= rb then return ra end
        return (a.gain or -1e9) > (b.gain or -1e9)
    end)
    return out
end

-- Login reminder: cooldowns ready on this character (the most profitable transmute first).
local function Remind()
    LS.UpdateCooldowns()
    local db = CDDB()
    if not db then return end
    local ready, bestT = {}, nil
    for _, cd in ipairs(Data().cooldowns or {}) do
        local at = db[cd.n]
        if at and at <= time() then
            local g = LS.CooldownGain(cd)
            if cd.n:find("^Transmute") then
                if not bestT or (g or -1e9) > (bestT.g or -1e9) then bestT = { cd = cd, g = g } end
            else
                ready[#ready + 1] = cd.n .. (g and (" (" .. ns.FormatMoney(g, { iconSize = 10, sign = true }) .. ")") or "")
            end
        end
    end
    if bestT then
        table.insert(ready, 1, (Tr("Transmute — best today: %s%s")):format(bestT.cd.n:gsub("^Transmute: ", ""),
            bestT.g and (" (" .. ns.FormatMoney(bestT.g, { iconSize = 10, sign = true }) .. ")") or ""))
    end
    if #ready > 0 then ns.Print(Tr("|cffe0a83dcooldowns ready:|r ") .. table.concat(ready, "  ·  ")) end
end

local ev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(ev, "Lists") end
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "TRADE_SKILL_SHOW", "SPELL_UPDATE_COOLDOWN", "TRADE_SKILL_LIST_UPDATE" }) do
    pcall(ev.RegisterEvent, ev, e)
end
local started, cdPend = false, false
ev:SetScript("OnEvent", function(_, event)
    if not ns.db then return end
    if event == "PLAYER_ENTERING_WORLD" then
        if started then return end
        started = true
        C_Timer.After(6, function()
            LS.ResolveReagents()
            Remind()
        end)
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" then
        -- New known recipes: rebuild the index and retry the missing materials.
        productIndex = nil
        if event == "TRADE_SKILL_SHOW" then LS.RetryReagents() end
        C_Timer.After(1, function() LS.ResolveReagents(); LS.UpdateCooldowns() end)
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        if cdPend then return end
        cdPend = true
        C_Timer.After(2, function() cdPend = false; LS.UpdateCooldowns() end)
    end
end)

-- Diagnostic (/ipg lists): how many recipes the game could detail.
function LS.Diag()
    LS.RetryReagents()
    local found, total = LS.ResolveReagents(true)
    LS.Build()
    local n = 0
    for _, g in ipairs(LS.groups) do for _, l in ipairs(g.lists) do n = n + #l.entries end end
    ns.Print((Tr("lists: recipe materials known for %d / %d recipes · %d items across all lists.")):format(found, total, n))
    -- Forever's own recipe (Living Crown): does the game give its materials?
    local it = Data().items and Data().items[252561]
    local function Fmt(r)
        local parts = {}
        for _, rg in ipairs(r or {}) do parts[#parts + 1] = rg[2] .. "× " .. P.Name(rg[1]) end
        return table.concat(parts, ", ")
    end
    local a = it and FromSchematic(it.s)
    local b = it and FromRecipeTooltip(it.rec)
    ns.Print(Tr("test, Living Crown — recipe data: ") .. (a and Fmt(a) or Tr("not available")))
    ns.Print(Tr("test, Living Crown — pattern tooltip: ") .. (b and Fmt(b) or Tr("not available")))
end

-- Profiling (/ipg perf): heavy functions called outside timed events.
if ns.Profile then
    LS.Build = ns.Profile.Wrap("Lists:Build", LS.Build)
    LS.UpdateCooldowns = ns.Profile.Wrap("Lists:UpdateCooldowns", LS.UpdateCooldowns)
    LS.ResolveReagents = ns.Profile.Wrap("Lists:ResolveReagents", LS.ResolveReagents)
end
