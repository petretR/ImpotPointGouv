-- ImpotPointGouv: visual theme (dark rounded panels, gold accent, Inter font).
local _, ns = ...
local Tr = ns.L
local T = {}
ns.Theme = T

T.C = {
    window   = { 0.051, 0.055, 0.063, 0.97 },
    header   = { 0.071, 0.075, 0.086, 1 },
    surface  = { 0.090, 0.094, 0.106, 1 },
    surface2 = { 0.125, 0.130, 0.145, 1 },
    hover    = { 0.165, 0.170, 0.188, 1 },
    border   = { 1, 1, 1, 0.07 },
    gold     = { 0.878, 0.659, 0.239, 1 },
    goldSoft = { 0.878, 0.659, 0.239, 0.16 },
    text     = { 0.925, 0.902, 0.839, 1 },
    muted    = { 0.580, 0.570, 0.545, 1 },
    faint    = { 0.380, 0.375, 0.360, 1 },
    pos      = { 0.361, 0.820, 0.451, 1 },
    neg      = { 0.929, 0.361, 0.322, 1 },
}

local WHITE = "Interface\\Buttons\\WHITE8X8"
local CIRCLE = ns.MEDIA .. "circle.tga"
local FONT_REG = ns.MEDIA .. "fonts\\Inter-Regular.ttf"
local FONT_SEMI = ns.MEDIA .. "fonts\\Inter-SemiBold.ttf"
T.WHITE, T.CIRCLE = WHITE, CIRCLE

-- ------------------------------------------------------------ text
function T.SetFont(fs, size, bold)
    local ok = fs:SetFont(bold and FONT_SEMI or FONT_REG, size, "")
    if ok == false then fs:SetFont(STANDARD_TEXT_FONT, size, "") end
    fs:SetShadowOffset(0, 0)
end

function T.Text(parent, size, opts)
    opts = opts or {}
    local fs = parent:CreateFontString(nil, opts.layer or "OVERLAY")
    T.SetFont(fs, size or 12, opts.bold)
    local c = opts.color or T.C.text
    fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    fs:SetJustifyH(opts.justify or "LEFT")
    if fs.SetWordWrap then fs:SetWordWrap(opts.wrap or false) end
    if opts.text then fs:SetText(opts.text) end
    return fs
end

-- ------------------------------------------------------------ rounded surfaces
-- A rounded rectangle = 4 quarter circles + 3 bands. No external texture.
local function RoundedLayer(frame, radius, layer, sub, inset)
    inset = inset or 0
    local parts = {}
    local function Tex()
        local t = frame:CreateTexture(nil, layer, nil, sub)
        parts[#parts + 1] = t
        return t
    end
    local r = radius
    local corners = {
        { "TOPLEFT", 0, 0.5, 0, 0.5, inset, -inset },
        { "TOPRIGHT", 0.5, 1, 0, 0.5, -inset, -inset },
        { "BOTTOMLEFT", 0, 0.5, 0.5, 1, inset, inset },
        { "BOTTOMRIGHT", 0.5, 1, 0.5, 1, -inset, inset },
    }
    for _, c in ipairs(corners) do
        local t = Tex()
        t:SetTexture(CIRCLE)
        t:SetTexCoord(c[2], c[3], c[4], c[5])
        t:SetSize(r, r)
        t:SetPoint(c[1], frame, c[1], c[6], c[7])
    end
    local top = Tex(); top:SetTexture(WHITE)
    top:SetPoint("TOPLEFT", frame, "TOPLEFT", inset + r, -inset)
    top:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -inset - r, -inset - r)
    local bottom = Tex(); bottom:SetTexture(WHITE)
    bottom:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", inset + r, inset + r)
    bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset - r, inset)
    local mid = Tex(); mid:SetTexture(WHITE)
    mid:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset - r)
    mid:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset + r)
    local obj = { parts = parts }
    function obj:SetColor(c)
        for _, t in ipairs(parts) do t:SetVertexColor(c[1], c[2], c[3], c[4] or 1) end
    end
    function obj:SetShown(v) for _, t in ipairs(parts) do t:SetShown(v) end end
    return obj
end

-- Rounded background with a 1 px border. Returns the "fill" object (to change the color on hover).
function T.Surface(frame, color, radius, borderColor)
    radius = radius or 8
    local border = RoundedLayer(frame, radius, "BACKGROUND", -8, 0)
    border:SetColor(borderColor or T.C.border)
    local fill = RoundedLayer(frame, radius - 1, "BACKGROUND", -7, 1)
    fill:SetColor(color or T.C.surface)
    frame.ipgBorder, frame.ipgFill = border, fill
    return fill, border
end

function T.Rounded(frame, color, radius, layer, sub)
    local o = RoundedLayer(frame, radius or 6, layer or "ARTWORK", sub or 0, 0)
    o:SetColor(color)
    return o
end

-- ------------------------------------------------------------ buttons
-- style: "ghost" (subtle background) | "pill" (selection segment) | "primary" (gold)
function T.Button(parent, label, width, height, onClick, style)
    style = style or "ghost"
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width or 90, height or 24)
    local base = style == "primary" and T.C.gold or T.C.surface2
    local fill = T.Surface(b, base, math.floor((height or 24) / 2) < 8 and math.floor((height or 24) / 2) or 7)
    b.text = T.Text(b, 12, { bold = style ~= "ghost", justify = "CENTER",
        color = style == "primary" and { 0.08, 0.07, 0.05, 1 } or T.C.text })
    b.text:SetPoint("CENTER", 0, 0)
    -- The translated text may be longer: the button widens if needed (never shrinks).
    local setText = b.text.SetText
    b.text.SetText = function(self, t)
        setText(self, t)
        local w = (self:GetStringWidth() or 0) + 18
        if w > b:GetWidth() then b:SetWidth(w) end
    end
    b.text:SetText(label)
    b.selected = false
    function b:Refresh()
        if self.disabled then
            fill:SetColor(T.C.surface); self.text:SetTextColor(unpack(T.C.faint)); return
        end
        if style == "primary" then
            fill:SetColor(self.hover and { 0.95, 0.74, 0.32, 1 } or T.C.gold)
        elseif self.selected then
            -- Opaque background (otherwise the gold border, drawn below, shows through and hides the gold text).
            fill:SetColor({ 0.235, 0.200, 0.125, 1 }); self.ipgBorder:SetColor({ T.C.gold[1], T.C.gold[2], T.C.gold[3], 0.55 })
            self.text:SetTextColor(unpack(T.C.gold)); return
        else
            fill:SetColor(self.hover and T.C.hover or T.C.surface2)
        end
        self.ipgBorder:SetColor(T.C.border)
        if style ~= "primary" then self.text:SetTextColor(unpack(T.C.text)) end
    end
    function b:SetSelected(v) self.selected = v; self:Refresh() end
    function b:SetDisabled(v) self.disabled = v; self:Refresh() end
    b:SetScript("OnEnter", function(self)
        self.hover = true; self:Refresh()
        if self.tooltip then
            -- Tooltip on the free side: below the button if it is at the top of the screen, above otherwise (never over the bar).
            local _, y = self:GetCenter()
            local top = y and UIParent:GetHeight() and y > UIParent:GetHeight() * 0.5
            GameTooltip:SetOwner(self, top and "ANCHOR_BOTTOM" or "ANCHOR_TOP")
            GameTooltip:AddLine(self.tooltip, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self) self.hover = false; self:Refresh(); GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self, ...)
        if self.disabled then return end
        if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
        if onClick then onClick(self, ...) end
    end)
    b:Refresh()
    return b
end

-- Tab in a "title + gold underline" style.
function T.Tab(parent, label, onClick)
    local b = CreateFrame("Button", nil, parent)
    b.text = T.Text(b, 13, { bold = true, color = T.C.muted })
    b.text:SetPoint("CENTER", 0, 1)
    b.text:SetText(label)
    b:SetSize(b.text:GetStringWidth() + 28, 44)
    b.line = b:CreateTexture(nil, "OVERLAY")
    b.line:SetTexture(WHITE)
    b.line:SetVertexColor(unpack(T.C.gold))
    b.line:SetHeight(2)
    b.line:SetPoint("BOTTOMLEFT", 12, 0)
    b.line:SetPoint("BOTTOMRIGHT", -12, 0)
    b.line:Hide()
    function b:SetSelected(v)
        self.selected = v
        self.line:SetShown(v)
        local c = v and T.C.text or (self.disabled and T.C.faint or T.C.muted)
        self.text:SetTextColor(c[1], c[2], c[3])
    end
    b:SetScript("OnEnter", function(self)
        if not self.selected and not self.disabled then self.text:SetTextColor(unpack(T.C.text)) end
        if self.tooltip then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(self.tooltip, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self) self:SetSelected(self.selected); GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self) if not self.disabled and onClick then onClick(self) end end)
    b:SetSelected(false)
    return b
end

function T.Divider(parent, alpha)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetTexture(WHITE)
    t:SetVertexColor(1, 1, 1, alpha or 0.06)
    t:SetHeight(1)
    return t
end

-- Close button (drawn cross).
function T.CloseButton(parent, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(28, 28)
    local bg = T.Rounded(b, { 1, 1, 1, 0 }, 6, "BACKGROUND")
    local function Bar(angle)
        local l = b:CreateLine(nil, "ARTWORK")
        l:SetThickness(1.6)
        l:SetColorTexture(1, 1, 1, 1)
        local d = 5
        l:SetStartPoint("CENTER", b, -d * angle, -d)
        l:SetEndPoint("CENTER", b, d * angle, d)
        l:SetVertexColor(unpack(T.C.muted))
        return l
    end
    local l1, l2 = Bar(1), Bar(-1)
    b:SetScript("OnEnter", function()
        bg:SetColor({ T.C.neg[1], T.C.neg[2], T.C.neg[3], 0.18 })
        l1:SetVertexColor(unpack(T.C.text)); l2:SetVertexColor(unpack(T.C.text))
    end)
    b:SetScript("OnLeave", function()
        bg:SetColor({ 1, 1, 1, 0 })
        l1:SetVertexColor(unpack(T.C.muted)); l2:SetVertexColor(unpack(T.C.muted))
    end)
    b:SetScript("OnClick", onClick)
    return b
end

-- Small color dot (category).
function T.Dot(parent, size, color)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetTexture(CIRCLE)
    t:SetSize(size, size)
    t:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
    return t
end

-- Item tooltip (like in the bags) on hover.
function T.ItemTooltip(owner, id, anchor)
    if not id then return false end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    if GameTooltip.SetItemByID then
        GameTooltip:SetItemByID(id)
    else
        GameTooltip:SetHyperlink("item:" .. id)
    end
    return true
end

-- Same rule for hand-made tooltips.
function T.TooltipAnchor(owner)
    local _, y = owner:GetCenter()
    local top = y and UIParent:GetHeight() and y > UIParent:GetHeight() * 0.5
    return top and "ANCHOR_BOTTOM" or "ANCHOR_TOP"
end

-- ------------------------------------------------------------ Esc and dialogs without Blizzard's tables
-- On this client, writing into Blizzard's own tables (UISpecialFrames, StaticPopupDialogs) or showing a
-- StaticPopup from an addon taints the game's code: the Esc menu, logout and confirmations such as
-- buying a bank tab then fail with "AddOn tried to call the protected function". So the addon closes its
-- windows on Esc by itself, and has its own small dialog.
local escPending = {}
local function EscapeNow(f)
    f:EnableKeyboard(true)
    f:SetPropagateKeyboardInput(true)
    f:SetScript("OnKeyDown", function(self, key)
        if InCombatLockdown() then return end -- in combat keys always go through (the game's rule)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
            -- Give the keyboard back once this key press is over.
            C_Timer.After(0, function() if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end end)
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
end
local escWatch
function T.CloseOnEscape(f)
    if not InCombatLockdown() then EscapeNow(f); return end
    escPending[#escPending + 1] = f
    if not escWatch then
        escWatch = CreateFrame("Frame")
        escWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
        escWatch:SetScript("OnEvent", function()
            for _, p in ipairs(escPending) do EscapeNow(p) end
            wipe(escPending)
        end)
    end
end

-- T.Dialog{ text = "...", input = true|nil, default = "", accept = "OK", cancel = "Cancel", onAccept = fn(text) }
local dialog
function T.Dialog(o)
    if not dialog then
        local d = CreateFrame("Frame", "ImpotPointGouvDialog", UIParent)
        d:SetSize(360, 150); d:SetPoint("CENTER", 0, 120)
        d:SetFrameStrata("DIALOG"); d:SetToplevel(true); d:EnableMouse(true); d:SetClampedToScreen(true)
        T.Surface(d, T.C.window, 12, { 1, 1, 1, 0.12 })
        d.text = T.Text(d, 13, { justify = "CENTER", wrap = true })
        d.text:SetPoint("TOPLEFT", 18, -18); d.text:SetPoint("TOPRIGHT", -18, -18)
        local eb = CreateFrame("EditBox", nil, d)
        eb:SetSize(300, 26); eb:SetPoint("TOP", d.text, "BOTTOM", 0, -12)
        eb:SetAutoFocus(false); eb:SetFontObject(ChatFontNormal); eb:SetTextInsets(8, 8, 0, 0)
        T.Surface(eb, T.C.surface2, 6)
        eb:SetScript("OnEnterPressed", function() d.ok:Click() end)
        eb:SetScript("OnEscapePressed", function() d:Hide() end)
        d.eb = eb
        d.ok = T.Button(d, "", 130, 30, function()
            local fn, text = d.onAccept, d.eb:IsShown() and d.eb:GetText() or nil
            d:Hide()
            if fn then fn(text) end
        end, "primary")
        d.ok:SetPoint("BOTTOMRIGHT", d, "BOTTOM", -4, 14)
        d.cancel = T.Button(d, "", 130, 30, function() d:Hide() end)
        d.cancel:SetPoint("BOTTOMLEFT", d, "BOTTOM", 4, 14)
        d:SetScript("OnHide", function() d.eb:ClearFocus() end)
        T.CloseOnEscape(d)
        d:Hide()
        dialog = d
    end
    local d = dialog
    d.text:SetText(o.text or "")
    d.ok.text:SetText(o.accept or OKAY or "OK")
    d.cancel.text:SetText(o.cancel or CANCEL or "Cancel")
    d.onAccept = o.onAccept
    d.eb:SetShown(o.input and true or false)
    d.eb:SetText(o.default or "")
    d:SetHeight(o.input and 150 or 120)
    d:Show(); d:Raise()
    if o.input then d.eb:SetFocus(); d.eb:HighlightText() end
    return d
end
