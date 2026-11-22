-- ImpotPointGouv : file de craft, liste de courses, achats (marchand / HV) et "Craft next".
--
-- File : ns.db.queue[clé] = { prof, name, n, auto }  (clé = métier .. "\001" .. recette)
--   auto = ajouté par "Queue profitable" (remplacé à chaque nouveau calcul), sinon ajout manuel.
-- Plan : la file + les crafts intermédiaires nécessaires (ex. Cured Light Hide) quand les fabriquer
--   coûte moins cher que les acheter, puis la liste de courses (besoin − sacs/banque − alts).
local _, ns = ...
local Tr = ns.L
local T, P, CR, I = ns.Theme, ns.Prices, ns.Craft, ns.Inventory
local C = T.C
local Q = {}
ns.Queue = Q

local SEP = "\001"
local function Me() return UnitGUID("player") end
-- Une file par personnage : la clé contient le propriétaire.
local function Key(prof, name, owner) return (prof or "?") .. SEP .. name .. SEP .. (owner or Me() or "?") end
local function DB()
    ns.db.queue = ns.db.queue or {}
    local db = ns.db.queue
    if not ns.db.queueV2 then
        -- Ancien format (une file commune) : on rattache chaque entrée à son propriétaire.
        local moved = {}
        for k, e in pairs(db) do
            local _, n = k:gsub(SEP, "")
            if n < 2 then moved[k] = e end
        end
        for k, e in pairs(moved) do
            db[k] = nil
            db[Key(e.prof, e.name, e.owner)] = e
        end
        ns.db.queueV2 = true
    end
    return db
end

-- Matériau d'artisanat (rouleaux, cuir traité…) : sert à d'autres recettes, jamais mis en file pour être vendu.
function Q.IsMaterial(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not id or not f then return false end
    local ok, _, _, _, _, _, classID = pcall(f, id)
    return ok and classID == 7
end

-- ------------------------------------------------------------ crafteurs (plusieurs possibles)
local function CrafterSet()
    local st = ns.db.settings
    if not st.crafters then
        st.crafters = {}
        if st.crafterChar then st.crafters[st.crafterChar] = true end
        for _, e in pairs(ns.db.queue or {}) do if e.owner then st.crafters[e.owner] = true end end
    end
    return st.crafters
end
function Q.IsCrafter(key) return key ~= nil and CrafterSet()[key] == true end
function Q.SetCrafter(key, on) CrafterSet()[key] = on or nil; Q.Refresh() end
function Q.Crafters()
    local list = {}
    for k in pairs(CrafterSet()) do if ns.db.chars[k] then list[#list + 1] = k end end
    table.sort(list, function(a, b) return (ns.db.chars[a].name or "") < (ns.db.chars[b].name or "") end)
    return list
end
-- Le personnage dont c'est la file : soi-même si on a une file, sinon "*" sur la banque (tous les crafteurs).
function Q.Owner()
    local me = Me()
    for _, e in pairs(DB()) do if e.owner == me then return me end end
    if Q.IsCrafter(me) then return me end
    if ns.db.settings.bankChar == me then return "*" end
    return me
end

-- ------------------------------------------------------------ recettes
local function LiveRec(prof, name)
    if prof ~= CR.ProfName() then return nil end
    for _, r in ipairs(CR.GetRecipes()) do if r.name == name then return r end end
end

local function RecFrom(prof, name)
    local live = LiveRec(prof, name)
    if live then return live end
    local r = ns.db.recipes[prof] and ns.db.recipes[prof][name]
    if not r then return nil end
    local rec = { name = name, pid = r.p, made = r.m or 1, reagents = {}, enchant = r.p == nil,
        icon = r.p and ns.GetItemIcon(r.p) }
    for _, rg in ipairs(r.r or {}) do
        rec.reagents[#rec.reagents + 1] = { id = rg[1], n = rg[2], name = P.Name(rg[1]),
            icon = ns.GetItemIcon(rg[1]), have = ns.GetItemCount(rg[1]) }
    end
    return rec
end

-- ------------------------------------------------------------ gestion de la file
function Q.Add(prof, name, n)
    if not prof or not name then return end
    local db = DB()
    local k = Key(prof, name)
    local e = db[k] or { prof = prof, name = name, n = 0 }
    e.n = math.max(0, e.n + (n or 1))
    e.auto = nil
    e.owner = UnitGUID("player")
    db[k] = e.n > 0 and e or nil
    ns.Print((Tr("queue: %s ×%d")):format(name, e.n))
    Q.Refresh()
end

function Q.Clear()
    local owner = Q.Owner()
    local db = DB()
    for k, e in pairs(db) do if owner == "*" or e.owner == owner then db[k] = nil end end
    Q.Refresh()
end

local function Clamp(v, a, b) return math.max(a, math.min(b, v)) end

-- Métiers connus par le personnage connecté (enregistrés à l'ouverture de chaque métier).
function Q.MyProfessions()
    local me, list = UnitGUID("player"), {}
    for prof, chars in pairs(ns.db.profChars or {}) do
        if chars[me] and ns.db.recipes[prof] then list[#list + 1] = prof end
    end
    table.sort(list)
    return list
end

local RecipesOf
function Q.FindRecipe(prof, name)
    for _, rec in ipairs(RecipesOf(prof)) do if rec.name == name then return rec end end
end

function RecipesOf(prof)
    if prof == CR.ProfName() and #CR.GetRecipes() > 0 then return CR.GetRecipes() end
    local list = {}
    for name in pairs(ns.db.recipes[prof] or {}) do
        local rec = RecFrom(prof, name)
        if rec then list[#list + 1] = rec end
    end
    return list
end

-- Remplit la file avec les recettes rentables, en visant un stock cible.
-- allProfs = true : tous les métiers du personnage (sinon seulement le métier ouvert).
-- ------------------------------------------------------------ cible adaptative (demande)
-- Chaque objet a sa propre cible de stock, ajustée d'une session à l'autre selon la façon dont
-- partent les mises en vente postées depuis le dernier ajustement :
--   tout vendu et vite (≤ 1 h)  → ×2      tout vendu      → ×1.5
--   ≥ 70 % vendu                → ×1.25   plus d'invendus que de ventes → ×0.6
-- On n'ajuste que quand le cycle est résolu (plus rien en vente) ou épuisé.
local FAST = 3600

local function AdaptDB() ns.db.settings.adapt = ns.db.settings.adapt or {}; return ns.db.settings.adapt end

-- Rejoue l'historique (FIFO) : pour chaque unité postée après `since`, vendue (et en combien de temps), expirée, ou encore en vente.
local function Cycle(name, since)
    local units, open = {}, {}
    local from = math.min(since, time() - 14 * 86400)
    for _, tx in ipairs(ns.db.tx) do
        if tx.t >= from and tx.i == name then
            if tx.k == "ah_deposit" then
                for _ = 1, (tx.q or 1) do local u = { t = tx.t }; units[#units + 1] = u; open[#open + 1] = u end
            elseif tx.k == "ah_sale" then
                local q = (tx.q and tx.q > 0) and tx.q or 1
                for _ = 1, q do local u = table.remove(open, 1); if u then u.sold = (tx.st or tx.t) end end
            elseif tx.k == "ah_expired" or tx.k == "ah_cancelled" then
                for _ = 1, (tx.q or 1) do local u = table.remove(open, 1); if u then u.expired = true end end
            end
        end
    end
    local c = { posted = 0, sold = 0, expired = 0, pending = 0, waits = {} }
    for _, u in ipairs(units) do
        if u.t > since then
            c.posted = c.posted + 1
            if u.sold then c.sold = c.sold + 1; c.waits[#c.waits + 1] = math.max(0, u.sold - u.t)
            elseif u.expired then c.expired = c.expired + 1
            else c.pending = c.pending + 1 end
        end
    end
    table.sort(c.waits)
    c.median = #c.waits > 0 and c.waits[math.ceil(#c.waits / 2)] or nil
    return c
end
Q.Cycle = Cycle

local function Ago(sec)
    if sec < 90 then return sec .. " s" elseif sec < 5400 then return math.floor(sec / 60 + 0.5) .. Tr(" min") end
    return math.floor(sec / 3600 + 0.5) .. " h"
end

-- Cible de stock à vendre pour une recette ; `commit` enregistre l'ajustement (Queue profitable).
-- ------------------------------------------------------------ profondeur : combien crafter tant que c'est rentable
-- Décompose une recette en achats bruts (intermédiaires crafter si c'est moins cher), puis "achète" les composants
-- palier par palier dans l'HV scannée, craft après craft, jusqu'à ce que le craft suivant ne soit plus rentable.
local function Expand(id, qty, depth, raw, acc)
    if P.IsVendorItem(id) then
        local vb = P.VendorBuy(id)
        if vb then acc.fixed = acc.fixed + vb * qty; return end
    end
    local prod = depth < 3 and CR.ProducerOf(id)
    if prod then
        local _, src = CR.UnitCost(id)
        if src == "craft" then
            for _, rg in ipairs(prod.r or {}) do Expand(rg[1], rg[2] * qty / math.max(1, prod.m or 1), depth + 1, raw, acc) end
            return
        end
    end
    raw[id] = (raw[id] or 0) + qty
end

function Q.Depth(rec, value, rules, cap)
    if not (ns.Market and ns.Market.Book) or not value then return nil end
    local raw, acc = {}, { fixed = 0 }
    for _, rg in ipairs(rec.reagents or {}) do
        if rg.id then Expand(rg.id, rg.n or 1, 0, raw, acc) end
    end
    -- Échelle de prix de chaque composant brut, avec votre stock en tête (au prix le plus bas).
    local ladders, age = {}, 0
    for id, q in pairs(raw) do
        local book, a = ns.Market.Book(id)
        if not book then return nil end
        age = math.max(age, a or 0)
        local L = {}
        local stock = I.Mine(id) + (I.Alts(id))
        if stock > 0 then L[1] = { book[1] and book[1][1] or (P.AHValue(id) or 0), stock, own = true } end
        for _, b in ipairs(book) do L[#L + 1] = { b[1], b[2] } end
        ladders[id] = { L = L, i = 1, left = L[1] and L[1][2] or 0, q = q, max = nil, stock = stock }
    end
    local n = 0
    while n < cap do
        local cost, ok = acc.fixed, true
        local snap = {}
        for id, ld in pairs(ladders) do
            snap[id] = { ld.i, ld.left, ld.max }
            local need = ld.q
            while need > 1e-9 do
                local step = ld.L[ld.i]
                if not step then ok = false; break end
                local take = math.min(need, ld.left)
                cost = cost + take * step[1]
                if not step.own then ld.max = step[1] end
                need = need - take
                ld.left = ld.left - take
                if ld.left <= 1e-9 then ld.i = ld.i + 1; ld.left = ld.L[ld.i] and ld.L[ld.i][2] or 0 end
            end
            if not ok then break end
        end
        local profit = value - cost
        if not ok or profit < rules.minProfit or (cost > 0 and profit / cost * 100 < rules.minMargin) then
            for id, sp in pairs(snap) do ladders[id].i, ladders[id].left, ladders[id].max = sp[1], sp[2], sp[3] end
            break
        end
        n = n + 1
    end
    local out = { n = n, max = {}, buy = {}, even = {}, age = age, t = time() }
    for id, ld in pairs(ladders) do
        out.max[id] = ld.max
        out.buy[id] = math.max(0, math.ceil(n * ld.q - ld.stock))
    end
    -- Seuil de rentabilité de chaque composant : prix au-delà duquel le craft perd de l'argent
    -- (les autres composants à leur prix actuel le plus bas).
    for id, ld in pairs(ladders) do
        local others = acc.fixed
        for oid, old in pairs(ladders) do
            if oid ~= id then
                local first = old.L[1] and old.L[1][1] or 0
                others = others + (old.max or first) * old.q
            end
        end
        out.even[id] = math.floor((value - others) / ld.q)
    end
    return out
end

-- Équipement (non empilable, BoE…) : on teste à l'unité et on monte de 1 en 1.
local function IsSingle(id)
    local _, _, _, _, _, _, _, stack, equipLoc = ns.GetItemInfo(id)
    if stack == 1 then return true end
    return equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_BAG" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" or false
end
Q.IsSingle = IsSingle

-- Cible de stock à vendre pour une recette ; `commit` enregistre l'ajustement (Queue profitable).
-- Progression : départ 2 (1 pour l'équipement), +2 (+1) quand ça part bien, ×2 quand tout part en moins d'1 h.
function Q.Target(rec, ev, rules, commit)
    local single = IsSingle(rec.pid)
    local step = single and 1 or 2
    local lo = single and 1 or rules.minQty
    local start = single and 1 or rules.startQty
    local A = AdaptDB()
    local st = A[rec.pid]
    if not st then
        local t = (ev.sold7 or 0) > 0 and Clamp(ev.sold7, lo, rules.maxQty) or start
        st = { t = t, at = 0 }
        if commit then A[rec.pid] = st end
    end
    local name = ns.db.items[rec.pid] or rec.name
    local c = Cycle(name, st.at)
    -- Pour le marchand, la demande est illimitée : on vise le plafond "vendor" (le budget tranche ensuite).
    if ev.channel == "vendor" then
        local cap = rules.vendorCap or 40
        local made = math.max(1, rec.made or 1)
        local d = Q.Depth(rec, (P.VendorSell(rec.pid) or 0) * made, rules, cap)
        ns.db.depth = ns.db.depth or {}
        if d then
            ns.db.depth[rec.pid] = d
            return d.n * made + I.Stock(rec.pid), nil
        end
        ns.db.depth[rec.pid] = nil
        return cap, nil
    end
    -- Désenchanté et jamais posté : pas de demande HV à suivre.
    if ev.channel == "de" and c.posted == 0 and (ev.posts14 or 0) == 0 then
        return start, nil
    end
    local t, why = st.t, nil
    if c.posted > 0 then
        local soldOut = c.sold == c.posted
        if soldOut and c.median and c.median <= FAST then
            t = math.max(t + step, t * 2); why = (Tr("sold out, %d in ~%s")):format(c.sold, Ago(c.median))
        elseif soldOut or (c.pending == 0 and c.sold >= 0.7 * c.posted) then
            t = t + step; why = soldOut and (Tr("sold out, %d in ~%s")):format(c.sold, Ago(c.median or 0))
                or (Tr("sold %d/%d")):format(c.sold, c.posted)
        elseif c.pending == 0 and c.expired > c.sold then
            t = math.max(lo, t - step); why = (Tr("only %d/%d sold")):format(c.sold, c.posted)
        elseif c.pending == 0 then
            why = (Tr("sold %d/%d, holding")):format(c.sold, c.posted)
        end
    end
    t = Clamp(t, lo, rules.maxQty)
    if commit and why then
        if t ~= st.t then st.why = ("%d → %d · %s"):format(st.t, t, why) else st.why = ("%d · %s"):format(t, why) end
        st.t, st.at = t, time()
    end
    return t, st.why
end

-- Or total : tous vos persos (dernier montant connu) + banque de bataillon.
function Q.TotalGold()
    local total = ns.Ledger and ns.Ledger.TotalMoney and ns.Ledger.TotalMoney() or (GetMoney and GetMoney() or 0)
    if C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType and Enum.BankType.Account then
        local ok, m = pcall(C_Bank.FetchDepositedMoney, Enum.BankType.Account)
        if ok and type(m) == "number" then total = total + m end
    end
    return total
end

function Q.RichestAlt()
    local me, best, bestM = ns.Ledger and ns.Ledger.CharKey and ns.Ledger.CharKey(), nil, 0
    for key, c in pairs(ns.db.chars) do
        if key ~= me and (c.money or 0) > bestM then best, bestM = key, c.money end
    end
    return best and best:match("^[^%-]+") or nil
end

function Q.AutoQueue(allProfs)
    local rules = CR.Rules()
    local profs = allProfs and Q.MyProfessions() or { CR.ProfName() }
    local me = UnitGUID("player")
    local db = DB()
    local added, skipped, pending = 0, 0, 0
    local cands = {}
    for _, prof in ipairs(profs) do
        for k, e in pairs(db) do if e.auto and e.prof == prof and e.owner == me then db[k] = nil end end
        for _, rec in ipairs(RecipesOf(prof)) do
            local ev = CR.GetEval(rec)
            if ev.infoPending then pending = pending + 1 end
            local keepN = ns.Keep and rec.pid and ns.Keep.Get(rec.pid) or 0
            local profitable = not rec.enchant and ev.profit and not ev.unsold and not ev.whiteGear and not ev.infoPending
                and ev.profit >= rules.minProfit and (ev.margin or 0) * 100 >= rules.minMargin
            if keepN > 0 and not profitable and not rec.enchant then
                -- Usage perso (ex. cuisine) : on crafte jusqu'à la réserve, rentable ou pas.
                local runs = math.ceil(math.max(0, keepN - ns.GetItemCount(rec.pid)) / math.max(1, rec.made or 1))
                local k = Key(prof, rec.name)
                if runs > 0 and not (db[k] and not db[k].auto) then
                    cands[#cands + 1] = { k = k, prof = prof, name = rec.name, runs = runs, cost = ev.cost or 0, roi = math.huge }
                end
            elseif not rec.enchant and ev.profit and not ev.unsold and not ev.whiteGear and not ev.infoPending
                and not Q.IsMaterial(rec.pid)
                and ev.profit >= rules.minProfit and (ev.margin or 0) * 100 >= rules.minMargin then
                local flooded = ev.channel == "ah" and (ev.listed or 0) > rules.maxListed and (ev.sold7 or 0) == 0
                if flooded then
                    skipped = skipped + 1
                else
                    local target = Q.Target(rec, ev, rules, true)
                    -- La réserve perso ("keep") s'ajoute à la cible : elle ne compte pas comme stock à vendre.
                    target = target + (ns.Keep and ns.Keep.Get(rec.pid) or 0)
                    local stock = I.Stock(rec.pid)
                    local runs = math.ceil(math.max(0, target - stock) / math.max(1, rec.made or 1))
                    local k = Key(prof, rec.name)
                    if runs > 0 and not (db[k] and not db[k].auto) then
                        cands[#cands + 1] = { k = k, prof = prof, name = rec.name, runs = runs, cost = ev.cost or 0,
                            roi = (ev.cost or 0) > 0 and ev.profit / ev.cost or math.huge }
                    end
                end
            end
        end
    end
    -- Budget : on ne met en file que ce que vous pouvez payer (part de l'or du perso), les recettes
    -- les plus rentables par pièce investie d'abord. Les réserves perso (keep) passent en premier.
    local budget = math.floor(Q.TotalGold() * (rules.budgetPct or 50) / 100)
    -- Ce que la file manuelle consomme déjà.
    for _, e in pairs(db) do
        if not e.auto then
            local rec = Q.FindRecipe and Q.FindRecipe(e.prof, e.name)
            local ev = rec and CR.GetEval(rec)
            if ev and ev.cost then budget = budget - ev.cost * e.n end
        end
    end
    table.sort(cands, function(a, b) return a.roi > b.roi end)
    local left, cut = math.max(0, budget), false
    for _, c in ipairs(cands) do
        local n = c.runs
        if c.cost > 0 then n = math.min(n, math.floor(left / c.cost)) end
        if n < c.runs then cut = true end
        if n > 0 then
            db[c.k] = { prof = c.prof, name = c.name, n = n, auto = true, owner = me }
            left = left - n * c.cost
            added = added + 1
        end
    end
    if added > 0 and not Q.IsCrafter(me) then CrafterSet()[me] = true end -- remplir une file fait de vous un crafteur
    local msg = (Tr("%d craft%s queued%s%s%s.")):format(added, added == 1 and "" or "s",
        cut and (Tr(" · capped by budget (%s)")):format(ns.FormatMoney(math.max(0, budget), { iconSize = 10 })) or "",
        skipped > 0 and (Tr(" · %d skipped (flooded market)")):format(skipped) or "",
        pending > 0 and (Tr(" · %d still loading, click again in a second")):format(pending) or "")
    -- Crafts pour le marchand : "×30 tant que Linen Cloth ≤ 24c".
    local vendorLines = {}
    for _, c in ipairs(cands) do
        local rec = Q.FindRecipe(c.prof, c.name)
        local d = rec and ns.db.depth and ns.db.depth[rec.pid]
        if d and db[c.k] then
            local parts = {}
            for id, mx in pairs(d.max) do
                parts[#parts + 1] = P.Name(id) .. " ≤ " .. ns.FormatMoney(mx, { iconSize = 10 })
                    .. (d.even and d.even[id] and (" (loses money above " .. ns.FormatMoney(d.even[id], { iconSize = 10 }) .. ")") or "")
            end
            if #parts > 0 then
                vendorLines[#vendorLines + 1] = (Tr("%s ×%d for the vendor, while %s")):format(c.name, db[c.k].n, table.concat(parts, ", "))
            end
        end
    end
    -- Achats directs à revendre au marchand repérés au dernier scan.
    local flips = ns.Market and ns.Market.FlipCount and ns.Market.FlipCount() or 0
    if flips > 0 then msg = msg .. (Tr(" · %d vendor flip%s on the AH (Market tab)")):format(flips, flips > 1 and "s" or "") end
    -- L'or est réparti sur vos persos : signale s'il faut en envoyer à celui qui achète.
    local need = (Q.Plan().buyCost or 0) - (GetMoney and GetMoney() or 0)
    if need > 0 then
        local rich = Q.RichestAlt()
        msg = msg .. (Tr(" · mail yourself %s%s")):format(ns.FormatMoney(need, { iconSize = 10 }), rich and (" from " .. rich) or "")
    end
    if allProfs then msg = msg .. "  (" .. (#profs > 0 and table.concat(profs, ", ") or "open each profession once first") .. ")" end
    if #vendorLines > 0 then msg = msg .. Tr(" · vendor crafts: see chat") end
    Q.SetStatus(msg)
    for _, l in ipairs(vendorLines) do ns.Print(l) end
    Q.Refresh()
    return msg
end

-- Crafteur "de référence" : soi-même si on l'est, sinon le premier crafteur qui a une file (puis le premier tout court).
function Q.Crafter()
    local me = Me()
    if Q.IsCrafter(me) then return me end
    local list = Q.Crafters()
    for _, k in ipairs(list) do
        for _, e in pairs(DB()) do if e.owner == k then return k end end
    end
    return list[1]
end

-- Seuil de perte d'un composant (le plus haut parmi les recettes en file).
function Q.BreakEven(id)
    local best
    for pid, d in pairs(ns.db.depth or {}) do
        if d.even and d.even[id] then
            for _, e in pairs(DB()) do
                local rec = RecFrom(e.prof, e.name)
                if rec and rec.pid == pid then best = math.max(best or 0, d.even[id]); break end
            end
        end
    end
    return best
end

-- Prix maximum à payer pour un composant (le plus haut que tolère une recette en file).
function Q.MaxPrice(id)
    local best
    for pid, d in pairs(ns.db.depth or {}) do
        local queued = false
        for _, e in pairs(DB()) do
            local rec = RecFrom(e.prof, e.name)
            if rec and rec.pid == pid then queued = true; break end
        end
        if queued and d.max and d.max[id] then best = math.max(best or 0, d.max[id]) end
    end
    return best
end

-- ------------------------------------------------------------ plan + courses
function Q.Plan(owner)
    owner = owner or Q.Owner()
    local plan = { crafts = {}, shop = {}, cost = 0, revenue = 0, owner = owner }
    local need, order = {}, {}
    local function Need(id, qty)
        if not need[id] then need[id] = 0; order[#order + 1] = id end
        need[id] = need[id] + qty
    end
    for k, e in pairs(DB()) do
        local rec = (owner == "*" or e.owner == owner) and RecFrom(e.prof, e.name)
        if rec then
            local ev = CR.GetEval(rec)
            plan.crafts[#plan.crafts + 1] = { key = k, prof = e.prof, name = e.name, n = e.n, rec = rec, ev = ev, auto = e.auto, owner = e.owner }
            for _, rg in ipairs(rec.reagents) do if rg.id then Need(rg.id, rg.n * e.n) end end
            plan.cost = plan.cost + (ev.cost or 0) * e.n
            plan.revenue = plan.revenue + (ev.value or 0) * e.n
        end
    end
    table.sort(plan.crafts, function(a, b) return a.name < b.name end)
    -- Intermédiaires : compo moins chère fabriquée qu'achetée, et qu'on peut fabriquer.
    local crafted = {}
    for _, id in ipairs({ unpack(order) }) do
        local _, src = CR.UnitCost(id)
        if src == "craft" then
            local prod, prof, name = CR.ProducerOf(id)
            if prod then
                crafted[id] = true
                local missing = need[id] - I.Mine(id) - (I.Alts(id)) -- tous vos personnages
                local runs = math.ceil(math.max(0, missing) / math.max(1, prod.m or 1))
                if runs > 0 then
                    local rec = RecFrom(prof, name)
                    if rec then
                        table.insert(plan.crafts, 1, { key = Key(prof, name), prof = prof, name = name, n = runs,
                            rec = rec, ev = CR.GetEval(rec), inter = true })
                        for _, rg in ipairs(rec.reagents) do if rg.id then Need(rg.id, rg.n * runs) end end
                    end
                end
            end
        end
    end
    for _, id in ipairs(order) do
        local qty = need[id]
        local mine = I.Mine(id)
        local alts, detail = I.Alts(id)
        local row = { id = id, need = qty, mine = mine, alts = alts, detail = detail, name = P.Name(id),
            icon = ns.GetItemIcon(id) }
        if crafted[id] then
            row.src, row.buy = "craft", 0
            row.toCraft = math.max(0, qty - mine - alts) -- à fabriquer avant les recettes qui l'utilisent
        else
            -- Marchand ou HV : le moins cher. Un objet de marchand n'est pris à l'HV que s'il y est vraiment moins cher.
            row.src = P.IsVendorItem(id) and "vendor" or "ah"
            if row.src == "vendor" then
                local vb = P.VendorBuy(id)
                local ah = P.AHValue(id)
                if vb and ah and ah < vb and not (Q.skipBuy and Q.skipBuy[id]) then row.src, row.cheaper = "ah", vb - ah end
            end
            row.buy = math.max(0, qty - mine - alts)
        end
        row.fromAlts = math.min(alts, math.max(0, qty - mine))
        if row.buy > 0 and CR.UnitCost then
            local u = CR.UnitCost(id)
            plan.buyCost = (plan.buyCost or 0) + (u or 0) * row.buy
        end
        plan.shop[#plan.shop + 1] = row
    end
    table.sort(plan.shop, function(a, b)
        if (a.buy > 0) ~= (b.buy > 0) then return a.buy > 0 end
        return a.name < b.name
    end)
    plan.profit = plan.revenue - plan.cost
    -- Liste affichée : seulement vos recettes en file ; les intermédiaires apparaissent dans les courses ("Craft").
    plan.visible = {}
    for _, c in ipairs(plan.crafts) do if not c.inter then plan.visible[#plan.visible + 1] = c end end
    return plan
end

-- ------------------------------------------------------------ craft
local pendingCraft

-- Combien de fois on peut crafter avec ce qui est DANS LES SACS (le jeu ne crafte pas depuis la banque).
local function BagCount(id)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id, false) or 0 end
    return ns.GetItemCount(id) or 0
end

local function FromBags(rec)
    local n
    for _, rg in ipairs(rec.reagents or {}) do
        if rg.id then
            local k = math.floor(BagCount(rg.id) / math.max(1, rg.n))
            n = n and math.min(n, k) or k
        end
    end
    return n or 0
end

local function FromBagsAndBank(rec)
    local n
    for _, rg in ipairs(rec.reagents or {}) do
        if rg.id then
            local k = math.floor(I.Mine(rg.id) / math.max(1, rg.n))
            n = n and math.min(n, k) or k
        end
    end
    return n or 0
end

local function Available(rec)
    local api = CR.GetAPI()
    local fromGame
    if api and api.key == "modern" and C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
        local info = C_TradeSkillUI.GetRecipeInfo(rec.index)
        fromGame = info and info.numAvailable
    elseif api and GetTradeSkillInfo and rec.index then
        local _, _, avail = GetTradeSkillInfo(rec.index)
        fromGame = avail
    end
    -- Si le jeu ne renseigne pas (ou pas encore) ce nombre, on le calcule depuis les sacs.
    local mine = FromBags(rec)
    if not fromGame or (fromGame == 0 and mine > 0) then return mine end
    return fromGame
end

local function NextCraft(plan)
    local prof = CR.ProfName()
    local blocked, inBank
    for _, c in ipairs(plan.crafts) do
        if c.prof == prof and c.n > 0 then
            local live = LiveRec(c.prof, c.name)
            if live then
                local avail = Available(live)
                if avail > 0 then return c, live, math.min(c.n, avail) end
                if not blocked then
                    blocked = c
                    inBank = FromBagsAndBank(live) > 0
                end
            end
        end
    end
    return nil, nil, 0, blocked, inBank
end

-- Prochain craft faisable maintenant (métier ouvert, compos dans les sacs).
function Q.NextCraftable()
    if not CR.GetAPI() then return nil end
    local c, _, count = NextCraft(Q.Plan())
    return c, count
end

-- Achats HV de ce personnage pas encore récupérés (achetés depuis sa dernière visite à la boîte aux lettres).
-- L'HV livre par courrier, et l'icône de la minicarte ne s'affiche pas toujours.
function Q.PendingMail()
    local key = ns.Ledger and ns.Ledger.CharKey and ns.Ledger.CharKey()
    local c = key and ns.db.chars[key]
    local since = c and c.lastMail or 0
    local items, order = {}, {}
    for i = #ns.db.tx, 1, -1 do
        local tx = ns.db.tx[i]
        if tx.t < since then break end
        if tx.k == "ah_buy" and tx.c == key and tx.i then
            if not items[tx.i] then items[tx.i] = 0; order[#order + 1] = tx.i end
            items[tx.i] = items[tx.i] + (tx.q or 1)
        end
    end
    local parts = {}
    for _, name in ipairs(order) do parts[#parts + 1] = items[name] .. "× " .. name end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

function Q.CraftNext()
    local plan = Q.Plan()
    local c, live, count, blocked, inBank = NextCraft(plan)
    if not c then
        if blocked and inBank then
            Q.SetStatus((Tr("Reagents for %s are in your bank: take them out to your bags.")):format(blocked.name))
        elseif blocked and Q.PendingMail() then
            Q.SetStatus((Tr("Missing reagents for %s: your AH purchases are in the mailbox (%s).")):format(blocked.name, Q.PendingMail()))
        elseif blocked then
            Q.SetStatus((Tr("Missing reagents for %s: check the shopping list.")):format(blocked.name))
        elseif #plan.crafts > 0 then
            Q.SetStatus(Tr("Nothing to craft in this profession: open the profession of the queued recipes."))
        else
            Q.SetStatus(Tr("The queue is empty."))
        end
        return
    end
    pendingCraft = { key = c.key, left = count, inter = c.inter }
    local api = CR.GetAPI()
    if api.key == "modern" and C_TradeSkillUI.CraftRecipe then
        C_TradeSkillUI.CraftRecipe(live.index, count)
    elseif DoTradeSkill then
        DoTradeSkill(live.index, count)
    end
    Q.SetStatus((Tr("Crafting %s ×%d…")):format(c.name, count))
end

-- ------------------------------------------------------------ achats HV (marchandises empilables)
local buy

local function ExpectedUnit(id) return P.AHValue(id) end

function Q.BuyNext()
    local AH = C_AuctionHouse
    if not AH or not AH.StartCommoditiesPurchase then
        P.Status(Tr("Buying from the queue needs the modern auction house."))
        return
    end
    if buy and buy.stage == "confirm" then
        local b = buy
        b.stage = "wait"
        P.Status((Tr("Buying %d× %s…")):format(b.qty, b.name))
        Q.UpdateBuyButton()
        AH.ConfirmCommoditiesPurchase(b.id, b.qty)
        return
    end
    if buy then return end
    local plan = Q.Plan()
    for _, row in ipairs(plan.shop) do
        if row.src == "ah" and row.buy > 0 and not (Q.skipBuy and Q.skipBuy[row.id]) then
            if not ns.IsCommodity(row.id) then
                Q.skipBuy = Q.skipBuy or {}
                Q.skipBuy[row.id] = true
                P.Status((Tr("%s isn't stackable: buy it from the Buy tab.")):format(row.name))
                Q.UpdateBuyButton()
                return
            end
            local mx = Q.MaxPrice(row.id)
            if mx and AH.SendSearchQuery and AH.MakeItemKey and AH.GetCommoditySearchResultInfo then
                -- Prix maximum connu : on regarde d'abord combien il en reste à ce prix, et on n'achète que ceux-là.
                buy = { id = row.id, qty = row.buy, name = row.name, stage = "depth", max = mx }
                P.Status((Tr("Checking how many %s are listed at %s or less…")):format(row.name, ns.FormatMoney(mx, { iconSize = 10 })))
                Q.UpdateBuyButton()
                AH.SendSearchQuery(AH.MakeItemKey(row.id), { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }, false)
                local my = buy
                C_Timer.After(5, function() if buy == my and buy.stage == "depth" then Q.CancelBuy("No answer from the AH, click again.") end end)
                return
            end
            buy = { id = row.id, qty = row.buy, name = row.name, stage = "price" }
            P.Status((Tr("Getting the price for %d× %s…")):format(row.buy, row.name))
            Q.UpdateBuyButton()
            AH.StartCommoditiesPurchase(row.id, row.buy)
            return
        end
    end
    P.Status(Tr("Nothing left to buy at the AH for this queue."))
end

-- Résultat de la recherche : quantité disponible à votre prix maximum ou moins.
function Q.OnDepth(itemID)
    if not buy or buy.stage ~= "depth" or itemID ~= buy.id then return end
    local AH = C_AuctionHouse
    local cheap = 0
    for k = 1, (AH.GetNumCommoditySearchResults(itemID) or 0) do
        local r = AH.GetCommoditySearchResultInfo(itemID, k)
        if r and r.unitPrice then
            if r.unitPrice > buy.max then break end
            if not ((r.numOwnerItems or 0) > 0) then cheap = cheap + (r.quantity or 0) end
        end
    end
    if cheap == 0 then
        Q.skipBuy = Q.skipBuy or {}; Q.skipBuy[buy.id] = true
        Q.CancelBuy((Tr("No %s left at %s or less. Scan, then Auto-fill to recalculate.")):format(buy.name,
            ns.FormatMoney(buy.max, { iconSize = 10 })))
        return
    end
    local qty = math.min(buy.qty, cheap)
    buy.partial = qty < buy.qty
    buy.qty, buy.stage = qty, "price"
    P.Status((Tr("Getting the price for %d× %s%s…")):format(qty, buy.name, buy.partial and " (all that's left at your max)" or ""))
    Q.UpdateBuyButton()
    AH.StartCommoditiesPurchase(buy.id, qty)
end

function Q.OnPrice(unit, total)
    if not buy or buy.stage ~= "price" then return end
    local bid = buy.id
    -- Garde-fous anti-arnaque : jamais plus cher qu'un marchand, jamais très au-dessus du prix habituel.
    local vb, est = P.VendorBuy(buy.id)
    if vb and unit and unit > vb then
        Q.CancelBuy((Tr("%s is sold by vendors for %s%s: not bought at the AH (%s each).")):format(buy.name,
            ns.FormatMoney(vb, { iconSize = 10 }), est and " (est.)" or "", ns.FormatMoney(unit, { iconSize = 10 })))
        Q.skipBuy = Q.skipBuy or {}; Q.skipBuy[bid] = true
        return
    end
    local usual = P.Market(buy.id)
    local mx0 = Q.MaxPrice(buy.id)
    local even = Q.BreakEven(bid)
    if unit and even and unit > even then
        Q.CancelBuy((Tr("%s: %s each, you'd LOSE money above %s. Not bought.")):format(buy.name,
            ns.FormatMoney(unit, { iconSize = 10 }), ns.FormatMoney(even, { iconSize = 10 })))
        Q.skipBuy = Q.skipBuy or {}; Q.skipBuy[bid] = true
        return
    end
    if unit and ((mx0 and unit > mx0) or (usual and unit > usual * 2)) then
        Q.CancelBuy((Tr("%s: %s each is %s, not bought. Buy fewer by hand if you still want it.")):format(buy.name,
            ns.FormatMoney(unit, { iconSize = 10 }), mx0 and unit > mx0 and ("above your max " .. ns.FormatMoney(mx0, { iconSize = 10 }))
            or ("over twice the usual " .. ns.FormatMoney(usual, { iconSize = 10 }))))
        Q.skipBuy = Q.skipBuy or {}; Q.skipBuy[bid] = true
        return
    end
    buy.unit, buy.total, buy.stage = unit, total, "confirm"
    local exp = ExpectedUnit(buy.id)
    local warn = ""
    local mx = Q.MaxPrice(buy.id)
    if mx and unit and unit > mx then
        warn = (Tr("  |cffed5c52above your max %s: not profitable anymore!|r")):format(ns.FormatMoney(mx, { iconSize = 10 }))
    elseif exp and unit and unit > exp * 1.5 then
        warn = (Tr("  |cffed5c52%d%% above usual!|r")):format(math.floor((unit / exp - 1) * 100))
    end
    P.Status((Tr("Buy %d× %s for %s (%s each)? Click Confirm.%s")):format(buy.qty, buy.name,
        ns.FormatMoney(total, { iconSize = 10 }), ns.FormatMoney(unit, { iconSize = 10 }), warn))
    Q.UpdateBuyButton()
end

function Q.CancelBuy(msg)
    if buy and buy.stage == "confirm" and C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then
        pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    end
    buy = nil
    if msg then P.Status(msg) end
    Q.UpdateBuyButton()
end

local buyButton
function Q.UpdateBuyButton()
    if not buyButton then return end
    local n, first = 0, nil
    for _, row in ipairs(Q.Plan().shop) do
        if row.src == "ah" and row.buy > 0 and not (Q.skipBuy and Q.skipBuy[row.id]) then
            n = n + 1; first = first or row
        end
    end
    if buy and buy.stage == "confirm" then
        buyButton.text:SetText(Tr("Confirm ") .. buy.qty .. "× " .. buy.name)
    elseif buy then
        buyButton.text:SetText(buy.stage == "depth" and "Checking…" or "…")
    else
        -- Ce que le prochain clic achète, en clair.
        buyButton.text:SetText(first and (Tr("Buy %d× %s")):format(first.buy, first.name) or "No reagent to buy here")
    end
    buyButton.tooltip = (Tr("%d reagent%s to buy. You confirm the total price; never above the vendor price or your profitable max.")):format(n, n == 1 and "" or "s")
    buyButton:SetDisabled(n == 0 and not buy)
end

ns.On("AH_BAR_READY", function(bar)
    if buyButton then return end
    buyButton = T.Button(bar, Tr("Buy reagents"), 220, 26, function() Q.BuyNext() end)
    buyButton:SetPoint("LEFT", bar.scan or bar, bar.scan and "RIGHT" or "LEFT", 6, 0)
    bar.buyButton = buyButton
    bar:SetWidth(790)
    Q.UpdateBuyButton()
end)

-- ------------------------------------------------------------ achats marchand
local vendorButton
local UpdateVendorButton
local function VendorNeeds()
    local plan = Q.Plan()
    local wants = {}
    for _, row in ipairs(plan.shop) do if row.src == "vendor" and row.buy > 0 then wants[row.id] = row.buy end end
    local list = {}
    for i = 1, (GetMerchantNumItems and GetMerchantNumItems() or 0) do
        local id = P.ItemID(GetMerchantItemLink(i))
        if id and wants[id] then list[#list + 1] = { index = i, id = id, qty = wants[id] } end
    end
    return list
end

function Q.VendorNeedCount()
    local n = 0
    for _, w in ipairs(VendorNeeds()) do n = n + w.qty end
    return n
end

-- Achète chez le marchand tout ce que la file demande encore (prix unitaire du marchand).
-- Manuel : aperçu à cocher d'abord ; "only" = { [id] = true } limite l'achat aux lignes cochées.
function Q.BuyVendorNeeds(auto, only)
    local list = VendorNeeds()
    if #list == 0 then return end
    if not auto and not only and ns.Preview then
        local rows = {}
        for _, w in ipairs(list) do
            local _, _, price, stack = ns.GetMerchantItemInfo(w.index)
            local unit = (price and stack and stack > 0) and price / stack or 0
            rows[#rows + 1] = { id = w.id, qty = w.qty, value = math.floor(unit * w.qty) }
        end
        ns.Preview.Show(rows, { title = Tr("Buy from this vendor"), sub = Tr("Reagents your craft queue still needs."), confirm = Tr("Buy") },
            function(chosen)
                local set = {}
                for _, r in ipairs(chosen) do set[r.id] = true end
                Q.BuyVendorNeeds(false, set)
            end)
        return
    end
    if only then
        local f = {}
        for _, w in ipairs(list) do if only[w.id] then f[#f + 1] = w end end
        list = f
    end
    local total, spent = 0, 0
    for _, w in ipairs(list) do
        local _, _, price, stack = ns.GetMerchantItemInfo(w.index)
        local unit = (price and stack and stack > 0) and price / stack or 0
        local cost = unit * w.qty
        if GetMoney() < spent + cost then
            ns.Print(Tr("|cffed5c52not enough gold for all the vendor reagents.|r"))
            break
        end
        local left = w.qty
        local maxStack = (GetMerchantItemMaxStack and GetMerchantItemMaxStack(w.index)) or 20
        while left > 0 do
            local n = math.min(left, math.max(1, maxStack))
            BuyMerchantItem(w.index, n)
            left = left - n
        end
        total, spent = total + w.qty, spent + cost
    end
    if total > 0 then
        ns.Print((Tr("%sbought %d vendor reagent%s for your craft queue (%s).")):format(auto and "auto-" or "",
            total, total > 1 and "s" or "", ns.FormatMoney(spent, { iconSize = 11 })))
    end
    C_Timer.After(0.5, function() if UpdateVendorButton then UpdateVendorButton() end end)
end

function UpdateVendorButton()
    if ns.Routine and ns.Routine.UpdateMerchantBar then ns.Routine.UpdateMerchantBar(); return end
    if not MerchantFrame or not MerchantFrame:IsShown() then return end
    local list = VendorNeeds()
    if not vendorButton then
        vendorButton = T.Button(MerchantFrame, "", 230, 26, function()
            Q.BuyVendorNeeds(false)
        end, "primary")
        vendorButton:SetPoint("BOTTOMLEFT", MerchantFrame, "TOPLEFT", 60, 4)
        vendorButton.tooltip = Tr("Buys every vendor reagent your craft queue still needs.")
    end
    if #list > 0 then
        local n = 0
        for _, w in ipairs(list) do n = n + w.qty end
        vendorButton.text:SetText((Tr("Buy queue reagents (%d)")):format(n))
        vendorButton:Show()
    else
        vendorButton:Hide()
    end
end

-- ------------------------------------------------------------ interface (onglet "Queue")
local view
local QROWS, SROWS = 6, 6

function Q.SetStatus(text)
    if view then view.status:SetText(text or "") end
end

local SRC = {
    vendor = { "Vendor", { 0.88, 0.66, 0.24 } }, ah = { "AH", { 0.55, 0.75, 0.95 } },
    craft = { "Craft", { 0.65, 0.85, 0.55 } },
}

local function Stepper(parent, y, label, get, set, step, fmt)
    local l = T.Text(parent, 12, { color = C.text, text = label }); l:SetPoint("TOPLEFT", 16, y)
    local v = T.Text(parent, 12, { bold = true, justify = "CENTER" }); v:SetPoint("TOPRIGHT", -52, y); v:SetWidth(70)
    local minus = T.Button(parent, "−", 22, 20, function() set(get() - step); v:SetText(fmt(get())) end)
    minus:SetPoint("RIGHT", v, "LEFT", -4, 0)
    local plus = T.Button(parent, "+", 22, 20, function() set(get() + step); v:SetText(fmt(get())) end)
    plus:SetPoint("LEFT", v, "RIGHT", 4, 0)
    v:SetText(fmt(get()))
    return v
end

local function BuildRules(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    f:SetFrameLevel((parent:GetFrameLevel() or 1) + 20)
    f:EnableMouse(true)
    T.Surface(f, C.surface2, 10)
    local t = T.Text(f, 13, { bold = true, text = Tr("Queue rules") }); t:SetPoint("TOPLEFT", 16, -14)
    local r = CR.Rules()
    local function Num(k, lo, hi) return function() return r[k] end, function(v) r[k] = math.max(lo, math.min(hi, v)) end end
    local money = function(v) return ns.FormatMoney(v, { iconSize = 10 }) end
    local plain = function(v) return tostring(v) end
    local g, s
    local rows = {
        { "minProfit", 0, 1000000, "Min profit per craft", 5, money },
        { "minMargin", 0, 500, "Min margin", 5, function(v) return v .. " %" end },
        { "startQty", 1, 50, "Stock target (no sales yet)", 1, plain },
        { "minQty", 1, 50, "Stock target min", 1, plain },
        { "maxQty", 1, 1000, "Stock target cap (adaptive)", 10, plain },
        { "maxListed", 0, 1000000, "Skip if more listed than", 1000, plain },
        { "unsoldPosts", 1, 50, "\"Doesn't sell\" after posts", 1, plain },
        { "deposit", 0, 100000, "AH deposit per post", 10, money },
        { "sellChance", 5, 100, "Sell chance (no history yet)", 5, function(v) return v .. " %" end },
        { "budgetPct", 5, 100, "Spend at most (of your gold)", 5, function(v) return v .. " %" end },
        { "vendorCap", 0, 500, "Crafts for the vendor (per session)", 10, plain },
    }
    for i, d in ipairs(rows) do
        g, s = Num(d[1], d[2], d[3])
        Stepper(f, -44 - (i - 1) * 28, d[4], g, s, d[5], d[6])
    end
    -- Interrupteur : équipement blanc au prix marchand
    local wy = -44 - #rows * 28
    local wl = T.Text(f, 12, { color = C.text, text = Tr("White gear: vendor price only") }); wl:SetPoint("TOPLEFT", 16, wy)
    local wb
    wb = T.Button(f, "", 70, 20, function()
        r.ignoreWhiteGear = not r.ignoreWhiteGear
        wb.text:SetText(r.ignoreWhiteGear and "On" or "Off"); wb:SetSelected(r.ignoreWhiteGear)
    end, "pill")
    wb:SetPoint("TOPRIGHT", -52, wy + 3)
    wb.text:SetText(r.ignoreWhiteGear and "On" or "Off"); wb:SetSelected(r.ignoreWhiteGear)
    wb.tooltip = Tr("White (common) gear rarely sells on the AH: value it at the vendor price only. Bags, armor kits and reagents are not affected.")
    local hint = T.Text(f, 11, { color = C.faint, wrap = true, justify = "LEFT",
        text = Tr("Stock target: starts at 2 (gear: 1), +2 when it sells, ×2 when everything sells within an hour, −2 when it doesn't. Capped by your budget.") })
    hint:SetPoint("TOPLEFT", 16, -44 - (#rows + 1) * 28 - 4)
    hint:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    local done = T.Button(f, Tr("Done"), 90, 26, function() f:Hide(); CR.Refresh() end, "primary")
    done:SetPoint("BOTTOMRIGHT", -12, 12)
    f:Hide()
    return f
end

local function Card(parent)
    local f = CreateFrame("Frame", nil, parent)
    T.Surface(f, C.surface, 10)
    return f
end

local function Build(panel)
    view = CreateFrame("Frame", nil, panel)
    view:SetPoint("TOPLEFT", 12, -46)
    view:SetPoint("BOTTOMRIGHT", -12, 12)

    local auto = T.Button(view, Tr("Auto-fill"), 110, 26, function() Q.AutoQueue(IsShiftKeyDown()) end)
    auto:SetPoint("TOPLEFT", 0, 0)
    auto.tooltip = Tr("Fills the queue with what's worth crafting now, in the right quantities and within your budget. Shift-click: all your professions.")
    local clear = T.Button(view, Tr("Clear"), 64, 26, function() Q.Clear() end)
    clear:SetPoint("LEFT", auto, "RIGHT", 6, 0)
    local rulesBtn = T.Button(view, Tr("Settings"), 80, 26, function() ns.UI.Toggle("settings") end)
    rulesBtn:SetPoint("LEFT", clear, "RIGHT", 6, 0)
    rulesBtn.tooltip = Tr("Profit, margin, budget, quantities.")
    view.status = T.Text(view, 11, { color = C.muted })
    view.status:SetPoint("TOPLEFT", 2, -34)
    view.status:SetWidth(PW and PW - 30 or 400)

    -- File
    local qc = Card(view)
    qc:SetPoint("TOPLEFT", 0, -52); qc:SetPoint("TOPRIGHT", 0, -52); qc:SetHeight(32 + QROWS * 24 + 6)
    local qt = T.Text(qc, 12, { bold = true, text = Tr("To craft") }); qt:SetPoint("TOPLEFT", 14, -10)
    view.sum = T.Text(qc, 11, { color = C.muted, justify = "RIGHT" }); view.sum:SetPoint("TOPRIGHT", -12, -11)
    view.qrows = {}
    for i = 1, QROWS do
        local r = CreateFrame("Frame", nil, qc)
        r:SetHeight(24)
        r:SetPoint("TOPLEFT", 8, -30 - (i - 1) * 24); r:SetPoint("TOPRIGHT", -8, -30 - (i - 1) * 24)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(18, 18); r.icon:SetPoint("LEFT", 2, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.name = T.Text(r, 12); r.name:SetPoint("LEFT", 26, 0); r.name:SetWidth(124)
        r.keep = ns.Keep.Button(r); r.keep:SetPoint("LEFT", 154, 0)
        r.minus = T.Button(r, "−", 20, 18, function() if r.entry then Q.Add(r.entry.prof, r.entry.name, -1) end end)
        r.minus:SetPoint("LEFT", 204, 0)
        r.count = T.Text(r, 12, { bold = true, justify = "CENTER" }); r.count:SetPoint("LEFT", r.minus, "RIGHT", 2, 0)
        r.count:SetWidth(34)
        r.plus = T.Button(r, "+", 20, 18, function() if r.entry then Q.Add(r.entry.prof, r.entry.name, 1) end end)
        r.plus:SetPoint("LEFT", r.count, "RIGHT", 2, 0)
        r.profit = T.Text(r, 11, { justify = "RIGHT" }); r.profit:SetPoint("RIGHT", -2, 0)
        r.chan = T.Text(r, 10, { bold = true, justify = "RIGHT" }); r.chan:SetPoint("RIGHT", r.profit, "LEFT", -6, 0)
        r:EnableMouse(true)
        r:SetScript("OnEnter", function(self)
            local c = self.entry
            if not c or not c.rec.pid then return end
            T.ItemTooltip(self, c.rec.pid)
            if c.inter then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(Tr("Crafted as a reagent for the recipes below it in the queue: not sold, not mailed."), 0.6, 0.85, 0.55, true)
                GameTooltip:Show()
                return
            end
            if c.ev and c.ev.verdict then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(Tr("|cffe0a83dImpot|rPointGouv: ") .. c.ev.verdict, 1, 1, 1)
                if c.ev.profit then
                    GameTooltip:AddDoubleLine(Tr("Profit per craft"), ns.FormatMoney(c.ev.profit, { sign = true, color = true, iconSize = 11 }), 0.7, 0.7, 0.7)
                end
                if c.prof then GameTooltip:AddDoubleLine(Tr("Profession"), c.prof, 0.7, 0.7, 0.7, 1, 1, 1) end
                local d = ns.db.depth and ns.db.depth[c.rec.pid]
                if c.ev.channel == "vendor" and not d then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine((Tr("For the vendor: up to %d per session (Rules).")):format(CR.Rules().vendorCap or 40), 0.88, 0.66, 0.24)
                    GameTooltip:AddLine(Tr("Click Scan at the AH, then Queue profitable: it tells you up to which reagent price it stays profitable."), 0.6, 0.6, 0.6, true)
                elseif d and c.ev.channel == "vendor" then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine((Tr("Profitable at the vendor up to %d crafts while:")):format(d.n), 0.88, 0.66, 0.24)
                    for id, mx in pairs(d.max) do
                        GameTooltip:AddDoubleLine((Tr("  %s (buy %d)")):format(P.Name(id), d.buy[id] or 0),
                            "≤ " .. ns.FormatMoney(mx, { iconSize = 11 }), 0.8, 0.8, 0.8, 1, 1, 1)
                        if d.even and d.even[id] then
                            GameTooltip:AddDoubleLine(Tr("    loses money above"), ns.FormatMoney(d.even[id], { iconSize = 11 }), 0.6, 0.6, 0.6, 0.93, 0.36, 0.32)
                        end
                    end
                    GameTooltip:AddLine((Tr("From your scan %s ago.")):format(P.Ago(time() - (d.t or time()) + (d.age or 0))), 0.5, 0.5, 0.5)
                else
                    local st = ns.db.settings.adapt and ns.db.settings.adapt[c.rec.pid]
                    if st then GameTooltip:AddDoubleLine(Tr("Stock target"), st.why or tostring(st.t), 0.7, 0.7, 0.7, 1, 1, 1) end
                end
            end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        view.qrows[i] = r
    end
    view.qempty = T.Text(qc, 12, { color = C.faint, justify = "CENTER", wrap = true,
        text = Tr("Empty. Click Auto-fill, or right-click a recipe in the profession window.") })
    view.qempty:SetPoint("CENTER", 0, -10); view.qempty:SetWidth(320)
    view.qoff = 0
    qc:EnableMouseWheel(true)
    qc:SetScript("OnMouseWheel", function(_, d)
        view.qoff = math.max(0, math.min(math.max(0, (view.ncrafts or 0) - QROWS), view.qoff - d))
        Q.Refresh()
    end)

    -- Courses
    local sc = Card(view)
    sc:SetPoint("TOPLEFT", qc, "BOTTOMLEFT", 0, -10); sc:SetPoint("TOPRIGHT", qc, "BOTTOMRIGHT", 0, -10)
    sc:SetHeight(46 + SROWS * 22 + 6)
    local st = T.Text(sc, 12, { bold = true, text = Tr("Shopping list") }); st:SetPoint("TOPLEFT", 14, -10)
    view.ssum = T.Text(sc, 11, { color = C.muted, justify = "RIGHT" }); view.ssum:SetPoint("TOPRIGHT", -12, -11)
    local cols = { { "Need", 186 }, { "Have", 226 }, { "Alts", 266 }, { "Buy", 306 } }
    for _, c in ipairs(cols) do
        local h = T.Text(sc, 10, { bold = true, color = C.faint, justify = "RIGHT", text = c[1] })
        h:SetPoint("TOPRIGHT", sc, "TOPLEFT", c[2] + 8, -30); h:SetWidth(40)
    end
    view.srows = {}
    for i = 1, SROWS do
        local r = CreateFrame("Frame", nil, sc)
        r:SetHeight(22)
        r:SetPoint("TOPLEFT", 8, -44 - (i - 1) * 22); r:SetPoint("TOPRIGHT", -8, -44 - (i - 1) * 22)
        r:EnableMouse(true)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(16, 16); r.icon:SetPoint("LEFT", 2, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.name = T.Text(r, 11); r.name:SetPoint("LEFT", 24, 0); r.name:SetWidth(126)
        local function Col(x) local t = T.Text(r, 11, { justify = "RIGHT" }); t:SetPoint("RIGHT", r, "LEFT", x, 0); t:SetWidth(40); return t end
        r.need, r.have, r.alts, r.buy = Col(186), Col(226), Col(266), Col(306)
        r.src = T.Text(r, 10, { bold = true }); r.src:SetPoint("LEFT", 318, 0)
        r:SetScript("OnEnter", function(self)
            local row = self.row
            if not row then return end
            T.ItemTooltip(self, row.id)
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine(Tr("Needed"), row.need, 0.7, 0.7, 0.7, 1, 1, 1)
            GameTooltip:AddDoubleLine(Tr("On this character (bags + bank)"), row.mine, 0.7, 0.7, 0.7, 1, 1, 1)
            for _, d in ipairs(row.detail or {}) do
                GameTooltip:AddDoubleLine("  " .. d[1], d[2], 0.7, 0.7, 0.7, 1, 1, 1)
            end
            if row.fromAlts > 0 then GameTooltip:AddLine(Tr("Mail ") .. row.fromAlts .. Tr(" from your alts."), 0.88, 0.66, 0.24) end
            if row.src == "craft" then GameTooltip:AddLine(Tr("Cheaper to craft: added to the queue automatically."), 0.65, 0.85, 0.55) end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        view.srows[i] = r
    end
    view.sempty = T.Text(sc, 12, { color = C.faint, justify = "CENTER", text = Tr("Nothing to buy.") })
    view.sempty:SetPoint("CENTER", 0, -10)
    view.soff = 0
    sc:EnableMouseWheel(true)
    sc:SetScript("OnMouseWheel", function(_, d)
        view.soff = math.max(0, math.min(math.max(0, (view.nshop or 0) - SROWS), view.soff - d))
        Q.Refresh()
    end)

    view.rules = BuildRules(view)

    view.craft = T.Button(view, Tr("Craft next"), 200, 36, function() Q.CraftNext() end, "primary")
    view.craft:HookScript("OnEnter", function(self)
        local key = ns.Next and ns.Next.Key()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(Tr("Crafts every queued copy of the next recipe."), 1, 1, 1, true)
        GameTooltip:AddLine(key and ("\"Next action\" key: " .. key .. Tr(" (crafts; disenchants when the Disenchant window is open)"))
            or "Tip: bind \"Next action\" in Options > Keybindings > AddOns > ImpotPointGouv to craft and disenchant with one key.",
            0.88, 0.66, 0.24, true)
        GameTooltip:Show()
    end)
    view.craft:SetPoint("BOTTOMLEFT", 0, 0); view.craft:SetPoint("BOTTOMRIGHT", 0, 0)
    view:Hide()
end

function Q.ShowIn(panel)
    if not view then Build(panel) end
    view:Show()
    Q.Refresh()
end

function Q.HideView() if view then view:Hide() end end

function Q.Refresh()
    Q.UpdateBuyButton()
    UpdateVendorButton()
    if ns.Routine and ns.Routine.Refresh then ns.Routine.Refresh() end
    if ns.Next then C_Timer.After(0.2, ns.Next.Arm) end
    if not view or not view:IsShown() then return end
    local plan = Q.Plan()
    local list = plan.visible
    view.ncrafts = #list
    view.qoff = math.min(view.qoff, math.max(0, #list - QROWS))
    for i, r in ipairs(view.qrows) do
        local c = list[view.qoff + i]
        if c then
            r.entry = c
            r.icon:SetTexture(c.rec.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.name:SetText(c.inter and ("|cff9ad98c" .. c.name .. Tr("|r  |cff615f5c· reagent|r")) or c.name)
            r.name:SetWidth(c.inter and 186 or 124) -- pas de bouton keep ni de +/- sur un intermédiaire
            r.keep:SetItem(not c.inter and c.rec.pid or nil)
            r.count:SetText("×" .. c.n)
            r.minus:SetShown(not c.inter); r.plus:SetShown(not c.inter)
            if c.ev.profit and not c.inter then
                r.profit:SetText(ns.FormatMoney(c.ev.profit * c.n, { sign = true, color = true, short = true, iconSize = 10 }))
            else
                r.profit:SetText("")
            end
            r.chan:SetText(c.inter and "" or ns.ChannelLabel(c.ev.channel))
            r:Show()
        else
            r.entry = nil
            r:Hide()
        end
    end
    view.qempty:SetShown(#plan.crafts == 0)
    view.sum:SetText(#plan.crafts > 0 and (Tr("cost %s  ·  profit %s")):format(
        ns.FormatMoney(plan.cost, { short = true, iconSize = 10 }),
        ns.FormatMoney(plan.profit, { sign = true, color = true, short = true, iconSize = 10 })) or "")

    view.nshop = #plan.shop
    view.soff = math.min(view.soff, math.max(0, #plan.shop - SROWS))
    local buyCost = 0
    for _, row in ipairs(plan.shop) do
        if row.buy > 0 then
            local unit = row.src == "vendor" and P.VendorBuy(row.id) or P.AHValue(row.id)
            buyCost = buyCost + (unit or 0) * row.buy
        end
    end
    for i, r in ipairs(view.srows) do
        local row = plan.shop[view.soff + i]
        r.row = row
        if row then
            r.icon:SetTexture(row.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.name:SetText(row.name)
            r.need:SetText(row.need)
            r.have:SetText(row.mine >= row.need and ("|cff5cd173" .. row.mine .. "|r") or row.mine)
            r.alts:SetText(row.alts > 0 and ("|cffe0a83d" .. row.alts .. "|r") or "|cff615f5c0|r")
            if row.src == "craft" then
                r.buy:SetText((row.toCraft or 0) > 0 and ("|cff9ad98c" .. row.toCraft .. "|r") or "|cff5cd173✓|r")
            else
                r.buy:SetText(row.buy > 0 and ("|cffed5c52" .. row.buy .. "|r") or "|cff5cd173✓|r")
            end
            local s = SRC[row.src]
            local mx = row.src == "ah" and Q.MaxPrice(row.id)
            r.src:SetText(mx and ("≤ " .. ns.FormatMoney(mx, { short = true, iconSize = 9 })) or s[1])
            r.src:SetTextColor(s[2][1], s[2][2], s[2][3])
            r:Show()
        else
            r:Hide()
        end
    end
    view.sempty:SetShown(#plan.shop == 0)
    view.ssum:SetText(buyCost > 0 and ("to buy ≈ " .. ns.FormatMoney(buyCost, { short = true, iconSize = 10 })) or "")

    local c, _, count, blocked, inBank = NextCraft(plan)
    if c then
        view.craft.text:SetText((Tr("Craft next:  %s ×%d")):format(c.name, count))
        view.craft:SetDisabled(false)
    else
        view.craft.text:SetText(blocked and (inBank and ("Reagents in your bank (" .. blocked.name .. ")")
            or (Q.PendingMail() and "Your AH purchases are in the mailbox")
            or ("Missing reagents for " .. blocked.name)) or "Craft next")
        view.craft:SetDisabled(true)
    end
    -- Onglet : compteur
    local panel = CR.Panel()
    if panel and panel.tabButtons then
        local n = 0
        for _, e in pairs(DB()) do n = n + e.n end
        panel.tabButtons.queue.text:SetText(n > 0 and ("Queue (" .. n .. ")") or "Queue")
    end
end

-- ------------------------------------------------------------ événements
local ev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(ev, "Queue") end
for _, e in ipairs({ "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
    "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED",
    "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_CLOSED", "MERCHANT_SHOW", "MERCHANT_UPDATE",
    "COMMODITY_SEARCH_RESULTS_UPDATED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, a1, a2)
    if not ns.db then return end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 == "player" and pendingCraft and pendingCraft.left > 0 then
            pendingCraft.left = pendingCraft.left - 1
            if not pendingCraft.inter then
                local e = DB()[pendingCraft.key]
                if e then
                    e.n = e.n - 1
                    if e.n <= 0 then DB()[pendingCraft.key] = nil end
                end
            end
            if pendingCraft.left <= 0 then pendingCraft = nil end
            C_Timer.After(0.3, Q.Refresh)
        end
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
        if a1 == "player" and pendingCraft then pendingCraft = nil; C_Timer.After(0.3, Q.Refresh) end
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        Q.OnDepth(a1)
    elseif event == "COMMODITY_PRICE_UPDATED" then
        Q.OnPrice(a1, a2)
    elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
        Q.CancelBuy("That reagent isn't available on the AH right now.")
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
        local b = buy
        buy = nil
        if b then
            P.Status((Tr("Bought %d× %s.%s")):format(b.qty, b.name,
                b.partial and " That's all at your max price: click Auto-fill to resize the queue." or ""))
        end
        C_Timer.After(0.5, Q.Refresh)
    elseif event == "COMMODITY_PURCHASE_FAILED" then
        Q.CancelBuy("Purchase failed (price changed or not enough gold). Click again to retry.")
    elseif event == "AUCTION_HOUSE_CLOSED" then
        if buy then Q.CancelBuy() end
        Q.skipBuy = nil
    elseif event == "MERCHANT_SHOW" then
        -- Achat automatique des compos marchand de la file (désactivable : /ipg vendor).
        if ns.db.settings.autoVendorBuy == true then
            C_Timer.After(0.4, function() Q.BuyVendorNeeds(true) end)
        end
        C_Timer.After(0.1, UpdateVendorButton)
    elseif event == "MERCHANT_UPDATE" then
        C_Timer.After(0.1, UpdateVendorButton)
    end
end)
ns.On("INVENTORY_CHANGED", function() Q.Refresh() end)
