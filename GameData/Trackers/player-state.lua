-- The player's combat state, for load options (see
-- Auras/Registries/load-options): whether they're in combat, and the combat
-- style of their equipped weapons. Polled when asked (load options read
-- each once a frame), through cached var configs so they skip the by-name
-- lookup.

local gameApi = require("GameData/game-api")

local playerState = {}

---@alias WeaponStyle "melee"|"ranged"|"magic"|"necromancy"

-- COMBATV2_MAINHAND_STYLE / _OFFHAND_STYLE value to style, seen in game
-- with one- and two-handed, plain and augmented weapons of each style
-- (neither changes it). They may be weapon categories rather than styles,
-- so other weapon types could use other values: unknown ones are logged
-- once (DEBUG). 9 is Malachi's tooth, a crossbow (seen in game).
---@type table<integer, WeaponStyle>
local STYLES = { [6] = "melee", [8] = "ranged", [9] = "ranged", [1] = "magic", [37] = "necromancy" }
-- 7 is nothing equipped and -1 an empty off hand (both seen in game). 0
-- hasn't been seen; it's taken as no weapon rather than an unknown style.
local NO_WEAPON = { [7] = true, [-1] = true, [0] = true }

local readVarPlayer = gameApi.CachedVarPlayer

--- Whether the player is in combat.
---@return boolean? inCombat nil out of game.
function playerState.InCombat()
    local value = readVarPlayer("COMBATV2_PLAYER_IS_IN_COMBAT")
    if value == nil then return nil end
    return value ~= 0
end

-- Style values already logged as unknown.
local reported = {}

--- The style a hand's style value means.
---@param value integer?
---@return WeaponStyle? style nil for no weapon or an unknown value.
local function styleOf(value)
    if value == nil or NO_WEAPON[value] then return nil end
    local style = STYLES[value]
    if style == nil and not reported[value] then
        reported[value] = true
        log(formatStr("DEBUG weapon style: unknown value {}", tostring(value)))
    end
    return style
end

--- The equipped weapon's combat style: the main hand weapon's style, or the
--- off-hand weapon's when the main hand is empty (e.g. only an off-hand weapon equipped).
---@return WeaponStyle? style nil with no weapon, or out of game.
function playerState.WeaponStyle()
    return styleOf(readVarPlayer("COMBATV2_MAINHAND_STYLE")) or styleOf(readVarPlayer("COMBATV2_OFFHAND_STYLE"))
end

return playerState
