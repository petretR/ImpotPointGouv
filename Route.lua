-- ImpotPointGouv : meilleure route de montée d'un métier (de la compétence actuelle à 300).
-- Pour chaque point de compétence, coût attendu d'une recette = (composants − revente du produit) / chance de monter.
-- Chance : 100 % en orange, puis (gris − compétence) / (gris − jaune) en jaune et en vert, 0 en gris.
-- Accès à la recette, payé une fois : déjà connue (0), formateur (coût relevé en jeu, sinon estimé),
-- patron à l'HV (prix actuel, s'il y en a en vente) ou patron vendu par un marchand (≈ 4 × prix de revente).
-- Programmation dynamique sur la compétence, puis alternatives proches pour chaque tranche.
-- Une recette apprise n'est payée qu'une fois, même si la route y revient plus tard.
-- Les recettes à recharge (transmutations, étoffe lunaire, sel) sont exclues : un craft par recharge.
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

-- Recettes à recharge connues (Classic), en plus de celles de Data.lua (D.cooldowns).
local CD_SPELLS = {
    [11479] = true, [11480] = true,                          -- Transmutation : fer en or, mithril en vrai-argent
    [17187] = true, [17559] = true, [17560] = true, [17561] = true, [17562] = true,
    [17563] = true, [17565] = true, [17566] = true, [25146] = true, -- autres transmutations
    [18560] = true,                                          -- Étoffe lunaire
    [19566] = true,                                          -- Sel de rochebrune raffiné (salière)
}
local cdOut
-- Vrai si la recette a une recharge (on ne peut pas la crafter en série pour monter).
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

-- Recettes d'un métier (construites une fois).
local cache = {}
function RO.Recipes(prof)
    if cache[prof] then return cache[prof] end
    local code, out = RO.AL_PROF[prof], {}
    for spell, t in pairs((ns.Data or {}).allRecipes or {}) do
        if t[2] == code then
            local r = { spell = spell, out = t[1] ~= 0 and t[1] or nil, o = t[3], y = t[4], g = t[5], n = t[6] or 1,
                pat = t[7] ~= 0 and t[7] or nil, est = t[8] == 1, mats = {} }
            r.cd = RO.IsCooldown(spell, prof, r.out)
            for i = 9, #t, 2 do r.mats[#r.mats + 1] = { t[i], t[i + 1] or 1 } end
            out[#out + 1] = r
        end
    end
    cache[prof] = out
    return out
end

-- Compétence actuelle : la plus haute parmi vos personnages.
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

-- Recettes connues par un de vos personnages (noms, d'après les fenêtres de métier ouvertes).
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

-- Coût de formation estimé (tant que le formateur n'a pas été visité) : grandit avec la compétence requise.
local function TrainerEstimate(o)
    return math.max(10, math.floor(o * o * 0.4))
end

-- Accès à une recette : coût, libellé, estimé ?  (nil = introuvable pour l'instant)
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

-- Prix d'un composant : HV (prix habituel, sinon actuel) ou marchand pour les fournitures.
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

-- Revente du produit, prudente : le prix marchand (garanti, sans limite), ou une part de la valeur HV
-- (60 % du prix net, seulement si le marché est liquide) plafonnée à 90 % du coût des composants.
-- On ne revend pas 80 objets au prix du marché : la route cherche à monter pas cher, pas à crafter pour vendre.
local function Resale(r, matCost)
    if not r.out then return 0 end
    local vs = (select(11, ns.GetItemInfo(r.out)) or (ns.db.vsell and ns.db.vsell[r.out]) or 0) * r.n
    local st = P.Stats(r.out)
    local ah = st and (st.med or st.cur)
    local ahPart = (ah and (st.qty or 0) >= 10) and math.floor(ah * 0.95 * 0.6) * r.n or 0
    return math.max(vs, math.min(ahPart, math.floor(matCost * 0.9)))
end

local function Chance(r, s)
    if s < r.o or s >= r.g then return 0 end
    if s < r.y then return 1 end
    return (r.g - s) / math.max(1, r.g - r.y)
end

-- Calcule la route. opts : { noAH = bool, from = skill }
function RO.Compute(prof, opts)
    opts = opts or {}
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
                r.matCost, r.resale = cost, Resale(r, cost)
                r.c = cost - r.resale
                cands[#cands + 1] = r
            else
                skipped = skipped + 1
            end
        end
    end
    local INF = math.huge
    -- Programmation dynamique : best[x] = coût minimal pour atteindre x, en tranches contiguës.
    -- owned : recettes déjà payées (apprentissage gratuit dans cette passe).
    local function Solve(owned)
        local best, arg = { [start] = 0 }, {}
        local M, Ms, PS = {}, {}, {}
        for _, r in ipairs(cands) do M[r], PS[r] = INF, 0 end
        for x = start, 299 do
            local bx = best[x] or INF
            local bestNext, br, bs = INF, nil, nil
            for _, r in ipairs(cands) do
                local ch = Chance(r, x)
                if ch > 0 then
                    -- démarrer (ou redémarrer) un segment avec r en x
                    local cand = bx + (owned[r] and 0 or r.F) - PS[r]
                    if cand < M[r] then M[r], Ms[r] = cand, x end
                    PS[r] = PS[r] + r.c / ch
                    local v = M[r] + PS[r]
                    if v < bestNext then bestNext, br, bs = v, r, Ms[r] end
                else
                    M[r] = INF
                end
            end
            best[x + 1] = bestNext
            arg[x + 1] = { br, bs }
        end
        -- Reconstruction des tranches (deux tranches de suite avec la même recette : fusionnées).
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
    local function SegCost(r, a, b, free)
        local total, crafts = free and 0 or r.F, 0
        for x = a, b - 1 do
            local ch = Chance(r, x)
            if ch <= 0 then return nil end
            total = total + r.c / ch
            crafts = crafts + 1 / ch
        end
        return total, crafts
    end
    -- Coût réel d'une route : chaque recette payée une seule fois (à sa première tranche).
    local function Price(segs)
        local paid, total = {}, 0
        for _, sg in ipairs(segs) do
            sg.reuse = paid[sg.r] or nil
            sg.cost, sg.crafts = SegCost(sg.r, sg.from, sg.to, sg.reuse)
            paid[sg.r] = true
            total = total + (sg.cost or 0)
        end
        return total, paid
    end
    -- Passe 1 sans rien de payé ; puis on refait la route en considérant acquises les recettes déjà
    -- choisies (le prix de leur apprentissage compte une fois), tant que la route réelle baisse.
    local segs, reached = Solve({})
    local total, paid = Price(segs)
    for _ = 1, 4 do
        if not reached then break end
        local s2, ok2 = Solve(paid)
        if not ok2 then break end
        local t2, p2 = Price(s2)
        if t2 >= total - 1 then break end
        segs, total, paid = s2, t2, p2
    end
    Price(segs) -- remet sg.cost / sg.reuse de la route retenue
    local maxPct = (ns.db.settings.routeAltPct or 30) / 100
    local maxAbs = (ns.db.settings.routeAltGold or 5) * 10000
    for _, sg in ipairs(segs) do
        local alts = {}
        for _, r in ipairs(cands) do
            if r ~= sg.r then
                local c, cr = SegCost(r, sg.from, sg.to, paid[r])
                if c and sg.cost and (c - sg.cost <= math.max(math.abs(sg.cost) * maxPct, maxAbs)) then
                    alts[#alts + 1] = { r = r, cost = c, crafts = cr, reuse = paid[r] or nil }
                end
            end
        end
        table.sort(alts, function(a, b) return a.cost < b.cost end)
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
end
function RO.ResetBans(prof)
    if ns.db.settings.routeBan then ns.db.settings.routeBan[prof] = nil end
end
function RO.HasBans(prof)
    local b = ns.db.settings.routeBan and ns.db.settings.routeBan[prof]
    return b and next(b) ~= nil
end

-- ------------------------------------------------------------ prix des formations (relevés chez le formateur)
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
end
local ev = CreateFrame("Frame")
for _, e in ipairs({ "TRAINER_SHOW", "TRAINER_UPDATE" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function() if ns.db then C_Timer.After(0.3, ReadTrainer) end end)
