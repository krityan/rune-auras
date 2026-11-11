-- The Target data type's sources: values about the player's target. (The
-- DoTs and debuffs on it are the Target debuff type's, see target-debuffs.)

local targetInfo = require("GameData/Trackers/target-info")

local target = {}

---@type DataSource[]
local SOURCES = {
    {
        -- The current target's lifepoints, of its max as far as the target
        -- panel's health bar shows (the game gives no max); 0 of 0 with no
        -- target. $name is the target's name, or the source's until it has one.
        id = "target_lifepoints",
        type = "target",
        label = "Target lifepoints",
        colour = 0x8E1B1BFF,
        read = targetInfo.Lifepoints,
        hasTarget = true,
        details = function()
            local icon, object, ammo = nil, nil, nil
            local info = targetInfo.Details()
            return info.name or "Target lifepoints", icon, object, ammo, info
        end,
    },
}

--- The target sources.
---@return DataSource[]
function target.Build()
    return SOURCES
end

return target
