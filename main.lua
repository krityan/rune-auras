print("Hello world!")

local EVENT_ID = "runeAuras"

-- get game window
game_window = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)

local abilityCooldowns = require("GameData/ability-cooldowns")
local gameClock = require("GameData/game-clock")
local auraStore = require("Auras/aura-store")
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

-- Leaving the game (logging out or going back to the lobby) tears down the
-- game interfaces, so drop our UI and let it rebuild when we're back in game.
Event.GameStateChanged.Subscribe(EVENT_ID, function(gameStateChangedEvent)
    if gameStateChangedEvent.newState ~= GameState.GAME then
        auraEditor.Destroy()
        auraPanel.Destroy()
        auraManager.Destroy()
        abilityCooldowns.Reset()
        gameClock.Reset()
    end
end)

function PluginShutdown()
    abilityCooldowns.Stop()
    gameClock.Stop()
    Event.Draw.Unsubscribe(EVENT_ID)
    Event.GameStateChanged.Unsubscribe(EVENT_ID)
    auraEditor.Destroy()
    auraPanel.Shutdown()
    auraManager.Destroy()
end
