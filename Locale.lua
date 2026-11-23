-- ImpotPointGouv: translations. The English text is the key; without a translation it shows as is.
local _, ns = ...
local locale = GetLocale and GetLocale() or "enUS"
local T = {}
ns.LOCALE = locale
ns.L = setmetatable({}, {
    __index = function(_, k) return T[k] or k end,
    __call = function(_, k) return T[k] or k end,
})
function ns.AddLocale(loc, tbl)
    if loc ~= locale then return end
    for k, v in pairs(tbl) do T[k] = v end
end
