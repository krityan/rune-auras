-- Rune Auras' entry point: starts each part of the plugin and wires them
-- together, and starts and stops what needs the player in game as they
-- enter and leave it. The work of each part belongs in that part's module.

local EVENT_ID = "runeAuras"

local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local activeBuffs = require("GameData/Trackers/active-buffs")
local channel = require("GameData/Trackers/channel")
local gameClock = require("GameData/Trackers/game-clock")
local auraStore = require("Auras/Store/aura-store")
local auraManager = require("Auras/aura-manager")
local sourceSync = require("Auras/source-sync")
local auraEditor = require("UI/Editor/aura-editor")
local auraPanel = require("UI/Windows/aura-panel")
local mainWindow = require("UI/Windows/main-window")

auraStore.Load()
gameClock.Start()
abilityCooldowns.Start()
auraPanel.Init({
    -- Edits re-apply only the auras they changed.
    onAurasChanged = auraManager.RefreshChanged,
})
auraManager.SetOnAuraMoved(auraEditor.OnAuraMoved)
Event.Draw.Subscribe(EVENT_ID, auraManager.Draw)

--- Re-applies the auras reading changed sources and updates the editor's
--- source pickers.
---@param isAffected (fun(sourceID: string): boolean)? Whether a source changed; nil for all of them.
local function onSourcesChanged(isAffected)
    auraManager.Refresh(isAffected)
    auraEditor.OnSourcesChanged()
end

sourceSync.Start({
    onSourcesChanged = onSourcesChanged,
    onAurasChanged = auraManager.RefreshChanged,
})

--- Drops our UI and per-session state on leaving the game (logging out or
--- going back to the lobby), which tears down the game interfaces; it all
--- rebuilds when we're back in game.
local function onLeaveGame()
    mainWindow.Destroy()
    -- Edits wait a moment before they're written (see auraStore.SavePending).
    auraStore.SaveNow()
    auraPanel.Destroy()
    auraManager.Destroy()
    abilityCooldowns.Reset()
    activeBuffs.Reset()
    channel.Reset()
    sourceSync.LeaveGame()
    gameClock.Reset()
end

Event.GameStateChanged.Subscribe(EVENT_ID, function(gameStateChangedEvent)
    if gameStateChangedEvent.newState == GameState.GAME then
        sourceSync.EnterGame()
    else
        onLeaveGame()
    end
end)

--- Called by the client when the plugin unloads: stops every event and drops
--- everything drawn.
function PluginShutdown()
    sourceSync.Stop()
    abilityCooldowns.Stop()
    gameClock.Stop()
    Event.Draw.Unsubscribe(EVENT_ID)
    Event.GameStateChanged.Unsubscribe(EVENT_ID)
    mainWindow.Destroy()
    auraStore.SaveNow()
    auraPanel.Shutdown()
    auraManager.Destroy()
end
