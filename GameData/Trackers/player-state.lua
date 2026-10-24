-- Reads the player's combat state for load options (see
-- Auras/Registries/load-options): whether they're in combat, and the combat
-- style of the weapons they have equipped. Polled when asked (load options
-- read each once a frame); both are VarPlayer reads, through cached configs
-- so they skip the by-name lookup.
-- Usage: local playerState = require("GameData/Trackers/player-state")
--        playerState.InCombat()      --> true/false, nil out of game
--        playerState.WeaponStyle()   --> "melee", "ranged", "magic",
--                                        "necromancy" or nil

local gameApi = require("GameData/game-api")

local playerState = {}

local function readVarPlayer(name)
    local config = gameApi.Cached(gameApi.VarPlayerConfig, name)
    return config and gameApi.VarValue(config)
end

-- COMBATV2_MAINHAND_STYLE / _OFFHAND_STYLE value -> style id, seen in game
-- with one- and two-handed, plain and augmented weapons of each style
-- (neither changes it). 7 is nothing equipped and -1 an empty off hand.
-- They may be weapon categories rather than styles, so other weapon types
-- could use other values: unknown ones are logged once (DEBUG).
local STYLES = { [6] = "melee", [8] = "ranged", [1] = "magic", [37] = "necromancy" }
local NO_WEAPON = { [7] = true, [-1] = true, [0] = true }

function playerState.InCombat()
    local value = readVarPlayer("COMBATV2_PLAYER_IS_IN_COMBAT")
    if value == nil then return nil end
    return value ~= 0
end

local reported = {}

local function styleOf(value)
    if value == nil or NO_WEAPON[value] then return nil end
    local style = STYLES[value]
    if style == nil and not reported[value] then
        reported[value] = true
        log(formatStr("DEBUG weapon style: unknown value {}", tostring(value)))
    end
    return style
end

-- The main hand's style, or the off hand's when the main hand is empty
-- (e.g. only an off-hand weapon equipped).
function playerState.WeaponStyle()
    return styleOf(readVarPlayer("COMBATV2_MAINHAND_STYLE")) or styleOf(readVarPlayer("COMBATV2_OFFHAND_STYLE"))
end

return playerState
