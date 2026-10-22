print("Hello world!")

local EVENT_ID = "runeAuras"

-- get game window
local gameApi = require("GameData/game-api")
game_window = gameApi.Component("TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP")

local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local buffVars = require("GameData/Trackers/buff-vars")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local gameClock = require("GameData/Trackers/game-clock")
local auraStore = require("Auras/aura-store")
local dataSources = require("Auras/Registries/data-sources")
local auraManager = require("Auras/aura-manager")
local auraEditor = require("UI/Windows/aura-editor")
local auraPanel = require("UI/Windows/aura-panel")

auraStore.Load()
gameClock.Start()
abilityCooldowns.Start()
auraPanel.Init({
    onAurasChanged = auraManager.Refresh,
})
auraManager.SetOnAuraMoved(auraEditor.OnAuraMoved)

Event.Draw.Subscribe(EVENT_ID, auraManager.Draw)

-- Auras made for a buff whose vars aren't known (e.g. under the old buff
-- bar tracking) lose their source; say so once per aura per session rather
-- than leaving a blank icon unexplained. Only once buff sources are listed,
-- so a catalogue that isn't readable yet doesn't count as every buff gone.
local reportedUntracked = {}
local function reportUntrackedBuffs()
    if #dataSources.ListByType("buff") == 0 then return end
    for _, aura in ipairs(auraStore.List()) do
        local sourceID = aura.source
        if type(sourceID) == "string" and sourceID:sub(1, 5) == "buff_"
            and dataSources.Get(sourceID) == nil and not reportedUntracked[aura.id] then
            reportedUntracked[aura.id] = true
            log(formatStr("Rune Auras: \"{}\" shows a buff that can't be tracked ({}). Choose another data source in its editor.",
                tostring(aura.name), sourceID))
        end
    end
end

-- The buff list loads from the saved struct ids (see data-sources); this
-- walks game config in the background, once per session, to catch new
-- buffs. It's called on every game entry because the walk needs the player
-- in game, but buffCatalogue skips it once a walk has finished.
local function scanBuffs()
    buffCatalogue.Scan(function()
        dataSources.RefreshBuffs()
        auraManager.Refresh()
        reportUntrackedBuffs()
    end)
end
if gameApi.PlayerAvailable() then scanBuffs() end

-- Greater ability icons: the unlock flags are read a couple of server ticks
-- after the player is in game, retrying for a while any that haven't
-- arrived. VarTransmit follows them after that, including unlocks mid-session.
local GREATER_EVENT_ID = "runeAuras_greaterIcons"
local GREATER_SETTLE_TICKS = 2
local GREATER_MAX_TICKS = 50
local function checkGreater()
    local ticks = 0
    Event.ServerLogic.Subscribe(GREATER_EVENT_ID, function()
        if not gameApi.PlayerAvailable() then return end
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
    local name = event.var and gameApi.EventVarName(event)
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
        reportUntrackedBuffs()
        checkGreater()
        scanBuffs()
    else
        auraEditor.Destroy()
        auraPanel.Destroy()
        auraManager.Destroy()
        abilityCooldowns.Reset()
        buffVars.Reset()
        buffCatalogue.Stop()
        gameClock.Reset()
        dataSources.ResetGreaterIcons()
    end
end)

function PluginShutdown()
    Event.ServerLogic.Unsubscribe(GREATER_EVENT_ID)
    Event.VarTransmit.Unsubscribe(GREATER_EVENT_ID)
    abilityCooldowns.Stop()
    buffCatalogue.Stop()
    gameClock.Stop()
    Event.Draw.Unsubscribe(EVENT_ID)
    Event.GameStateChanged.Unsubscribe(EVENT_ID)
    auraEditor.Destroy()
    auraPanel.Shutdown()
    auraManager.Destroy()
end
