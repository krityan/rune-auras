-- The player's summoned familiar, read from game vars when asked (through
-- var-cache, so a step with no var changes reads nothing from the game):
-- its lifepoints, spell points and stored scrolls, and its name, the
-- pouch it was summoned from and its special move's name and scroll.

local gameApi = require("GameData/game-api")
local varCache = require("GameData/Trackers/var-cache")

local familiar = {}

local readVarPlayer = varCache.VarPlayer

-- The most spell points a familiar can have.
local MAX_SPELL_POINTS = 60
-- The most scrolls a familiar can store.
-- TODO: check in game that a familiar can't store more than 500.
local MAX_SCROLLS = 500
-- Every pouch (or binding contract) to its familiar's scroll: input pouch,
-- output scroll. Read through its entries, as GetOutputValue takes only a
-- config (an id logs an error, even in pcall).
local POUCH_SCROLLS_ENUM = "LORE_POUCH_COUNT_ENUM"
local ENUM_INPUT, ENUM_OUTPUT = 1, 2
-- A scroll item's name ends this way, or names its special move in
-- brackets after it: "Spirit Wolf scroll (Howl)".
local SCROLL_SUFFIX = " scroll"

--- What's known about the summoned familiar, worked out once per familiar.
---@class FamiliarDetails
---@field npcID integer
---@field name string? The familiar's name.
---@field pouchID integer? The pouch (or binding contract) it was summoned from.
---@field scrollID integer? Its special move's scroll.
---@field specialName string? Its special move's name.

---@type FamiliarDetails?
local details = nil
---@type table<integer, integer>? Pouch id to scroll id; nil until the enum has been read.
local scrollsByPouch = nil

--- An id from a var's value: a config (an NPC or OBJ var), or a plain id.
---@param value any
---@return integer? id nil (or below 0) for none.
local function idFrom(value)
    if type(value) == "number" then
        return math.tointeger(value)
    end

    if type(value) ~= "userdata" then
        return nil
    end

    return gameApi.ID(value)
end

--- Reads every pouch's scroll from the enum, once it can be read (a few
--- hundred entries, once a session).
---@return table<integer, integer>? scrollsByPouch nil while config can't be read.
local function readScrolls()
    if scrollsByPouch ~= nil then
        return scrollsByPouch
    end

    local entries = gameApi.EnumValues(POUCH_SCROLLS_ENUM)
    if type(entries) ~= "table" then
        return nil
    end

    local found = {}
    for _, entry in ipairs(entries) do
        if type(entry) == "table" then
            local pouchID, scrollID = gameApi.ItemID(entry[ENUM_INPUT]), gameApi.ItemID(entry[ENUM_OUTPUT])
            if pouchID ~= nil and scrollID ~= nil and scrollID >= 0 then
                found[pouchID] = scrollID
            end
        end
    end

    scrollsByPouch = found
    return found
end

--- The scroll a familiar's special move uses, from the pouch it was
--- summoned from.
---@param pouchID integer?
---@return integer? scrollID
local function scrollFor(pouchID)
    if pouchID == nil then
        return nil
    end

    local scrolls = readScrolls()
    return scrolls and scrolls[pouchID]
end

--- Drops a trailing " scroll" from a name, in any case.
---@param name string
---@return string
local function withoutScrollSuffix(name)
    local suffixStart = #name - #SCROLL_SUFFIX + 1
    if suffixStart >= 1 and name:sub(suffixStart):lower() == SCROLL_SUFFIX then
        return name:sub(1, suffixStart - 1)
    end

    return name
end

--- The special move's name from its scroll's: what's in brackets after
--- "... scroll" ("Spirit Wolf scroll (Howl)": Howl, "Devout Yak scroll
--- (Ethereal Storage scroll)": Ethereal Storage), else what's before the
--- brackets ("Sundering strike (little bloodrager)": Sundering strike),
--- else the name without " scroll".
---@param scrollName string
---@return string?
function familiar.SpecialName(scrollName)
    local before, inside = scrollName:match("^(.-)%s*%((.*)%)%s*$")
    local name = scrollName
    if before ~= nil then
        local namesScroll = before:lower():sub(-#SCROLL_SUFFIX) == SCROLL_SUFFIX
        name = (namesScroll and inside ~= "") and inside or before
    end

    name = withoutScrollSuffix(name)

    if name == "" then
        return nil
    end

    return name
end

--- The special move's name, from its scroll's.
---@param scrollID integer?
---@return string?
local function specialNameFor(scrollID)
    if scrollID == nil then
        return nil
    end

    local name = gameApi.ItemName(scrollID)
    if type(name) ~= "string" or name == "" then
        return nil
    end

    return familiar.SpecialName(name)
end

--- The summoned familiar's details, or nil with none out. Looked up again
--- only when the familiar or its pouch changes.
---@return FamiliarDetails?
function familiar.Details()
    local npcConfig = readVarPlayer("LORE_NPC_HEAD")
    local npcID = idFrom(npcConfig)
    if npcID == nil or npcID < 0 then
        details = nil
        return nil
    end

    local pouchID = idFrom(readVarPlayer("FOLLOWER_OBJ"))
    if pouchID ~= nil and pouchID < 0 then
        pouchID = nil
    end

    -- The pouch's var can arrive after the familiar's, and the scrolls may
    -- not be readable yet, so either one coming in looks the details up again.
    local isSameFamiliar = details ~= nil and details.npcID == npcID and details.pouchID == pouchID
    local scrollsPending = pouchID ~= nil and scrollsByPouch == nil
    if isSameFamiliar and not scrollsPending then
        return details
    end

    local name = type(npcConfig) == "userdata" and gameApi.DisplayName(npcConfig) or nil
    if name == "" then
        name = nil
    end

    local scrollID = scrollFor(pouchID)
    details = { npcID = npcID, name = name, pouchID = pouchID, scrollID = scrollID,
        specialName = specialNameFor(scrollID) }
    return details
end

--- The familiar's lifepoints; 0 with no familiar out.
---@return integer?
function familiar.GetLifepoints()
    return readVarPlayer("LORE_FOLLOWER_LIFEPOINTS")
end

--- The familiar's maximum lifepoints. It keeps the last familiar's after
--- it's dismissed.
--- TODO: check in game whether this includes boosts.
---@return integer?
function familiar.GetMaxLifepoints()
    return readVarPlayer("LORE_FOLLOWER_BASE_LIFEPOINTS")
end

--- The familiar's spell points, of the most it can have.
---@return integer? points
---@return integer max
function familiar.GetSpellPoints()
    return readVarPlayer("LORE_SPELL_POINTS"), MAX_SPELL_POINTS
end

--- The scrolls stored in the familiar, of the most it can store; 0 with no
--- familiar out.
---@return integer? scrolls
---@return integer max
function familiar.GetScrolls()
    return readVarPlayer("COMBATV2_SUMMONING_SCROLLCOUNT"), MAX_SCROLLS
end

return familiar
