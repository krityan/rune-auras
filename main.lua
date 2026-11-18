-- RuneAuras' entry point: starts each part of the plugin and wires them
-- together, and starts and stops what needs the player in game as they
-- enter and leave it. The work of each part belongs in that part's module.

local EVENT_ID = "runeAuras"

local trackerManager = require("GameData/Trackers/tracker-manager")
local auraStore = require("Auras/Store/aura-store")
local auraManager = require("Auras/aura-manager")
local dragFollow = require("Auras/Displays/Parts/drag-follow")
local sourceSync = require("Auras/source-sync")
local auraEditor = require("UI/Editor/aura-editor")
local auraPanel = require("UI/Windows/aura-panel")
local mainWindow = require("UI/Windows/main-window")

trackerManager.Start()
auraPanel.Init({
    -- Edits re-apply only the auras they changed.
    onAurasChanged = auraManager.RefreshChanged,
    -- The editor and list place auras by the size they have on screen.
    screenSize = auraManager.ScreenSize,
})
auraManager.SetOnAuraMoved(auraEditor.OnAuraMoved)

--- Re-applies the auras reading changed sources and updates the main
--- window's list icons and source pickers.
---@param isAffected (fun(sourceID: string): boolean)? Whether a source changed; nil for all of them.
local function onSourcesChanged(isAffected)
    auraManager.Refresh(isAffected)
    mainWindow.OnSourcesChanged()
end

-- Whether the saved auras have loaded (over a few frames, see
-- auraStore.Load), and whether the game was entered before they had.
local aurasLoaded = false
local enterPending = false

--- Starts what works from the saved auras, once they've loaded: the buff
--- list, which builds the buffs they show first, and what entering the game
--- does if that came first, then drawing them, and the panel's count.
local function onAurasLoaded()
    aurasLoaded = true
    sourceSync.Start({
        onSourcesChanged = onSourcesChanged,
        onAurasChanged = auraManager.RefreshChanged,
    })
    if enterPending then
        enterPending = false
        sourceSync.EnterGame()
    end
    Event.Draw.Subscribe(EVENT_ID, auraManager.Draw)
    auraPanel.Refresh()
end

auraStore.Load(onAurasLoaded)

--- Drops our UI and per-session state on leaving the game (logging out or
--- going back to the lobby), which tears down the game interfaces; it all
--- rebuilds when we're back in game.
local function onLeaveGame()
    mainWindow.Destroy()
    -- Edits wait a moment before they're written (see auraStore.SavePending).
    auraStore.SaveNow()
    auraPanel.Destroy()
    dragFollow.Cancel()
    auraManager.Destroy()
    trackerManager.Reset()
    sourceSync.LeaveGame()
end

Event.GameStateChanged.Subscribe(EVENT_ID, function(gameStateChangedEvent)
    if gameStateChangedEvent.newState == GameState.GAME then
        -- Entering the game lists the buffs the auras use first, so it waits
        -- for them to load.
        if aurasLoaded then
            sourceSync.EnterGame()
        else
            enterPending = true
        end
    else
        enterPending = false
        onLeaveGame()
    end
end)

--- Called by the client when the plugin unloads: stops every event and drops
--- everything drawn.
function PluginShutdown()
    sourceSync.Stop()
    trackerManager.Stop()
    Event.Draw.Unsubscribe(EVENT_ID)
    Event.GameStateChanged.Unsubscribe(EVENT_ID)
    auraStore.StopLoading()
    mainWindow.Destroy()
    auraStore.SaveNow()
    auraPanel.Shutdown()
    dragFollow.Cancel()
    auraManager.Destroy()
end
