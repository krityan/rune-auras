-- RadialProgressOverlay Start flags, read once from the client, falling back
-- to the values seen in game.

local gameApi = require("GameData/game-api")

local radialFlags = {}

local function radialFlagValue(name)
    return ui.RadialProgressOverlayFlag[name]
end

--- A RadialProgressOverlay flag's value, falling back to the one seen in game.
---@param name string
---@param fallback integer
---@return integer
local function radialFlag(name, fallback)
    return tonumber((gameApi.Try(radialFlagValue, name))) or fallback
end

-- Counts curValue up in seconds by itself.
radialFlags.AUTOMATIC = radialFlag("AUTOMATIC", 1)
-- Draws the other slice, still clockwise from the top.
radialFlags.REVERSE = radialFlag("REVERSE", 2)
-- Draws the slice anticlockwise from the top.
radialFlags.FLIP_HORIZONTAL = radialFlag("FLIP_HORIZONTAL", 4)

return radialFlags
