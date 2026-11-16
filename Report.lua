-- ImpotPointGouv : bilan de test par objet (/ipg report).
-- Mises en vente, ventes, prix moyens, délai de vente, invendus, et résultats réels de désenchantement.
local _, ns = ...
local Tr = ns.L
local P = ns.Prices
local R = {}
ns.Report = R

-- Montants en texte simple (copiable) : 1g 23s 45c
local function Plain(v, sign)
    if not v then return "—" end
    v = math.floor(v + 0.5)
    local neg = v < 0
    v = math.abs(v)
    local g, s, c = math.floor(v / 10000), math.floor(v / 100) % 100, v % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    return (neg and "-" or (sign and "+" or "")) .. table.concat(parts, " ")
end
local function M(v) return Plain(v) end

function R.Build(days)
    days = days or 30
    local since = time() - days * 86400
    local items, order = {}, {}
    local function Item(name)
        name = name or "?"
        local it = items[name]
        if not it then
            it = { name = name, posts = 0, postedQty = 0, listSum = 0, listN = 0, sold = 0, soldGross = 0, net = 0,
                expired = 0, cancelled = 0, waits = {}, postTimes = {} }
            items[name] = it
            order[#order + 1] = name
        end
        return it
    end
    for _, tx in ipairs(ns.db.tx) do
        if tx.t >= since and tx.i then
            if tx.k == "ah_deposit" then
                local it = Item(tx.i)
                it.posts = it.posts + 1
                it.postedQty = it.postedQty + (tx.q or 1)
                if tx.unit then it.listSum = it.listSum + tx.unit; it.listN = it.listN + 1 end
                it.net = it.net + tx.a
                for _ = 1, (tx.q or 1) do it.postTimes[#it.postTimes + 1] = tx.t end
            elseif tx.k == "ah_sale" then
                local it = Item(tx.i)
                local q = (tx.q and tx.q > 0) and tx.q or 1
                it.sold = it.sold + q
                it.soldGross = it.soldGross + (tx.gross or tx.a)
                it.net = it.net + tx.a
                for _ = 1, q do
                    local t0 = table.remove(it.postTimes, 1) -- mise en vente la plus ancienne (FIFO)
                    if t0 then it.waits[#it.waits + 1] = tx.t - t0 end
                end
            elseif tx.k == "ah_expired" then
                local it = Item(tx.i); it.expired = it.expired + (tx.q or 1)
                for _ = 1, (tx.q or 1) do table.remove(it.postTimes, 1) end
            elseif tx.k == "ah_cancelled" then
                local it = Item(tx.i); it.cancelled = it.cancelled + (tx.q or 1)
                for _ = 1, (tx.q or 1) do table.remove(it.postTimes, 1) end
            end
        end
    end
    local lines = {}
    local function Add(s) lines[#lines + 1] = s end
    Add((Tr("ImpotPointGouv test report  ·  last %d days  ·  %s")):format(days, date("%d/%m/%Y %H:%M")))
    Add("")
    Add("== AH: per item ==")
    Add("item | posted (posts) | avg list price | sold | avg sale price | expired/cancelled | still listed | avg time to sell | net gold")
    table.sort(order, function(a, b) return items[a].net > items[b].net end)
    for _, name in ipairs(order) do
        local it = items[name]
        local wait = 0
        for _, w in ipairs(it.waits) do wait = wait + w end
        local waitTxt = #it.waits > 0 and ("%.1f h"):format(wait / #it.waits / 3600) or "—"
        Add(("%s | %d (%d) | %s | %d | %s | %d/%d | %d | %s | %s"):format(name, it.postedQty, it.posts,
            it.listN > 0 and M(it.listSum / it.listN) or "—", it.sold,
            it.sold > 0 and M(it.soldGross / it.sold) or "—", it.expired, it.cancelled, #it.postTimes, waitTxt,
            Plain(it.net, true)))
    end
    if #order == 0 then Add("(no AH activity yet)") end
    Add("")
    Add("== Disenchant results ==")
    local log = ns.db.deLog or {}
    local byItem, dorder = {}, {}
    for _, e in ipairs(log) do
        if e.t >= since then
            local key = (e.name or "unknown item") .. (e.ilvl and (" (ilvl " .. e.ilvl .. ")") or "")
            local b = byItem[key]
            if not b then b = { n = 0, out = {}, predicted = e.id and P.DisenchantValue(e.id) }; byItem[key] = b; dorder[#dorder + 1] = key end
            b.n = b.n + 1
            for _, o in ipairs(e.out) do b.out[o[1]] = (b.out[o[1]] or 0) + o[2] end
        end
    end
    for _, key in ipairs(dorder) do
        local b = byItem[key]
        local parts, value = {}, 0
        for id, qty in pairs(b.out) do
            local v = P.AHValue(id)
            value = value + (v or 0) * 0.95 * qty
            parts[#parts + 1] = ("%s ×%d"):format(P.Name(id), qty)
        end
        Add((Tr("%s | %d disenchant(s) | got: %s | real value/DE %s | predicted %s")):format(key, b.n,
            table.concat(parts, ", "), M(value / b.n), M(b.predicted)))
    end
    if #dorder == 0 then Add("(no disenchant recorded yet: use the Disenchant window, /ipg de)") end
    return table.concat(lines, "\n")
end

function R.Show(days)
    ns.Craft.ShowText(R.Build(days))
end
