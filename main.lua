print("Hello world!")

local EVENT_ID = "runeAuras"

-- get game window
game_window = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)

local abilityCooldowns = require("GameData/ability-cooldowns")
local gameClock = require("GameData/game-clock")
local auraStore = require("Auras/aura-store")
local dataSources = require("Auras/data-sources")
local auraManager = require("Auras/aura-manager")
local auraEditor = require("UI/aura-editor")
local auraPanel = require("UI/aura-panel")

auraStore.Load()
gameClock.Start()
abilityCooldowns.Start()
auraPanel.Init({
    onAurasChanged = auraManager.Refresh,
})
auraManager.SetOnAuraMoved(auraEditor.OnAuraMoved)

Event.Draw.Subscribe(EVENT_ID, auraManager.Draw)

-- Greater ability icons: the unlock flags are read a couple of server ticks
-- after the player is in game, retrying for a while any that haven't
-- arrived. VarTransmit follows them after that, including unlocks mid-session.
local GREATER_EVENT_ID = "runeAuras_greaterIcons"
local GREATER_SETTLE_TICKS = 2
local GREATER_MAX_TICKS = 50
local function checkGreater()
    local ticks = 0
    Event.ServerLogic.Subscribe(GREATER_EVENT_ID, function()
        if not Player.IsAvailable() then return end
        ticks = ticks + 1
        if ticks < GREATER_SETTLE_TICKS then return end
        local changed, complete = dataSources.ApplyGreaterIcons()
        if changed then auraManager.Refresh() end
        if complete or ticks >= GREATER_MAX_TICKS then
            Event.ServerLogic.Unsubscribe(GREATER_EVENT_ID)
        end
    end)
end
checkGreater()
Event.VarTransmit.Subscribe(GREATER_EVENT_ID, function(event)
    local name = event.var and event.var.configName
    if name ~= nil and dataSources.OnVarChanged(name, event.newValue) then
        auraManager.Refresh()
    end
end)

-- Leaving the game (logging out or going back to the lobby) tears down the
-- game interfaces, so drop our UI and let it rebuild when we're back in game.
-- Entering it retries anything that needs the game's config.
Event.GameStateChanged.Subscribe(EVENT_ID, function(gameStateChangedEvent)
    if gameStateChangedEvent.newState == GameState.GAME then
        -- Game config may only be readable once in game.
        if dataSources.Refresh() then auraManager.Refresh() end
        checkGreater()
    else
        auraEditor.Destroy()
        auraPanel.Destroy()
        auraManager.Destroy()
        abilityCooldowns.Reset()
        gameClock.Reset()
        dataSources.ResetGreaterIcons()
    end
end)

function PluginShutdown()
    Event.ServerLogic.Unsubscribe(GREATER_EVENT_ID)
    Event.VarTransmit.Unsubscribe(GREATER_EVENT_ID)
    abilityCooldowns.Stop()
    gameClock.Stop()
    Event.Draw.Unsubscribe(EVENT_ID)
    Event.GameStateChanged.Unsubscribe(EVENT_ID)
    auraEditor.Destroy()
    auraPanel.Shutdown()
    auraManager.Destroy()
end
