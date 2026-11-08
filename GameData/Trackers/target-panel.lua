-- The target info panel's buff slots: which effects it shows on the
-- player's current target, by sprite. Nothing names an effect or who put it
-- there, and the panel has no timers, so the sprite is all there is.

local gameApi = require("GameData/game-api")

local targetPanel = {}

-- The target info panel's 12 buff slots.
local SLOT_PREFIX = "TOPLEVEL_V2_TARGET_INFO__GRAPHIC_"
targetPanel.SLOT_COUNT = 12

---@type string[]? The slots' sprite component names, built once.
local slotNames = nil

--- The sprites the target info panel shows for the current target.
---@return table<integer, boolean>? icons The sprites in its buff slots; nil while the game has the panel unloaded (no target, or the panel turned off).
---@return integer filled How many slots show something.
function targetPanel.Icons()
    if slotNames == nil then
        slotNames = {}
        for index = 0, targetPanel.SLOT_COUNT - 1 do slotNames[#slotNames + 1] = SLOT_PREFIX .. index end
    end
    local icons, filled = {}, 0
    for _, name in ipairs(slotNames) do
        local combinedID = gameApi.Cached(gameApi.ComponentID, name)
        local slot = combinedID and gameApi.ComponentByID(combinedID)
        if slot == nil then return nil, 0 end
        local sprite = gameApi.SpriteID(slot)
        if sprite ~= nil and sprite >= 0 then
            icons[sprite] = true
            filled = filled + 1
        end
    end
    return icons, filled
end

return targetPanel
