-- The Familiar data type's sources: the summoned familiar's lifepoints,
-- spell points and stored scrolls. A fixed list, not built from game
-- config. $name is the familiar's name (lifepoints) or its special move's
-- (points and scrolls), or what the source is with none out; the icon is
-- its pouch's or its scroll's. Labels leave out "Familiar", as the picker
-- lists them under the Familiar type; the name an aura picking one gets,
-- and $name with none out, keep it.

local familiarTracker = require("GameData/Trackers/familiar")

local familiar = {}

local NO_ICON = nil
-- Each source's name with "Familiar", for auras picking it and $name with
-- no familiar out.
local LIFEPOINTS_NAME = "Familiar lifepoints"
local SPELL_POINTS_NAME = "Familiar spell points"
local SCROLLS_NAME = "Familiar stored scrolls"

--- A source's details: the familiar's name and its pouch's icon.
---@param fallback string Shown as $name with no familiar out.
---@return fun(): string, integer?, integer?
local function familiarDetails(fallback)
    return function()
        local summoned = familiarTracker.Details()
        if summoned == nil then
            return fallback, NO_ICON, NO_ICON
        end

        return summoned.name or fallback, NO_ICON, summoned.pouchID
    end
end

--- A source's details: the special move's name and its scroll's icon
--- (else the pouch's).
---@param fallback string Shown as $name with no familiar out, or one whose special move isn't known.
---@return fun(): string, integer?, integer?
local function specialDetails(fallback)
    return function()
        local summoned = familiarTracker.Details()
        if summoned == nil then
            return fallback, NO_ICON, NO_ICON
        end

        return summoned.specialName or fallback, NO_ICON, summoned.scrollID or summoned.pouchID
    end
end

---@type DataSource[]
local SOURCES = {
    {
        id = "familiarLifepoints",
        type = "familiar",
        label = "Lifepoints",
        auraName = LIFEPOINTS_NAME,
        -- The game's lifepoints bar red (the main row of its gradient).
        colour = 0xE32D0CFF,
        read = function()
            return familiarTracker.GetLifepoints(), familiarTracker.GetMaxLifepoints()
        end,
        details = familiarDetails(LIFEPOINTS_NAME),
    },
    {
        id = "familiarSpellPoints",
        type = "familiar",
        label = "Spell points",
        auraName = SPELL_POINTS_NAME,
        -- The game's green bar (a light row of its gradient).
        colour = 0x5CAF47FF,
        read = familiarTracker.GetSpellPoints,
        details = specialDetails(SPELL_POINTS_NAME),
    },
    {
        id = "familiarScrolls",
        type = "familiar",
        label = "Stored scrolls",
        auraName = SCROLLS_NAME,
        -- A summoning scroll's purple.
        colour = 0x474D9CFF,
        read = familiarTracker.GetScrolls,
        details = specialDetails(SCROLLS_NAME),
    },
}

--- The familiar sources.
---@return DataSource[]
function familiar.Build()
    return SOURCES
end

return familiar
