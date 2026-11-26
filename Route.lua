-- ImpotPointGouv: best leveling route for a profession (from the current skill to 300).
-- For each skill point, expected cost of a recipe = (materials − product resale) / skill-up chance.
-- Chance: 100 % in orange, then (grey − skill) / (grey − yellow) in yellow and green, 0 in grey.
-- Access to the recipe, paid once: already known (0), trainer (cost read in game, otherwise estimated),
-- pattern at the AH (current price, if any is listed) or pattern sold by a vendor (≈ 4 × resale price).
-- Dynamic programming over skill, then close alternatives for each step.
-- A learned recipe is paid only once, even if the route comes back to it later.
-- Cooldown recipes (transmutes, mooncloth, salt) are excluded: one craft per cooldown.
local _, ns = ...
local Tr = ns.L
local P = ns.Prices
local RO = {}
ns.Route = RO

RO.AL_PROF = { alch = 4, bs = 2, ench = 10, eng = 9, lw = 3, tail = 8, cook = 6, fa = 1 }
local NAME_KEYS = { alch = "Alchemy", bs = "Blacksmithing", ench = "Enchanting", eng = "Engineering",
    lw = "Leatherworking", tail = "Tailoring", cook = "Cooking", fa = "First Aid" }

local function SpellName(spell)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(spell) end
    if GetSpellInfo then return (GetSpellInfo(spell)) end
end

RO.NAME_KEYS = NAME_KEYS
RO.SpellName = SpellName

-- Known cooldown recipes (Classic), in addition to those of Data.lua (D.cooldowns).
local CD_SPELLS = {
    [11479] = true, [11480] = true,                          -- Transmute: iron to gold, mithril to truesilver
    [17187] = true, [17559] = true, [17560] = true, [17561] = true, [17562] = true,
    [17563] = true, [17565] = true, [17566] = true, [25146] = true, -- other transmutes
    [18560] = true,                                          -- Mooncloth
    [19566] = true,                                          -- Refined Deeprock Salt (Salt Shaker)
}
local cdOut
-- True if the recipe has a cooldown (it cannot be crafted in a row to level).
function RO.IsCooldown(spell, prof, out)
    if CD_SPELLS[spell] then return true end
    if not cdOut then
        cdOut = {}
        for _, cd in ipairs((ns.Data or {}).cooldowns or {}) do
            if cd.s then CD_SPELLS[cd.s] = true end
            if cd.out and cd.p then cdOut[cd.p .. ":" .. cd.out] = true end
        end
        if CD_SPELLS[spell] then return true end
    end
    return out ~= nil and prof ~= nil and cdOut[prof .. ":" .. out] == true
end

-- Recipes of a profession (built once).
local cache = {}
function RO.Recipes(prof)
    if cache[prof] then return cache[prof] end
    local code, out = RO.AL_PROF[prof], {}
    for spell, t in pairs((ns.Data or {}).allRecipes or {}) do
        if t[2] == code then
            local r = { spell = spell, out = t[1] ~= 0 and t[1] or nil, o = t[3], y = t[4], g = t[5],
                n = (t[6] or 1) * ns.YieldBonus(t[1] ~= 0 and t[1] or nil),
                pat = t[7] ~= 0 and t[7] or nil, est = t[8] == 1, mats = {} }
            r.cd = RO.IsCooldown(spell, prof, r.out)
            for i = 9, #t, 2 do r.mats[#r.mats + 1] = { t[i], t[i + 1] or 1 } end
            out[#out + 1] = r
        end
    end
    cache[prof] = out
    return out
end

-- Current skill: the highest among your characters.
function RO.CurrentSkill(prof)
    local best, who = 1, nil
    local want = Tr(NAME_KEYS[prof]):lower()
    local wantEn = NAME_KEYS[prof]:lower()
    for _, c in pairs(ns.db.chars or {}) do
        for _, p in ipairs(c.profs or {}) do
            local n = (p.name or ""):lower()
            if (n == want or n == wantEn) and (p.rank or 0) > best then best, who = p.rank, c.name end
        end
    end
    return math.min(best, 299), who
end

-- Recipes known by one of your characters (names, from the profession windows opened).
local function KnownSet(prof)
    local set = {}
    for profName, recipes in pairs(ns.db.recipes or {}) do
        local pn = profName:lower()
        if pn == NAME_KEYS[prof]:lower() or pn == Tr(NAME_KEYS[prof]):lower() then
            for name in pairs(recipes) do set[name:lower()] = true end
        end
    end
    return set
end
RO.KnownSet = KnownSet

-- Estimated training cost (until the trainer has been visited): grows with the required skill.
local function TrainerEstimate(o)
    return math.max(10, math.floor(o * o * 0.4))
end

-- Access to a recipe: cost, label, estimated?  (nil = not found for now)
function RO.Access(r, known, opts)
    local name = r.name
    if name and known[name:lower()] then return 0, "known" end
    local tr = name and ns.db.trainer and ns.db.trainer[name:lower()]
    if tr then return tr.c or 0, "trainer" end
    if r.pat then
        local st = P.Stats(r.pat)
        local ah = st and st.cur and (st.qty or 0) > 0 and st.cur or nil
        local vend
        if ns.Data.vendorPatterns and ns.Data.vendorPatterns[r.pat] then
            local sp = select(11, ns.GetItemInfo(r.pat))
            if sp and sp > 0 then vend = sp * 4 end
        end
        if vend and (not ah or vend <= ah) then return vend, "vendor" end
        if ah and not opts.noAH then return ah, "ah", st.qty end
        return nil
    end
    if r.spell < 100000 then return TrainerEstimate(r.o), "trainer", nil, true end
    return nil
end

-- Price of a material: AH (usual price, otherwise current) or vendor for supplies.
local function MatPrice(id, memo)
    if memo[id] ~= nil then return memo[id] or nil end
    local p
    if P.IsVendorItem and P.IsVendorItem(id) then p = P.VendorBuy(id) end
    if not p then
        local st = P.Stats(id)
        p = st and (st.med or st.cur)
    end
    memo[id] = p or false
    return p
end

-- Product resale, conservative. Each outlet:
--   vendor: resale price to the vendor (guaranteed, unlimited);
--   AH: price minus the AH's 5 %, only if the market is liquid (≥ 10 listed);
--   disenchant: expected net value of the materials (AH − 5 %).
-- No cap: the cost shown is the real one (a profitable recipe makes the route earn).
-- sell: outlets kept, { ah = true, vendor = true, de = true }; for each recipe, the best of them.
RO.SELL_KEYS = { "ah", "vendor", "de" }
-- Saved setting -> set of outlets (old format: "ah" / "vendor" / "de" / "mix").
function RO.SellSet(v)
    if type(v) == "table" and (v.ah or v.vendor or v.de) then return v end
    if v == "ah" or v == "vendor" or v == "de" then return { [v] = true } end
    return { ah = true, vendor = true, de = true }
end
local function Resale(r, sell)
    if not r.out then return 0 end
    local vals = {}
    if sell.vendor then
        vals.vendor = (P.VendorSell(r.out) or 0) * r.n
    end
    if sell.ah then
        local st = P.Stats(r.out)
        local ah = st and (st.med or st.cur)
        vals.ah = (ah and (st.qty or 0) >= 10) and math.floor(ah * 0.95) * r.n or 0
    end
    if sell.de then
        local de = P.DisenchantValue and P.DisenchantValue(r.out)
        vals.de = de and math.floor(de) * r.n or 0
    end
    local best, how = 0, nil
    for _, k in ipairs(RO.SELL_KEYS) do
        if (vals[k] or 0) > best then best, how = vals[k], k end
    end
    return best, how
end

-- Cost of a craft for choosing the route (not the one shown): a profitable craft counts as 0,
-- otherwise the route would craft on purpose where the skill-up chance is low, to sell more.
-- + the time of a craft (2 s): one more craft is not worth saving less than 2 s, the route stays fast.
-- Then, barely less, the one that earns the most (bonus < 0.5 copper: never beats one craft fewer).
RO.CRAFT_TIME = 200
local function PlanCost(c)
    local t = RO.CRAFT_TIME
    if c >= 0 then return c + t end
    local p = -c
    return t - 0.5 * p / (p + 100000)
end

local function Chance(r, s)
    if s < r.o or s >= r.g then return 0 end
    if s < r.y then return 1 end
    return (r.g - s) / math.max(1, r.g - r.y)
end

-- Route cache: recomputed when prices, characters, choices or settings change,
-- at the latest every 10 min (learned recipes, trainer). Switching lists no longer recomputes.
local routeCache, routeVer = {}, 0
function RO.Invalidate() routeVer = routeVer + 1 end
function RO.ResetRecipes() cache = {}; RO.Invalidate() end
for _, ev in ipairs({ "PRICES_CHANGED", "CHARS_CHANGED", "LISTS_CHANGED", "INVENTORY_CHANGED" }) do ns.On(ev, RO.Invalidate) end

-- Computes the route. opts: { noAH = bool, from = skill, sell = { ah = bool, vendor = bool, de = bool } }
local Compute
function RO.Compute(prof, opts)
    opts = opts or {}
    local sell = RO.SellSet(opts.sell)
    local key = table.concat({ prof, tostring(opts.noAH and true or false), tostring(opts.from or RO.CurrentSkill(prof)),
        sell.ah and "a" or "", sell.vendor and "v" or "", sell.de and "d" or "" }, ":")
    local c = routeCache[key]
    if c and c.ver == routeVer and time() - c.at < 600 then return c.res end
    local res = ns.Profile and ns.Profile.Time("Route:Compute " .. prof, Compute, prof, opts) or Compute(prof, opts)
    routeCache[key] = { ver = routeVer, at = time(), res = res }
    return res
end
Compute = function(prof, opts)
    local sell = RO.SellSet(opts.sell)
    local recipes = RO.Recipes(prof)
    local known = KnownSet(prof)
    local bans = (ns.db.settings.routeBan or {})[prof] or {}
    local memo = {}
    local start, who = RO.CurrentSkill(prof)
    if opts.from then start = opts.from end
    local cands, skipped, cdSkipped = {}, 0, 0
    for _, r in ipairs(recipes) do
        r.name = r.name or SpellName(r.spell)
        if r.g > start and r.cd then
            cdSkipped = cdSkipped + 1
        elseif r.g > start and not bans[r.spell] then
            local F, label, qty, est = RO.Access(r, known, opts)
            local cost, missing = 0, false
            for _, m in ipairs(r.mats) do
                local p = MatPrice(m[1], memo)
                if p then cost = cost + p * m[2] else missing = true; break end
            end
            if F and not missing then
                r.F, r.label, r.qtyListed, r.estF = F, label, qty, est
                r.matCost = cost
                r.resale, r.sellHow = Resale(r, sell)
                r.c = cost - r.resale
                r.k = PlanCost(r.c)
                cands[#cands + 1] = r
            else
                skipped = skipped + 1
            end
        end
    end
    -- User's choice (clicked alternative): only this recipe on that range.
    local pinAt = {}
    local pins = (ns.db.settings.routePin or {})[prof]
    if pins then
        local bySpell = {}
        for _, r in ipairs(cands) do bySpell[r.spell] = r end
        for _, p in ipairs(pins) do
            local r = bySpell[p.spell]
            if r then
                for x = math.max(start, p.from), math.min(299, p.to - 1) do
                    if Chance(r, x) > 0 then pinAt[x] = r end
                end
            end
        end
    end
    local INF = math.huge
    -- Dynamic programming: best[x] = minimal cost to reach x, in contiguous steps.
    -- owned: recipes already paid for (free learning in this pass).
    local function Solve(owned)
        local best, arg = { [start] = 0 }, {}
        local M, Ms, PS = {}, {}, {}
        for _, r in ipairs(cands) do M[r], PS[r] = INF, 0 end
        for x = start, 299 do
            local bx = best[x] or INF
            local bestNext, br, bs = INF, nil, nil
            local pin = pinAt[x]
            for _, r in ipairs(cands) do
                local ch = (pin and r ~= pin) and 0 or Chance(r, x)
                if ch > 0 then
                    -- start (or restart) a segment with r at x
                    local cand = bx + (owned[r] and 0 or r.F) - PS[r]
                    if cand < M[r] then M[r], Ms[r] = cand, x end
                    PS[r] = PS[r] + r.k / ch
                    local v = M[r] + PS[r]
                    if v < bestNext then bestNext, br, bs = v, r, Ms[r] end
                else
                    M[r] = INF
                end
            end
            best[x + 1] = bestNext
            arg[x + 1] = { br, bs }
        end
        -- Rebuilding the steps (two steps in a row with the same recipe: merged).
        local segs = {}
        local t = 300
        while t > start and arg[t] and arg[t][1] do
            local r, s = arg[t][1], arg[t][2]
            if segs[1] and segs[1].r == r and segs[1].from == t then segs[1].from = s
            else table.insert(segs, 1, { from = s, to = t, r = r }) end
            t = s
        end
        return segs, (best[300] or INF) < INF
    end
    -- Real cost (shown), number of crafts and cost used to choose the route (PlanCost).
    local function SegCost(r, a, b, free)
        local total, crafts, plan = free and 0 or r.F, 0, free and 0 or r.F
        for x = a, b - 1 do
            local ch = Chance(r, x)
            if ch <= 0 then return nil end
            total = total + r.c / ch
            plan = plan + r.k / ch
            crafts = crafts + 1 / ch
        end
        return total, crafts, plan
    end
    -- Cost of a route: each recipe paid only once (at its first step).
    local function Price(segs)
        local paid, total, plan = {}, 0, 0
        for _, sg in ipairs(segs) do
            sg.reuse = paid[sg.r] or nil
            sg.cost, sg.crafts, sg.plan = SegCost(sg.r, sg.from, sg.to, sg.reuse)
            paid[sg.r] = true
            total = total + (sg.cost or 0)
            plan = plan + (sg.plan or 0)
        end
        return total, paid, plan
    end
    -- Pass 1 with nothing paid; then the route is redone treating the recipes already
    -- chosen as owned (their learning price counts once), as long as the route gets cheaper.
    local segs, reached = Solve({})
    local total, paid, plan = Price(segs)
    for _ = 1, 4 do
        if not reached then break end
        local s2, ok2 = Solve(paid)
        if not ok2 then break end
        local t2, p2, pl2 = Price(s2)
        if pl2 >= plan - 1 then break end
        segs, total, paid, plan = s2, t2, p2, pl2
    end
    Price(segs) -- restores sg.cost / sg.reuse of the route kept
    local maxPct = (ns.db.settings.routeAltPct or 30) / 100
    local maxAbs = (ns.db.settings.routeAltGold or 5) * 10000
    for _, sg in ipairs(segs) do
        local alts = {}
        for _, r in ipairs(cands) do
            if r ~= sg.r then
                local c, cr, pl = SegCost(r, sg.from, sg.to, paid[r])
                if c and sg.plan and (pl - sg.plan <= math.max(math.abs(sg.plan) * maxPct, maxAbs)) then
                    alts[#alts + 1] = { r = r, cost = c, crafts = cr, plan = pl, reuse = paid[r] or nil }
                end
            end
        end
        table.sort(alts, function(a, b) return a.plan < b.plan end)
        for k = #alts, 4, -1 do alts[k] = nil end
        sg.alts = alts
    end
    return { segs = segs, total = total, start = start, who = who, skipped = skipped, cdSkipped = cdSkipped,
        reached = reached }
end

function RO.Ban(prof, spell)
    ns.db.settings.routeBan = ns.db.settings.routeBan or {}
    ns.db.settings.routeBan[prof] = ns.db.settings.routeBan[prof] or {}
    ns.db.settings.routeBan[prof][spell] = true
    RO.Invalidate()
end
-- Picked alternative: this recipe from `from` to `to` (replaces overlapping picks).
function RO.Pin(prof, spell, from, to)
    local s = ns.db.settings
    s.routePin = s.routePin or {}
    local list = s.routePin[prof] or {}
    for i = #list, 1, -1 do
        if list[i].from < to and list[i].to > from then table.remove(list, i) end
    end
    list[#list + 1] = { spell = spell, from = from, to = to }
    s.routePin[prof] = list
    RO.Invalidate()
end
function RO.ResetBans(prof)
    if ns.db.settings.routeBan then ns.db.settings.routeBan[prof] = nil end
    if ns.db.settings.routePin then ns.db.settings.routePin[prof] = nil end
    RO.Invalidate()
end
function RO.HasBans(prof)
    local b = ns.db.settings.routeBan and ns.db.settings.routeBan[prof]
    local p = ns.db.settings.routePin and ns.db.settings.routePin[prof]
    return (b and next(b) ~= nil) or (p and #p > 0) or false
end

-- ------------------------------------------------------------ training costs (read at the trainer)
local function ReadTrainer()
    if not GetNumTrainerServices or not GetTrainerServiceInfo then return end
    ns.db.trainer = ns.db.trainer or {}
    for i = 1, GetNumTrainerServices() do
        local name, _, category = GetTrainerServiceInfo(i)
        if name and category ~= "header" then
            local cost = GetTrainerServiceCost and GetTrainerServiceCost(i) or 0
            ns.db.trainer[name:lower()] = { c = cost, t = time() }
        end
    end
    RO.Invalidate()
end
local ev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(ev, "Route") end
for _, e in ipairs({ "TRAINER_SHOW", "TRAINER_UPDATE" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function() if ns.db then C_Timer.After(0.3, ReadTrainer) end end)
