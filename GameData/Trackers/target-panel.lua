-- The target info panel's buff slots: which effects it shows on the
-- player's current target, by sprite. Nothing names an effect or who put it
-- there, and the panel has no timers, so the sprite is all there is.

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")

local targetPanel = {}

-- The target info panel's 12 buff slots.
local SLOT_PREFIX = "TOPLEVEL_V2_TARGET_INFO__GRAPHIC_"
targetPanel.SLOT_COUNT = 12

---@type string[]? The slots' sprite component names, built once.
local slotNames = nil

-- The last read and when it was made: the target debuff and effect trackers
-- both read the panel in the same server tick's handlers, so the second
-- gets the first's. Keyed on the Logic tick too, so a read later in the
-- same server tick (a spell cast) sees the panel as it is then.
local readServerTick, readLogicTick = nil, nil
local readIcons, readFilled = nil, 0

--- Reads the slots' sprites from the panel.
---@return table<integer, boolean>? icons
---@return integer filled
local function readSlots()
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

--- The sprites the target info panel shows for the current target, read
--- at most once a moment (see readServerTick). Callers share the table, so
--- they mustn't change it.
---@return table<integer, boolean>? icons The sprites in its buff slots; nil while the game has the panel unloaded (no target, or the panel turned off).
---@return integer filled How many slots show something.
function targetPanel.Icons()
    local serverTick, logicTick = gameClock.ServerTicks(), gameClock.LogicTick()
    local isSameMoment = logicTick ~= nil and serverTick == readServerTick and logicTick == readLogicTick
    if not isSameMoment then
        readServerTick, readLogicTick = serverTick, logicTick
        readIcons, readFilled = readSlots()
    end
    return readIcons, readFilled
end

return targetPanel
