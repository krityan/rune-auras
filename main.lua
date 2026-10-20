print("Hello world!")

-- get game window
game_window = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)

local playerResources = require("GameData/player-resources")

-- DEBUG: log resource values whenever they change
local lastResourceLine = nil
local function logResources()
    local r = playerResources.GetAll()
    if r == nil then
        return
    end
    local line = formatStr("lifepoints: {}/{} - prayer: {}/{} - adrenaline: {}/{} - summoning: {}/{}",
        tostring(r.lifepoints.curr), tostring(r.lifepoints.max),
        tostring(r.prayer.curr), tostring(r.prayer.max),
        tostring(r.adrenaline.curr), tostring(r.adrenaline.max),
        tostring(r.summoning.curr), tostring(r.summoning.max))
    if line ~= lastResourceLine then
        log(line)
        lastResourceLine = line
    end
end
Event.ServerLogic.Subscribe("debugResources", logResources)
