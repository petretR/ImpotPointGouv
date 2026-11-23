-- Minimal WoW API stubs, enough to load the addon outside the game and drive its pages.
-- Lua 5.1 (same as the game client). Frames are tables that accept any method call.

unpack = unpack or table.unpack
strmatch = string.match
tinsert, tremove = table.insert, table.remove
math.log10 = math.log10 or function(x) return math.log(x) / math.log(10) end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
securecallfunction = function(f, ...) return f(...) end
geterrorhandler = function() return function(e) error(e, 2) end end

-- Virtual clock: GetTime() and time() only move when Advance() is called.
local clock, now = 1000, 1795000000
function GetTime() return clock end
function time() return now end
date = function(f, t) return os.date(f, t and math.floor(t)) end
function Advance(s) clock = clock + s; now = now + s end
debugprofilestop = function() return clock * 1000 end
GetFramerate = function() return 60 end

-- Timers are queued and run by RunTimers(seconds), in time order.
local queue = {}
C_Timer = {
    After = function(d, f) queue[#queue + 1] = { t = clock + (d or 0), f = f } end,
    NewTicker = function() return { Cancel = function() end } end,
    NewTimer = function(d, f) queue[#queue + 1] = { t = clock + (d or 0), f = f }; return { Cancel = function() end } end,
}
function RunTimers(seconds)
    local limit = clock + seconds
    while #queue > 0 do
        table.sort(queue, function(a, b) return a.t < b.t end)
        local e = table.remove(queue, 1)
        if e.t > limit then table.insert(queue, 1, e); break end
        Advance(math.max(0, e.t - clock))
        e.f()
    end
    Advance(math.max(0, limit - clock))
end

-- Frames: any unknown method is a no-op; a few return values the addon reads.
__events = {}
local function Obj()
    return setmetatable({}, { __index = function(_, k)
        if k == "GetWidth" or k == "GetHeight" then return function(self) return rawget(self, "_w") or 300 end end
        if k == "SetWidth" or k == "SetSize" then return function(self, w) rawset(self, "_w", w) end end
        if k == "GetStringWidth" then return function() return 40 end end
        if k == "GetLeft" or k == "GetRight" or k == "GetTop" or k == "GetBottom" then return function() return 10 end end
        if k == "GetCenter" then return function() return 100, 100 end end
        if k == "GetEffectiveScale" then return function() return 1 end end
        if k == "IsShown" or k == "IsVisible" then return function(self) return rawget(self, "_shown") end end
        if k == "Show" then return function(self)
            rawset(self, "_shown", true)
            local sc = rawget(self, "_scripts")
            if sc and sc.OnShow then sc.OnShow(self) end
        end end
        if k == "Hide" then return function(self) rawset(self, "_shown", false) end end
        if k == "SetShown" then return function(self, v) rawset(self, "_shown", v and true or false) end end
        if k == "SetScript" then return function(self, n, f)
            rawset(self, "_scripts", rawget(self, "_scripts") or {})
            self._scripts[n] = f
        end end
        if k == "GetScript" then return function(self, n) local sc = rawget(self, "_scripts"); return sc and sc[n] end end
        if k == "RegisterEvent" then return function(self, e)
            __events[e] = __events[e] or {}
            table.insert(__events[e], self)
        end end
        if k == "CreateTexture" or k == "CreateFontString" or k == "CreateLine" or k == "CreateAnimationGroup" then
            return function() return Obj() end
        end
        if k == "IsOwned" then return function() return false end end
        return function() end
    end })
end
CreateFrame = function(_, name) local o = Obj(); if name then _G[name] = o end; return o end
UIParent, GameTooltip, WorldFrame = Obj(), Obj(), Obj()
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) if os.getenv("IPG_VERBOSE") then print("CHAT", m) end end }
UISpecialFrames, StaticPopupDialogs, SlashCmdList = {}, {}, {}
RAID_CLASS_COLORS = { DRUID = { r = 1, g = 0.49, b = 0.04 } }
ITEM_QUALITY_COLORS = { [2] = { r = 0.1, g = 1, b = 0.1, hex = "|cff1eff00" } }
STANDARD_TEXT_FONT, ChatFontNormal = "x", {}
hooksecurefunc = function(a, b, c)
    local t, name, fn
    if type(a) == "table" then t, name, fn = a, b, c else t, name, fn = _G, a, b end
    local orig = t[name] or function() end
    t[name] = function(...) fn(...); return orig(...) end
end
function Fire(e, ...)
    for _, f in ipairs(__events[e] or {}) do
        local sc = rawget(f, "_scripts")
        if sc and sc.OnEvent then sc.OnEvent(f, e, ...) end
    end
end

-- Player and realm (Forever returns "" for realm names since 1.60.1).
money = 500000
GetMoney = function() return money end
UnitGUID = function() return "Player-1234-0ABCDEF0" end
UnitName = function() return "Tester" end
UnitClass = function() return "Druid", "DRUID" end
UnitLevel = function() return 60 end
GetRealmName = function() return "" end
GetLocale = function() return os.getenv("IPG_LOCALE") or "enUS" end
GetBuildInfo = function() return "1.60.1", "1", "Nov 2026", 16001 end
InCombatLockdown = function() return false end
GetBindingKey = function() return nil end
GetCursorPosition = function() return 0, 0 end
IsPlayerSpell = function() return false end
GetSpellCooldown = function() return 0, 0 end
IsModifiedClick = function() return false end

-- Items: synthetic names, every item is green, item level 50, sells to vendors for 1s.
C_Item = {
    GetItemInfo = function(id) return "Item " .. id, "|Hitem:" .. id .. "|h", 2, 50, 1, "Trade Goods", "Leather", 20, "", "icon", 100 end,
    GetItemCount = function() return 0 end,
    GetItemIconByID = function() return "icon" end,
    GetItemInfoInstant = function(id) return id, "", "", "", "icon", 7, 6 end,
    RequestLoadItemDataByID = function() end,
}
C_Spell = { GetSpellName = function(s) return "Spell " .. s end, GetSpellTexture = function() return "icon" end }
C_TradeSkillUI = { GetRecipeSchematic = function() return nil end }
C_Container = {
    GetContainerNumSlots = function() return 0 end,
    GetContainerItemInfo = function() return nil end,
    GetContainerNumFreeSlots = function() return 10, 0 end,
}
Enum = { CraftingReagentType = { Basic = 1 }, AuctionHouseSortOrder = { Price = 0 }, BagIndex = {} }

-- Auction mail subjects (the game's globals), used to tell expired and cancelled auctions apart.
AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
AUCTION_REMOVED_MAIL_SUBJECT = "Auction cancelled: %s"

-- Mailbox: a list of mails the tests fill; taking from a mail answers after 0.15 s, like the server.
inbox = {}
GetInboxNumItems = function() return #inbox, #inbox end
GetInboxHeaderInfo = function(i)
    local m = inbox[i]
    if not m then return end
    return nil, nil, m.sender, m.subject, m.money, 0, m.days or 29.5, m.items or 0, true
end
GetInboxItem = function(i, a)
    local m = inbox[i]
    if m and a == 1 and (m.items or 0) > 0 then return "Thing", 123, "icon", 1, 2 end
end
GetInboxInvoiceInfo = function(i)
    local m = inbox[i]
    -- Only sales carry an invoice (expired and cancelled auctions don't).
    if m and m.sender == "Auction House" and (m.money or 0) > 0 then return "seller", "Linen Cloth", "Buyer", m.money end
end
CheckInbox = function() end
mailTakes = 0
local function TakeLater(i)
    mailTakes = mailTakes + 1
    C_Timer.After(0.15, function()
        local m = inbox[i]
        if not m then return end
        money = money + m.money
        m.money, m.items = 0, 0
        if not m.text then table.remove(inbox, i) end
        Fire("MAIL_INBOX_UPDATE")
    end)
end
TakeInboxMoney, AutoLootMailItem, TakeInboxItem = TakeLater, TakeLater, TakeLater
