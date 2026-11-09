-- The Channel data type's sources (channel tracker): current is the seconds
-- left of the channel (so far, for a cast like Snipe), max its length, so a
-- bar is a channel or cast bar. "Any channel" shows whatever is being
-- channelled; the others one channelled ability each (any version of it,
-- e.g. Greater Flurry for Flurry), from the ability catalogue.

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local channel = require("GameData/Trackers/channel")

local channels = {}

local CHANNEL_COLOUR = 0x5DADE2FF
local ANY_CHANNEL_NAME = "Any channel"
local COOLDOWN_ID_PREFIX = abilityCatalogue.SOURCE_ID_PREFIX
---@type table<string, AbilityEntry> Ability key to its ability, so "Any channel" can name and show it.
local channelAbilities = {}

--- "Any channel"'s details: the name and icon of whatever is (or was last)
--- being channelled.
---@return string name
---@return integer? spriteID
---@return nil objectID
local function anyChannelDetails()
    local key = channel.Key()
    local ability = key ~= nil and channelAbilities[key] or nil
    if ability == nil then return ANY_CHANNEL_NAME, nil, nil end
    return ability.label, ability.icon, nil
end

--- A read for one ability's channel: the channel while this ability is channelled,
--- else 0 of its own last length.
---@param key string The ability's key (see abilityCatalogue.Key).
---@return fun(): number, number, number?
local function abilityChannelReader(key)
    local lastMax = 0
    return function()
        local curr, max, remaining = channel.Read()
        if channel.Key() ~= key then return 0, lastMax end
        lastMax = max
        return curr, max, remaining
    end
end

--- Builds "Any channel", plus a source per channelled ability once the
--- catalogue can be read.
---@param usingCatalogue boolean Whether the ability catalogue could be read (see cooldowns.Build).
---@return DataSource[]
function channels.Build(usingCatalogue)
    local sources = {
        {
            id = "channel_any",
            type = "channel",
            label = ANY_CHANNEL_NAME,
            colour = CHANNEL_COLOUR,
            smooth = true,
            timed = true,
            state = "active",
            read = channel.Read,
            details = anyChannelDetails,
        },
    }
    channelAbilities = {}
    if not usingCatalogue then return sources end
    for _, ability in ipairs(abilityCatalogue.List()) do
        if ability.channelled and ability.key ~= nil then
            channelAbilities[ability.key] = ability
            local abilityName = ability.id:gsub("^" .. COOLDOWN_ID_PREFIX, "")
            sources[#sources + 1] = {
                id = "channel_" .. abilityName,
                type = "channel",
                label = ability.label,
                colour = CHANNEL_COLOUR,
                icon = ability.icon,
                ability = ability,
                smooth = true,
                timed = true,
                state = "active",
                -- Channelled abilities were once listed as buffs.
                movedFrom = { buffCatalogue.SourceID(abilityCatalogue.STRUCT_PREFIX .. abilityName) },
                read = abilityChannelReader(ability.key),
            }
        end
    end
    return sources
end

return channels
