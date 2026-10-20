print("Hello world!")

local EVENT_ID = "runeAuras"

-- get game window
game_window = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)

local playerResources = require("GameData/player-resources")
local auraStore = require("Auras/aura-store")
local auraManager = require("Auras/aura-manager")
local auraEditor = require("UI/aura-editor")
local auraPanel = require("UI/aura-panel")

auraStore.Load()
auraPanel.Init({
    onAurasChanged = auraManager.Refresh,
})
auraManager.SetOnAuraMoved(auraEditor.OnAuraMoved)

Event.Draw.Subscribe(EVENT_ID, auraManager.Draw)

-- Leaving the game (logging out or going back to the lobby) tears down the
-- game interfaces, so drop our UI and let it rebuild when we're back in game.
Event.GameStateChanged.Subscribe(EVENT_ID, function(gameStateChangedEvent)
    if gameStateChangedEvent.newState ~= GameState.GAME then
        auraEditor.Destroy()
        auraPanel.Destroy()
        auraManager.Destroy()
    end
end)

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

function PluginShutdown()
    Event.Draw.Unsubscribe(EVENT_ID)
    Event.GameStateChanged.Unsubscribe(EVENT_ID)
    Event.ServerLogic.Unsubscribe("debugResources")
    auraEditor.Destroy()
    auraPanel.Shutdown()
    auraManager.Destroy()
end
