-- Item search: type part of a name, pick an item, its price history opens.
-- Searches the items that have a price on this realm (names saved by the scans), accents ignored.
local _, ns = ...
local Tr = ns.L

local SR = {}
ns.Search = SR
local MAX = 8

-- ------------------------------------------------------------ matching
-- Lower case and no accents: "Écaille" matches "ecaille". string.lower leaves UTF-8 letters alone.
local FOLD = {
    ["\195\160"] = "a", ["\195\161"] = "a", ["\195\162"] = "a", ["\195\164"] = "a", ["\195\167"] = "c",
    ["\195\168"] = "e", ["\195\169"] = "e", ["\195\170"] = "e", ["\195\171"] = "e", ["\195\174"] = "i",
    ["\195\175"] = "i", ["\195\177"] = "n", ["\195\180"] = "o", ["\195\182"] = "o", ["\195\185"] = "u",
    ["\195\187"] = "u", ["\195\188"] = "u", ["\195\159"] = "ss", ["\197\147"] = "oe",
}
function SR.Fold(s)
    s = (s or ""):lower()
    -- Upper-case Latin-1 letters (À..Þ, not ×) are 32 below their lower case.
    s = s:gsub("\195([\128-\158])", function(b)
        if b == "\151" then return "\195\151" end
        return "\195" .. string.char(b:byte() + 32)
    end)
    s = s:gsub("\197\146", "\197\147")
    return (s:gsub("[\195\197][\128-\191]", FOLD))
end

local folded = {}
local function Folded(name)
    local f = folded[name]
    if not f then f = SR.Fold(name); folded[name] = f end
    return f
end

-- Best matches first: exact name, then names starting with the text, then a word starting with it, then anywhere.
-- Shorter names first within a group ("Thick Leather" before "Thick Leather Ammo Pouch").
function SR.Find(query, n)
    local q = SR.Fold(query):gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return {} end
    local prices = ns.db.prices and ns.db.prices[ns.Realm()] or {}
    local hits = {}
    for id, name in pairs(ns.db.items or {}) do
        if prices[id] and type(name) == "string" and name ~= "" then
            local f = Folded(name)
            local at = f:find(q, 1, true)
            if at then
                local rank = (f == q) and 0 or (at == 1) and 1 or f:find(" " .. q, 1, true) and 2 or 3
                hits[#hits + 1] = { id = id, name = name, rank = rank }
            end
        end
    end
    table.sort(hits, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if #a.name ~= #b.name then return #a.name < #b.name end
        return a.name < b.name
    end)
    for i = #hits, (n or MAX) + 1, -1 do hits[i] = nil end
    return hits
end

-- Price now and change over the last 7 days (nil when unknown).
local function Trend(id)
    local st = ns.Prices.Stats(id)
    if not st or not st.cur then return nil end
    local first
    for k = 1, 7 do if st.spark and st.spark[k] then first = st.spark[k]; break end end
    return st.cur, first and first > 0 and (st.cur / first - 1) * 100 or nil
end
SR.Trend = Trend

-- ------------------------------------------------------------ window
local T = ns.Theme
local C = T.C
local ROW = 28
local box

local function PctText(v)
    if not v then return "" end
    local col = v > 0.5 and "|cff5cd173" or v < -0.5 and "|cffed5c52" or "|cff9a968e"
    return ("%s%s%d%%|r"):format(col, v > 0 and "+" or (v < 0 and "−" or ""), math.floor(math.abs(v) + 0.5))
end

local function Pick(id)
    if not id then return end
    if box then box:Hide() end
    ns.History.Show(id)
end

local function Highlight(f)
    for i, r in ipairs(f.rows) do r.hl:SetColor({ 1, 1, 1, (i == f.sel) and 0.07 or 0 }) end
end

local function Draw(f)
    local text = f.eb:GetText() or ""
    f.eb.hint:SetShown(text == "")
    local direct = tonumber(text) or tonumber(text:match("item:(%d+)"))
    local hits = direct and { { id = direct, name = ns.Prices.Name(direct) } } or SR.Find(text, MAX)
    f.hits, f.sel = hits, (#hits > 0) and 1 or nil
    for i, r in ipairs(f.rows) do
        local h = hits[i]
        if h then
            r.id = h.id
            r.icon:SetTexture(ns.GetItemIcon(h.id))
            r.name:SetText(h.name ~= "" and h.name or ("#" .. h.id))
            local cur, chg = Trend(h.id)
            r.price:SetText(cur and ns.FormatMoney(cur, { iconSize = 12 }) or "|cff615f5c—|r")
            r.chg:SetText(PctText(chg))
            r:Show()
        else
            r:Hide()
        end
    end
    local msg
    if text ~= "" and #hits == 0 then msg = Tr("No item with a price matches. Prices come from your AH scans.") end
    f.msg:SetText(msg or "")
    f.msg:SetShown(msg ~= nil)
    f:SetHeight(46 + #hits * ROW + (msg and 26 or 0) + (#hits > 0 and 6 or 0))
    Highlight(f)
end

local function Build()
    local f = CreateFrame("Frame", "ImpotPointGouvSearch", UIParent)
    f:SetSize(380, 46)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    T.Surface(f, C.window, 10, { 1, 1, 1, 0.12 })

    local eb = CreateFrame("EditBox", nil, f)
    eb:SetPoint("TOPLEFT", 9, -9); eb:SetPoint("TOPRIGHT", -9, -9); eb:SetHeight(28)
    eb:SetAutoFocus(false); eb:SetFontObject(ChatFontNormal); eb:SetTextInsets(28, 8, 0, 0)
    T.Surface(eb, C.surface2, 6)
    local mag = eb:CreateTexture(nil, "OVERLAY")
    mag:SetTexture("Interface\\Common\\UI-Searchbox-Icon"); mag:SetSize(14, 14); mag:SetPoint("LEFT", 9, -1)
    mag:SetVertexColor(0.7, 0.7, 0.7)
    eb.hint = T.Text(eb, 12, { color = C.faint, text = Tr("Item name, or shift-click an item") })
    eb.hint:SetPoint("LEFT", 28, 0)
    eb:SetScript("OnTextChanged", function() Draw(f) end)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    eb:SetScript("OnEnterPressed", function() local h = f.sel and f.hits[f.sel]; Pick(h and h.id) end)
    eb:SetScript("OnArrowPressed", function(_, key)
        local n = #(f.hits or {})
        if n == 0 then return end
        if key == "DOWN" then f.sel = (f.sel or 0) % n + 1 elseif key == "UP" then f.sel = ((f.sel or 1) - 2) % n + 1 end
        Highlight(f)
    end)
    f.eb = eb

    f.rows = {}
    for i = 1, MAX do
        local r = CreateFrame("Button", nil, f)
        r:SetHeight(ROW)
        r:SetPoint("TOPLEFT", 6, -42 - (i - 1) * ROW); r:SetPoint("TOPRIGHT", -6, -42 - (i - 1) * ROW)
        r.hl = T.Rounded(r, { 1, 1, 1, 0 }, 5, "BACKGROUND", 1)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(20, 20); r.icon:SetPoint("LEFT", 6, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.chg = T.Text(r, 11, { justify = "RIGHT" }); r.chg:SetPoint("RIGHT", -6, 0); r.chg:SetWidth(40)
        r.price = T.Text(r, 12, { justify = "RIGHT" }); r.price:SetPoint("RIGHT", r.chg, "LEFT", -6, 0)
        r.name = T.Text(r, 12); r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
        r.name:SetPoint("RIGHT", r.price, "LEFT", -8, 0)
        r:SetScript("OnEnter", function(self)
            f.sel = i; Highlight(f)
            T.ItemTooltip(self, self.id)
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:SetScript("OnClick", function(self) Pick(self.id) end)
        r:Hide()
        f.rows[i] = r
    end
    f.msg = T.Text(f, 11, { color = C.faint, wrap = true })
    f.msg:SetPoint("TOPLEFT", 14, -44); f.msg:SetPoint("TOPRIGHT", -14, -44)

    -- A click anywhere else closes it.
    f:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
    f:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN"); self.eb:ClearFocus(); GameTooltip:Hide()
    end)
    f:SetScript("OnEvent", function(self)
        if self:IsMouseOver() or (self.anchor and self.anchor:IsMouseOver()) then return end
        self:Hide()
    end)
    ns.Theme.CloseOnEscape(f)
    return f
end

-- Opens the search under a button (or in the middle of the screen), text cleared and ready to type.
function SR.Open(anchor, text)
    box = box or Build()
    box.anchor = anchor
    box:ClearAllPoints()
    if anchor then box:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4) else box:SetPoint("TOP", UIParent, "TOP", 0, -180) end
    box.eb:SetText(text or "")
    box:Show()
    box:Raise()
    box.eb:SetFocus()
    Draw(box)
end

function SR.Toggle(anchor)
    if box and box:IsShown() then box:Hide() else SR.Open(anchor) end
end

-- Shift-click an item (bags, chat, AH…) while typing: opens that item.
local function OnLink(link)
    if box and box:IsShown() and box.eb:HasFocus() and type(link) == "string" then
        local id = tonumber(link:match("item:(%d+)"))
        if id then Pick(id) end
    end
end
if hooksecurefunc then
    if type(ChatEdit_InsertLink) == "function" then hooksecurefunc("ChatEdit_InsertLink", OnLink) end
    if ChatFrameUtil and type(ChatFrameUtil.InsertLink) == "function" then hooksecurefunc(ChatFrameUtil, "InsertLink", OnLink) end
end
