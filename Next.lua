-- ImpotPointGouv : raccourci "Next action" — crafte le prochain objet de la file, sinon désenchante le suivant.
-- Un bouton sécurisé invisible, réglé hors combat sur la prochaine action ; le raccourci clique dessus.
local _, ns = ...
local N = {}
ns.Next = N

_G["BINDING_NAME_CLICK ImpotPointGouvNextButton:LeftButton"] = "Next action (craft / disenchant)"

local button = CreateFrame("Button", "ImpotPointGouvNextButton", UIParent, "SecureActionButtonTemplate")
button:SetSize(1, 1)
button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)
button:RegisterForClicks("AnyUp", "AnyDown")
button:Show()

N.action = nil -- "craft" | "de" | nil

function N.Arm()
    if InCombatLockdown() or not ns.db then return end
    local action, macro
    if ns.Queue and ns.Queue.NextCraftable then
        local c, count = ns.Queue.NextCraftable()
        if c then
            action = "craft"
            macro = "/run ImpotPointGouv.Queue.CraftNext()"
            N.label = ("craft %s ×%d"):format(c.name, count)
        end
    end
    -- Désenchantement seulement quand la fenêtre Disenchant est ouverte.
    if not action and ns.Destroy and ns.Destroy.NextTarget and ns.Destroy.IsShown() then
        local it, spell = ns.Destroy.NextTarget()
        if it and spell then
            action = "de"
            macro = ("/cast %s\n/use %d %d"):format(spell, it.bag, it.slot)
            N.label = "disenchant " .. (it.name or "?")
        end
    end
    N.action = action
    if action then
        button:SetAttribute("type", "macro")
        button:SetAttribute("macrotext", macro)
    else
        button:SetAttribute("type", nil)
        button:SetAttribute("macrotext", nil)
        N.label = nil
    end
end

function N.Key()
    return GetBindingKey and GetBindingKey("CLICK ImpotPointGouvNextButton:LeftButton")
end

-- Réarme après chaque changement pertinent (sacs, file, craft, désenchantement, sortie de combat).
local queued
local function Queue()
    if queued then return end
    queued = true
    C_Timer.After(0.3, function() queued = false; N.Arm() end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "PLAYER_REGEN_ENABLED", "TRADE_SKILL_SHOW",
    "TRADE_SKILL_CLOSE", "TRADE_SKILL_LIST_UPDATE", "UNIT_SPELLCAST_SUCCEEDED", "LOOT_CLOSED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, unit)
    if event == "UNIT_SPELLCAST_SUCCEEDED" and unit ~= "player" then return end
    Queue()
end)
ns.On("INVENTORY_CHANGED", Queue)
ns.On("PRICES_CHANGED", Queue)
ns.On("DE_LOGGED", Queue)
