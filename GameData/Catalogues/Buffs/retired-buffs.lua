-- Buffs the game no longer gives, whose structs are still in config: told
-- apart by their names, or listed by hand, so they aren't catalogued.

local gameApi = require("GameData/game-api")

local retiredBuffs = {}

-- Seasonal events whose buffs are named with the event and its year
-- (HALLOWEEN23, MTXBEACH15, EVENT21): each year's event brings new ones.
local EVENT_WORDS = { "HALLOWEEN", "XMAS", "CHRISTMAS", "EASTER", "VALENTINES", "BEACH", "SUMMER", "WINTER", "EVENT" }

-- Config names of things the game no longer gives: Treasure Hunter
-- (promotions are TRH<number>, older items plain TRH), Leagues (a game mode
-- only on its own worlds while it ran), the retired Beach event, and an
-- event word followed by a year of 2 or 4 digits.
local RETIRED_PATTERNS = { "^TRH[%d_]", "_TRH[%d_]", "LEAGUE", "^COMBATV2_BEACH_", "^MTXBEACH" }
for _, word in ipairs(EVENT_WORDS) do
    RETIRED_PATTERNS[#RETIRED_PATTERNS + 1] = word .. "_?%d%d%d?%d?%f[%D]"
end

-- Buffs whose struct is still in config though the game no longer gives
-- them, where their names don't say so (see RETIRED_PATTERNS).
local REMOVED_BUFFS = {
    -- A temporary experience boost from Menaphos' launch.
    COMBATV2_MENAPHOS_XPBOOST = true,
    -- Only from a time-limited event's skilling cauldrons.
    COMBATV2_AGILITY_POTION_EFFECT = true,
    COMBATV2_CRAFTING_POTION_EFFECT = true,
    -- One-off rewards for returning players.
    COMBATV2_CHALLENGE_RETURNER_DXP_CHANCE_ABILITY = true,
    COMBATV2_CHALLENGE_RETURNER_FREE_DEATHS_ABILITY = true,
    COMBATV2_RETURNER_PACK_XP_BOOST_DUMMY_ABILITY = true,
    -- The Bonanza event's buff.
    BUFF_SELECT_EVENT_CENTRAL_BUFF_BAR_STRUCT = true,
    -- Removed with Chronicle cards.
    COMBATV2_CHRONICLE_CARD_DUMMY_ABILITY = true,
    -- The Battle of the Monolith world event, and its prerelease boost.
    COMBATV2_ABILITY_CONSTITUTION_6AWE2_BLESSING = true,
    COMBATV2_MINIQUEST_EGWD_PRERELEASE_XP_BUFF_DUMMY_ABILITY = true,
    -- The Raid on Port Sarim event.
    COMBATV2_PORTSARIM_CONCH_DUMMY_ABILITY = true,
}

--- Whether a config name is a retired one (see RETIRED_PATTERNS).
---@param name string?
---@return boolean
local function isRetiredName(name)
    if name == nil then return false end
    for _, pattern in ipairs(RETIRED_PATTERNS) do
        if name:find(pattern) ~= nil then return true end
    end
    return false
end

--- Whether the game no longer gives a buff: it's in REMOVED_BUFFS, or its
--- struct or the item it shows has a retired name (Lucky Clover's struct
--- isn't Treasure Hunter's by name, but its item is TRH78_...).
---@param structName string
---@param objectID integer?
---@return boolean
function retiredBuffs.IsRetired(structName, objectID)
    if REMOVED_BUFFS[structName] or isRetiredName(structName) then return true end
    return objectID ~= nil and isRetiredName(gameApi.ItemConfigName(objectID))
end

return retiredBuffs
