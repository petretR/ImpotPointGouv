-- ImpotPointGouv : guide de démarrage. Liste ce qui manque pour que tout marche (rôles, métiers,
-- noms complets, prix, raccourci) et l'affiche dans un bandeau tant qu'il reste des étapes.
local _, ns = ...
local T = ns.Theme
local C = T.C
local S = {}
ns.Setup = S

local function CharLabel(key)
    local c = key and ns.db.chars[key]
    return c and (c.full or c.name) or "?"
end

local function HasPrices()
    for r, list in pairs(ns.db.prices or {}) do
        if type(list) == "table" and next(list) then return true end
    end
    return false
end

local win
-- Ouvre la page Characters au premier plan (le guide se ferme, sinon il la cache).
local function OpenChars()
    if win then win:Hide() end
    ns.UI.Toggle("chars")
end

local NEXT = "CLICK ImpotPointGouvNextButton:LeftButton"
local DESTROY = "CLICK ImpotPointGouvDestroyButton:LeftButton"
-- Déplace la touche de "Disenchant next item" vers "Next action" (qui crafte puis désenchante).
local function MoveKey()
    if InCombatLockdown and InCombatLockdown() then return end
    local key = GetBindingKey and GetBindingKey(DESTROY)
    if not key or not SetBinding then return end
    SetBinding(key, NEXT)
    if SaveBindings and GetCurrentBindingSet then SaveBindings(GetCurrentBindingSet()) end
    ns.Print(("key %s now runs Next action (craft, then disenchant when that window is open)."):format(key))
    if ns.Next then ns.Next.Arm() end
    S.Refresh()
end

-- Chaque étape : { done = bool, text = "...", how = "..." , go = fonction optionnelle }
function S.Steps()
    local st = ns.db.settings
    local steps = {}
    local function Add(done, text, how, go) steps[#steps + 1] = { done = done, text = text, how = how, go = go } end

    local crafters = ns.Queue and ns.Queue.Crafters() or {}
    local crafter = crafters[1]
    local bank = st.bankChar
    Add(#crafters > 0, "Pick your crafter(s)",
        "Characters page: click \"Crafter\" on each character who crafts (several allowed).", OpenChars)
    Add(bank and ns.db.chars[bank] and true or false, "Pick your bank",
        "Characters page: click \"Bank\" on the character who buys and sells at the AH.", OpenChars)

    for _, crafter in ipairs(crafters) do
        local c = ns.db.chars[crafter]
        if not c.profs then
            Add(false, "Log in once on " .. CharLabel(crafter), "So the addon can see its professions.")
        else
            for _, p in ipairs(c.profs) do
                if not p.gather then
                    local seen = ns.db.profChars and ns.db.profChars[p.name] and ns.db.profChars[p.name][crafter]
                    Add(seen and true or false, ("Open %s once on %s"):format(p.name, CharLabel(crafter)),
                        "Open the profession window so the addon reads your recipes.")
                end
            end
        end
    end
    local roleKeys = {}
    if bank then roleKeys[1] = bank end
    for _, k in ipairs(crafters) do roleKeys[#roleKeys + 1] = k end
    for _, key in ipairs(roleKeys) do
        local c = key and ns.db.chars[key]
        if c and not c.full then
            Add(false, "Full name of " .. (c.name or "?"),
                "On that character, open the character sheet (C) once: mail needs first + last name.")
        end
    end
    Add(HasPrices(), "Scan the auction house once",
        "At the AH, click Scan in the ImpotPointGouv bar (any character).")
    local nextKey = ns.Next and ns.Next.Key()
    local deKey = GetBindingKey and GetBindingKey(DESTROY)
    if not nextKey and deKey then
        Add(false, ("Your key %s only disenchants"):format(deKey),
            "Click here to move it to Next action: it crafts your queue, then disenchants when that window is open.", MoveKey)
    else
        Add(nextKey and true or false, "Set the \"Next action\" key",
            "Click here, then AddOns > ImpotPointGouv: one key crafts the queue, then disenchants.",
            function()
                if win then win:Hide() end
                if Settings and Settings.OpenToCategory and Settings.KEYBINDINGS_CATEGORY_ID then
                    pcall(Settings.OpenToCategory, Settings.KEYBINDINGS_CATEGORY_ID)
                end
            end)
    end
    return steps
end

function S.Remaining()
    local n = 0
    for _, s in ipairs(S.Steps()) do if not s.done then n = n + 1 end end
    return n
end

-- ------------------------------------------------------------ fenêtre
local function Build()
    win = CreateFrame("Frame", "ImpotPointGouvSetup", UIParent)
    win:SetSize(420, 120)
    win:SetPoint("CENTER", 0, 80)
    win:SetFrameStrata("DIALOG")
    win:SetClampedToScreen(true)
    win:SetMovable(true); win:EnableMouse(true); win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing)
    T.Surface(win, C.window, 14, { C.gold[1], C.gold[2], C.gold[3], 0.4 })
    local icon = win:CreateTexture(nil, "ARTWORK"); icon:SetTexture(ns.MEDIA .. "icon.tga"); icon:SetSize(24, 24)
    icon:SetPoint("TOPLEFT", 14, -12)
    local title = T.Text(win, 15, { bold = true, text = "Setup" }); title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    win.sub = T.Text(win, 11, { color = C.muted }); win.sub:SetPoint("LEFT", title, "RIGHT", 10, -1)
    local close = T.CloseButton(win, function() win:Hide() end); close:SetPoint("TOPRIGHT", -8, -10)
    win.rows = {}
    win.chars = T.Button(win, "Characters", 110, 26, function()
        if S.Remaining() == 0 then win:Hide() else OpenChars() end
    end, "primary")
    win.chars:SetPoint("BOTTOMRIGHT", -12, 12)
    tinsert(UISpecialFrames, "ImpotPointGouvSetup")
    win:SetScript("OnShow", function() S.Refresh() end)
    win:Hide()
end

local function Row(i)
    local r = win.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, win)
    r:SetHeight(40)
    r:SetPoint("TOPLEFT", 12, -48 - (i - 1) * 44); r:SetPoint("TOPRIGHT", -12, -48 - (i - 1) * 44)
    T.Surface(r, C.surface, 8)
    r.mark = T.Text(r, 14, { bold = true, justify = "CENTER" }); r.mark:SetPoint("LEFT", 10, 0); r.mark:SetWidth(18)
    r.text = T.Text(r, 12, { bold = true }); r.text:SetPoint("TOPLEFT", 36, -6)
    r.how = T.Text(r, 10, { color = C.muted }); r.how:SetPoint("TOPLEFT", 36, -22); r.how:SetPoint("RIGHT", -10, 0)
    r.how:SetWordWrap(false)
    r:SetScript("OnClick", function(self) if self.step and not self.step.done and self.step.go then self.step.go() end end)
    r:SetScript("OnEnter", function(self)
        if not self.step or self.step.done then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self.step.text, 1, 1, 1)
        GameTooltip:AddLine(self.step.how, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    win.rows[i] = r
    return r
end

function S.Refresh()
    if win and win:IsShown() then
        local steps = S.Steps()
        local left = 0
        for i, st in ipairs(steps) do
            local r = Row(i)
            r.step = st
            r.mark:SetText(st.done and "|cff5cd173✓|r" or "|cffe0a83d•|r")
            r.text:SetText(st.text); r.text:SetTextColor(unpack(st.done and C.faint or C.text))
            r.how:SetText(st.done and "" or st.how)
            r:Show()
            if not st.done then left = left + 1 end
        end
        for i = #steps + 1, #win.rows do win.rows[i]:Hide() end
        win:SetHeight(48 + #steps * 44 + 50)
        win.sub:SetText(left == 0 and "|cff5cd173all set|r" or (left .. (left > 1 and " steps left" or " step left")))
        -- Tout est prêt : le bouton ferme simplement le guide.
        win.chars.text:SetText(left == 0 and "Done" or "Characters")
        win.chars.tooltip = left == 0 and nil or "Roles and professions of all your characters."
    end
    S.UpdateBanners()
end

function S.Show()
    if not win then Build() end
    win:Show()
    win:Raise()
    S.Refresh()
end

-- ------------------------------------------------------------ bandeaux
local banners = {}
function S.AttachBanner(frame)
    if not frame or banners[frame] then return end
    local b = CreateFrame("Button", nil, frame)
    b:SetHeight(26)
    b:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 10, 2); b:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -10, 2)
    T.Surface(b, { 0.20, 0.15, 0.06, 0.96 }, 8, { C.gold[1], C.gold[2], C.gold[3], 0.5 })
    b.text = T.Text(b, 11, { bold = true, color = C.gold }); b.text:SetPoint("LEFT", 12, 0)
    local go = T.Text(b, 11, { color = C.text, text = "Finish setup ›" }); go:SetPoint("RIGHT", -12, 0)
    b:SetScript("OnClick", S.Show)
    banners[frame] = b
    S.UpdateBanners()
end

function S.UpdateBanners()
    if not ns.db then return end
    local n = S.Remaining()
    for _, b in pairs(banners) do
        b.text:SetText(("Setup: %d step%s left"):format(n, n > 1 and "s" or ""))
        b:SetShown(n > 0)
    end
end

local pending
local function Later()
    if pending then return end
    pending = true
    C_Timer.After(0.5, function() pending = false; S.Refresh() end)
end
for _, e in ipairs({ "CHARS_CHANGED", "PRICES_CHANGED", "QUEUE_CHANGED", "LEDGER_READY", "INVENTORY_CHANGED" }) do
    ns.On(e, Later)
end
local ev = CreateFrame("Frame")
for _, e in ipairs({ "UPDATE_BINDINGS", "TRADE_SKILL_SHOW", "PLAYER_ENTERING_WORLD" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", Later)
