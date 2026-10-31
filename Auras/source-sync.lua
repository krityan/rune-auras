-- Keeps the data sources in step with the game: lists them again as game
-- config becomes readable and the buff catalogue loads, switches greater
-- ability icons as their unlocks arrive, moves saved auras off source ids
-- that changed, and says which auras show a buff that can't be tracked.

local gameApi = require("GameData/game-api")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local varChanges = require("GameData/Trackers/var-changes")
local auraStore = require("Auras/Store/aura-store")
local dataSources = require("Auras/Registries/data-sources")

local sourceSync = {}

---@class SourceSyncHandlers
---@field onSourcesChanged fun(isAffected: (fun(sourceID: string): boolean)?) Sources or their icons changed: auras reading those that pass `isAffected` (every aura if it's nil) are applied again.
---@field onAurasChanged fun() Some auras changed: those are applied again.

local GREATER_EVENT_ID = "runeAuras_greaterIcons"
-- Greater ability icons: the unlock flags are read this many server ticks
-- after the player is in game, retrying until this many have passed.
local GREATER_SETTLE_TICKS = 2
local GREATER_MAX_TICKS = 50

---@type SourceSyncHandlers?
local handlers = nil
-- Aura ids already reported as showing an untracked buff this session.
local reportedUntracked = {}

--- Tells the handlers which auras need applying again.
---@param isAffected (fun(sourceID: string): boolean)? Whether a source changed; nil for all of them.
local function sourcesChanged(isAffected)
    if handlers ~= nil then handlers.onSourcesChanged(isAffected) end
end

--- Whether a source comes from the buff list (a buff, or a special attack
--- found by its cooldown debuff), or isn't listed (yet): what a new buff
--- list can change.
---@param sourceID string
---@return boolean
local function isFromBuffList(sourceID)
    local source = dataSources.Get(sourceID)
    return source == nil or source.type == "buff" or source.type == "specialAttack"
end

--- Whether a source's icon follows an ability's greater unlock.
---@param sourceID string
---@return boolean
local function followsAbility(sourceID)
    local source = dataSources.Get(sourceID)
    return source ~= nil and source.ability ~= nil
end

--- Gives sources saved with an id that has since moved the new one (see
--- auraStore.MigrateSources), and has the auras that changed applied again.
local function migrateSourceIDs()
    if auraStore.MigrateSources() and handlers ~= nil then handlers.onAurasChanged() end
end

--- Migrates moved source ids, then says once per aura per session which
--- auras show a buff whose vars aren't known (e.g. made under the old buff
--- bar tracking), rather than leaving a blank icon unexplained. Only once
--- buff sources are listed, so a catalogue that isn't readable yet doesn't
--- count as every buff gone.
local function reportUntrackedBuffs()
    if #dataSources.ListByType("buff") == 0 then return end
    migrateSourceIDs()
    for _, aura in ipairs(auraStore.List()) do
        local sourceID = aura.source
        local isUntracked = buffCatalogue.IsSourceID(sourceID) and dataSources.Get(sourceID) == nil
        if isUntracked and not reportedUntracked[aura.id] then
            reportedUntracked[aura.id] = true
            log(formatStr("Rune Auras: \"{}\" shows a buff that can't be tracked ({}). Choose another data source in its editor.",
                tostring(aura.name), sourceID))
        end
    end
end

--- Lists the buff sources again after the buff catalogue changed.
local function buffsChanged()
    dataSources.RefreshBuffs()
    sourcesChanged(isFromBuffList)
    reportUntrackedBuffs()
end

--- Loads the buff list from the saved struct ids (the buffs auras use at
--- once, so they show straight away, the rest in the background), then
--- walks game config (also in the background, once per session) for new
--- buffs. Both need the player in game; buffCatalogue skips whatever is
--- already done.
local function loadBuffs()
    buffCatalogue.Load(auraStore.UsedSources(), buffsChanged, function(changed)
        if changed then buffsChanged() end
        buffCatalogue.Scan(buffsChanged)
    end)
end

--- Switches unlocked greater abilities to their icons, a couple of server
--- ticks after the player is in game, retrying for a while any flags that
--- haven't arrived. VarTransmit follows them after that (see Start),
--- including unlocks mid-session.
local function checkGreater()
    local ticks = 0
    Event.ServerLogic.Subscribe(GREATER_EVENT_ID, function()
        if not gameApi.PlayerAvailable() then return end
        ticks = ticks + 1
        if ticks < GREATER_SETTLE_TICKS then return end
        local changed, complete = dataSources.ApplyGreaterIcons()
        if changed then sourcesChanged(followsAbility) end
        if complete or ticks >= GREATER_MAX_TICKS then
            Event.ServerLogic.Unsubscribe(GREATER_EVENT_ID)
        end
    end)
end

--- Follows greater unlock flags changing.
---@param name string
---@param value any Its new value.
local function onVarChanged(name, value)
    if dataSources.OnVarChanged(name, value) then sourcesChanged(followsAbility) end
end

--- Starts following the game, at plugin load. If the player is already in
--- game (a reload), the buffs load straight away.
---@param syncHandlers SourceSyncHandlers
function sourceSync.Start(syncHandlers)
    handlers = syncHandlers
    checkGreater()
    varChanges.Listen(GREATER_EVENT_ID, onVarChanged)
    if gameApi.PlayerAvailable() then loadBuffs() end
end

--- Retries everything that needs the game's config, on entering the game.
function sourceSync.EnterGame()
    -- Game config may only be readable once in game.
    if dataSources.Refresh() then sourcesChanged() end
    reportUntrackedBuffs()
    checkGreater()
    loadBuffs()
end

--- Drops what belongs to the session, on leaving the game: a buff walk in
--- progress, and the greater icons, which are read again on the next entry.
function sourceSync.LeaveGame()
    buffCatalogue.Stop()
    dataSources.ResetGreaterIcons()
end

--- Stops following the game, when the plugin unloads.
function sourceSync.Stop()
    Event.ServerLogic.Unsubscribe(GREATER_EVENT_ID)
    varChanges.Unlisten(GREATER_EVENT_ID)
    buffCatalogue.Stop()
    handlers = nil
end

return sourceSync
