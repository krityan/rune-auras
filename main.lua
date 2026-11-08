-- Rune Auras' entry point: starts each part of the plugin and wires them
-- together, and starts and stops what needs the player in game as they
-- enter and leave it. The work of each part belongs in that part's module.

local EVENT_ID = "runeAuras"

local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local activeBuffs = require("GameData/Trackers/active-buffs")
local channel = require("GameData/Trackers/channel")
local extraAction = require("GameData/Trackers/extra-action")
local gameClock = require("GameData/Trackers/game-clock")
local playerTarget = require("GameData/Trackers/player-target")
local targetDebuffs = require("GameData/Trackers/target-debuffs")
local targetEffects = require("GameData/Trackers/target-effects")
local stalledAbility = require("GameData/Trackers/stalled-ability")
local combatTimer = require("GameData/Trackers/combat-timer")
local wornEquipment = require("GameData/Trackers/worn-equipment")
local targetInfo = require("GameData/Trackers/target-info")
local auraStore = require("Auras/Store/aura-store")
local auraManager = require("Auras/aura-manager")
local dragFollow = require("Auras/Displays/Parts/drag-follow")
local sourceSync = require("Auras/source-sync")
local auraEditor = require("UI/Editor/aura-editor")
local auraPanel = require("UI/Windows/aura-panel")
local mainWindow = require("UI/Windows/main-window")

auraStore.Load()
gameClock.Start()
abilityCooldowns.Start()
extraAction.Start()
playerTarget.Start()
targetDebuffs.Start()
targetEffects.Start()
stalledAbility.Start()
combatTimer.Start()
wornEquipment.Start()
targetInfo.Start()
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
    dragFollow.Cancel()
    auraManager.Destroy()
    abilityCooldowns.Reset()
    activeBuffs.Reset()
    channel.Reset()
    extraAction.Reset()
    playerTarget.Reset()
    targetInfo.Reset()
    targetDebuffs.Reset()
    targetEffects.Reset()
    stalledAbility.Reset()
    combatTimer.Reset()
    wornEquipment.Reset()
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
    extraAction.Stop()
    combatTimer.Stop()
    stalledAbility.Stop()
    targetEffects.Stop()
    targetDebuffs.Stop()
    playerTarget.Stop()
    wornEquipment.Stop()
    targetInfo.Stop()
    gameClock.Stop()
    Event.Draw.Unsubscribe(EVENT_ID)
    Event.GameStateChanged.Unsubscribe(EVENT_ID)
    mainWindow.Destroy()
    auraStore.SaveNow()
    auraPanel.Shutdown()
    dragFollow.Cancel()
    auraManager.Destroy()
end
