-- ImpotPointGouv: value of everything you own (bags, banks, mail, listed, in transit, warband), all
-- characters: net AH (after the 5 % commission) or vendor price, the better of the two. Bound items are
-- worth the vendor price only. Shown by the Overview's "Stock value" card.
local _, ns = ...
local Tr = ns.L
local T, P, I = ns.Theme, ns.Prices, ns.Inventory
local C = T.C
local S = {}
ns.Stock = S

-- Value of one unit: price, source ("ah" | "vendor"), or nil if no price is known.
function S.Unit(id)
    local vs = P.VendorSell(id) or 0
    if I.IsBound(id) then
        if vs > 0 then return vs, "vendor" end
        return nil
    end
    local ah = P.AHValue(id)
    local net = ah and math.floor(ah * 0.95) or 0
    if net > 0 and net >= vs then return net, "ah" end
    if vs > 0 then return vs, "vendor" end
    return nil
end

-- Stock rows: { id, q (detail), unit, src, total }.
function S.Rows()
    local rows, total, n, unpriced = {}, 0, 0, 0
    for id, q in pairs(I.AllStock()) do
        local unit, src = S.Unit(id)
        local v = unit and unit * q.total or 0
        rows[#rows + 1] = { id = id, q = q, unit = unit, src = src, total = v }
        total = total + v
        n = n + q.total
        if not unit then unpriced = unpriced + 1 end
    end
    return rows, math.floor(total), n, unpriced
end

-- For the Overview card. Items with no price yet whose info the game has not loaded are requested,
-- so their vendor price arrives and the card catches up (see the redraw below).
function S.Value()
    local rows, total, n = S.Rows()
    for _, row in ipairs(rows) do
        if not row.unit and not ns.GetItemInfo(row.id) then ns.RequestItem(row.id) end
    end
    return total, n
end

-- ------------------------------------------------------------ page
local ROWS = 14
local FILTERS = { { "all", "All" }, { "ah", "AH value" }, { "vendor", "Vendor value" }, { "none", "No price" } }
local SORTS = {
    name  = function(a, b) return P.Name(a.id) < P.Name(b.id) end,
    qty   = function(a, b) if a.q.total ~= b.q.total then return a.q.total > b.q.total end return a.total > b.total end,
    unit  = function(a, b) if (a.unit or -1) ~= (b.unit or -1) then return (a.unit or -1) > (b.unit or -1) end return a.total > b.total end,
    total = function(a, b) if a.total ~= b.total then return a.total > b.total end return P.Name(a.id) < P.Name(b.id) end,
}

-- Names and vendor prices that arrive later, and inventory changes: redraw the Overview (its Stock
-- value card), at most every 2 s.
local function ShowsStock()
    local f = _G.ImpotPointGouvFrame
    local cur = ns.UI.Current and ns.UI.Current()
    return f and f:IsShown() and cur == "bilan"
end
local pend
local ev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(ev, "Stock") end
pcall(ev.RegisterEvent, ev, "GET_ITEM_INFO_RECEIVED")
local lastDraw = 0
ev:SetScript("OnEvent", function(_, _, id, success)
    -- Item doesn't exist, or the addon didn't ask for it: nothing to redraw.
    if success == false or pend or not ns.ItemWanted(id) then return end
    pend = true
    C_Timer.After(math.max(0.6, 2 - (GetTime() - lastDraw)), function()
        pend = false
        lastDraw = GetTime()
        if ShowsStock() then ns.UI.Refresh() end
    end)
end)
local invPend
ns.On("INVENTORY_CHANGED", function()
    if invPend or not ShowsStock() then return end
    invPend = true
    C_Timer.After(math.max(0.3, 2 - (GetTime() - lastDraw)), function()
        invPend = false
        lastDraw = GetTime()
        if ShowsStock() then ns.UI.Refresh() end
    end)
end)
