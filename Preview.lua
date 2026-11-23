-- ImpotPointGouv: preview before a batch action (sending, selling to a vendor, buying from a vendor).
-- A checklist, a total and a confirm button: nothing goes out without you seeing it.
local _, ns = ...
local Tr = ns.L
local T = ns.Theme
local C = T.C
local PV = {}
ns.Preview = PV

local ROWS = 10
local win

local function Build()
    win = CreateFrame("Frame", "ImpotPointGouvPreview", UIParent)
    win:SetSize(380, 108 + ROWS * 28)
    win:SetPoint("CENTER", 0, 60)
    win:SetFrameStrata("DIALOG")
    win:SetToplevel(true)
    win:SetClampedToScreen(true)
    win:SetMovable(true); win:EnableMouse(true); win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing)
    T.Surface(win, C.window, 14, { C.gold[1], C.gold[2], C.gold[3], 0.4 })
    win.title = T.Text(win, 15, { bold = true }); win.title:SetPoint("TOPLEFT", 16, -14)
    win.sub = T.Text(win, 11, { color = C.muted }); win.sub:SetPoint("TOPLEFT", 16, -34)
    local close = T.CloseButton(win, function() win:Hide() end); close:SetPoint("TOPRIGHT", -8, -10)
    win.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, win)
        r:SetHeight(26)
        r:SetPoint("TOPLEFT", 12, -54 - (i - 1) * 28); r:SetPoint("TOPRIGHT", -12, -54 - (i - 1) * 28)
        r.hl = T.Rounded(r, { 1, 1, 1, 0 }, 6, "BACKGROUND", 1)
        r.box = r:CreateTexture(nil, "ARTWORK"); r.box:SetTexture(T.WHITE); r.box:SetVertexColor(1, 1, 1, 0.1)
        r.box:SetSize(16, 16); r.box:SetPoint("LEFT", 6, 0)
        r.check = r:CreateTexture(nil, "OVERLAY"); r.check:SetSize(16, 16); r.check:SetPoint("CENTER", r.box, "CENTER")
        r.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(20, 20); r.icon:SetPoint("LEFT", 30, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.name = T.Text(r, 12); r.name:SetPoint("LEFT", 56, 0); r.name:SetWidth(200)
        r.qty = T.Text(r, 12, { bold = true, justify = "RIGHT" }); r.qty:SetPoint("RIGHT", -8, 0)
        r.extra = T.Text(r, 11, { color = C.muted, justify = "RIGHT" }); r.extra:SetPoint("RIGHT", r.qty, "LEFT", -10, 0)
        r:SetScript("OnClick", function(self)
            if not self.row then return end
            self.row.checked = not self.row.checked
            PV.Draw()
        end)
        r:SetScript("OnEnter", function(self)
            self.hl:SetColor({ 1, 1, 1, 0.045 })
            if self.row and self.row.id then T.ItemTooltip(self, self.row.id) end
        end)
        r:SetScript("OnLeave", function(self) self.hl:SetColor({ 1, 1, 1, 0 }); GameTooltip:Hide() end)
        win.rows[i] = r
    end
    win.offset = 0
    win:EnableMouseWheel(true)
    win:SetScript("OnMouseWheel", function(_, d)
        win.offset = math.max(0, math.min(math.max(0, #(win.data or {}) - ROWS), win.offset - d))
        PV.Draw()
    end)
    win.total = T.Text(win, 12, { color = C.text }); win.total:SetPoint("BOTTOMLEFT", 16, 22)
    win.ok = T.Button(win, Tr("Confirm"), 150, 32, function()
        local chosen = {}
        for _, row in ipairs(win.data or {}) do if row.checked then chosen[#chosen + 1] = row end end
        win:Hide()
        if #chosen > 0 and win.onConfirm then win.onConfirm(chosen) end
    end, "primary")
    win.ok:SetPoint("BOTTOMRIGHT", -12, 12)
    tinsert(UISpecialFrames, "ImpotPointGouvPreview")
    win:Hide()
end

-- rows = { { id, qty, label?, extra?, value? (cuivre), checked? }, ... }
-- opts = { title, sub, confirm (label), total = function(chosenRows) -> text }
function PV.Show(rows, opts, onConfirm)
    if not rows or #rows == 0 then return false end
    if not win then Build() end
    for _, r in ipairs(rows) do if r.checked == nil then r.checked = true end end
    win.data, win.opts, win.onConfirm = rows, opts or {}, onConfirm
    win.offset = 0
    win.title:SetText(win.opts.title or "Confirm")
    win.sub:SetText(win.opts.sub or "Uncheck what you want to keep.")
    win:Show(); win:Raise()
    PV.Draw()
    return true
end

function PV.Draw()
    if not win or not win:IsShown() then return end
    local data = win.data or {}
    for i, r in ipairs(win.rows) do
        local row = data[win.offset + i]
        r.row = row
        if row then
            r.check:SetShown(row.checked)
            r.icon:SetTexture(row.icon or (row.id and ns.GetItemIcon(row.id)) or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.name:SetText(row.label or (row.id and ns.Prices.Name(row.id)) or "?")
            r.qty:SetText("×" .. (row.qty or 1))
            r.extra:SetText(row.extra or (row.value and ns.FormatMoney(row.value, { iconSize = 10, short = true })) or "")
            r:SetAlpha(row.checked and 1 or 0.45)
            r:Show()
        else
            r:Hide()
        end
    end
    local n, items, value = 0, 0, 0
    for _, row in ipairs(data) do
        if row.checked then n = n + 1; items = items + (row.qty or 1); value = value + (row.value or 0) end
    end
    local txt = win.opts.total and win.opts.total(n, items, value)
        or ((Tr("%d item%s")):format(items, items == 1 and "" or "s") .. (value > 0 and ("  ·  " .. ns.FormatMoney(value, { iconSize = 11 })) or ""))
    win.total:SetText(txt)
    win.ok.text:SetText(win.opts.confirm or "Confirm")
    win.ok:SetDisabled(n == 0)
end
