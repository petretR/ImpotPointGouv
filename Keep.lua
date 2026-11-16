-- ImpotPointGouv : "garder en sac" (équivalent du Keep Quantity de TSM), par objet.
-- Utilisé par l'envoi à la banque (n'envoie que l'excédent) et par Queue profitable (réserve perso hors stock à vendre).
local _, ns = ...
local T = ns.Theme
local C = T.C
local K = {}
ns.Keep = K

local function DB() ns.db.settings.keep = ns.db.settings.keep or {}; return ns.db.settings.keep end
function K.Get(id) return id and DB()[id] or 0 end
function K.Set(id, n)
    if not id then return end
    n = math.max(0, math.floor(n or 0))
    DB()[id] = n > 0 and n or nil
    ns.Fire("KEEP_CHANGED")
    if ns.Queue then ns.Queue.Refresh() end
end

local pop
local function Build()
    pop = CreateFrame("Frame", "ImpotPointGouvKeep", UIParent)
    pop:SetSize(300, 118)
    pop:SetFrameStrata("DIALOG")
    pop:SetClampedToScreen(true)
    pop:EnableMouse(true)
    T.Surface(pop, C.window, 10, { C.gold[1], C.gold[2], C.gold[3], 0.45 })
    pop.icon = pop:CreateTexture(nil, "ARTWORK"); pop.icon:SetSize(22, 22); pop.icon:SetPoint("TOPLEFT", 12, -10)
    pop.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    pop.name = T.Text(pop, 12, { bold = true }); pop.name:SetPoint("LEFT", pop.icon, "RIGHT", 8, 0); pop.name:SetWidth(200)
    local close = T.CloseButton(pop, function() pop:Hide() end); close:SetPoint("TOPRIGHT", -6, -6)
    local lbl = T.Text(pop, 11, { color = C.muted, text = "Keep in bags (not sent, not counted for sale)" })
    lbl:SetPoint("TOPLEFT", 12, -40)
    pop.value = T.Text(pop, 18, { bold = true, justify = "CENTER" })
    pop.value:SetPoint("TOP", 0, -58); pop.value:SetWidth(60)
    local steps = { -20, -5, -1, 1, 5, 20 }
    local x0 = 12
    for i, st in ipairs(steps) do
        local b = T.Button(pop, (st > 0 and "+" or "−") .. math.abs(st), 40, 22, function()
            K.Set(pop.id, K.Get(pop.id) + st); pop.value:SetText(K.Get(pop.id))
        end)
        local x = i <= 3 and (x0 + (i - 1) * 44) or (300 - 12 - 40 - (6 - i) * 44)
        b:SetPoint("TOPLEFT", x, -88)
    end
    pop:Hide()
    tinsert(UISpecialFrames, "ImpotPointGouvKeep")
end

function K.Edit(id, anchor)
    if not id then return end
    if not pop then Build() end
    pop.id = id
    pop.icon:SetTexture(ns.GetItemIcon(id) or "Interface\\Icons\\INV_Misc_QuestionMark")
    pop.name:SetText(ns.Prices.Name(id))
    pop.value:SetText(K.Get(id))
    pop:ClearAllPoints()
    if anchor then pop:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4) else pop:SetPoint("CENTER") end
    pop:Show()
end

-- Bouton visible "garder en sac" pour les lignes de liste : icône sac + quantité gardée.
local BAG = "Interface\\Icons\\INV_Misc_Bag_08"
function K.Button(parent)
    local b = T.Button(parent, "", 44, 18, function(self) if self.id then K.Edit(self.id, self) end end)
    b.bag = b:CreateTexture(nil, "OVERLAY"); b.bag:SetSize(12, 12); b.bag:SetPoint("LEFT", 5, 0)
    b.bag:SetTexture(BAG); b.bag:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.text:ClearAllPoints(); b.text:SetPoint("LEFT", b.bag, "RIGHT", 4, 0); T.SetFont(b.text, 11, true)
    function b:SetItem(id)
        self.id = id
        local n = K.Get(id)
        self.text:SetText(n > 0 and tostring(n) or "+")
        self.bag:SetDesaturated(n == 0); self.bag:SetAlpha(n > 0 and 1 or 0.55)
        self.tooltip = n > 0 and ("Keeping %d in your bags (not mailed to the bank, not counted as stock to sell). Click to change."):format(n)
            or "Keep some in your bags for yourself (not mailed to the bank, not counted as stock to sell)."
        self:SetShown(id ~= nil)
    end
    return b
end
