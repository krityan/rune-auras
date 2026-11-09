-- Buffs, listed from game config: finding the buff structs (a background walk
-- of every struct id, saved so later loads list them straight away) and the
-- list the rest of the plugin reads, built with the modules in Buffs/.

local gameApi = require("GameData/game-api")
local specialAttackCatalogue = require("GameData/Catalogues/special-attack-catalogue")
local buffVars = require("GameData/Catalogues/Buffs/buff-vars")
local buffEntries = require("GameData/Catalogues/Buffs/buff-entries")
local buffList = require("GameData/Catalogues/Buffs/buff-list")

local buffCatalogue = {}

local CACHE_KEY = "buffStructIDs"
local EVENT_ID = "runeAuras_buffCatalogue"
local LOAD_EVENT_ID = "runeAuras_buffCatalogueLoad"
-- Saved buffs built per Logic tick when loading: each takes dozens of
-- guarded lookups (its params, and the var names its rules try), so the
-- ~600 take about a second and a half.
local LOAD_PER_TICK = 8
-- Structs checked per Logic tick, about 4 lookups each for one that isn't a
-- buff: small, as buffs are already listed from the saved ids, and the walk
-- reuses those (see buildEntry). (There's no clock to budget by time.)
local SCAN_PER_TICK = 150
-- Buffs the walk reads from config per Logic tick (new ones, after a game
-- update): dozens of lookups each, so a batch ends early after this many,
-- as a run of them would otherwise stall the tick.
local SCAN_READS_PER_TICK = LOAD_PER_TICK

---@type BuffEntry[]
local entries = {}
---@type table<integer, BuffEntry> Struct id to every buff built this session, duplicates included (see buildEntry).
local builtByID = {}
-- The saved struct ids, as a comma list.
local cachedIDs = nil

--- A buff source's id, from its struct name.
---@type fun(structName: string): string
buffCatalogue.SourceID = buffEntries.SourceID

--- Whether a source id is a buff source's id, listed or not.
---@type fun(sourceID: any): boolean
buffCatalogue.IsSourceID = buffEntries.IsSourceID

--- Whether a buff has any var to be read from (active-buffs reads it if so).
---@type fun(entry: BuffEntry): boolean
buffCatalogue.HasVars = buffVars.HasAny

--- Whether a buff or debuff is listed as a source of its kind (see buffEntries.IsListed).
---@type fun(entry: BuffEntry): boolean
buffCatalogue.IsListed = buffEntries.IsListed

--- A struct as a buff, read once a session: game config doesn't change
--- while the client runs, so the walk reuses what Load built. Later
--- buffList.Finish calls change the entry in place, which is safe to repeat.
---@param structID integer
---@return BuffEntry? entry nil if it isn't a buff.
---@return boolean isFresh Whether it was read from config just now.
local function buildEntry(structID)
    local built = builtByID[structID]
    if built ~= nil then return built, false end
    local entry = buffEntries.Read(structID)
    builtByID[structID] = entry
    return entry, true
end

--- A list's struct ids as a sorted comma list, for saving and comparing.
---@param list BuffEntry[]
---@return string
local function idString(list)
    local ids = {}
    for _, entry in ipairs(list) do ids[#ids + 1] = entry.structID end
    table.sort(ids)
    for index, value in ipairs(ids) do ids[index] = tostring(value) end
    return table.concat(ids, ",")
end

local loading = false

--- Builds the list from the saved struct ids. Each buff takes dozens of
--- guarded lookups (its params, and the var names its rules try), so all
--- ~600 at once stalled a frame for about half a second. So the buffs auras
--- use are built at once, after one quick pass over the saved ids' names,
--- so those auras show straight away; the rest follow in the background,
--- LOAD_PER_TICK each Logic tick. Call it in game, where vars can be read.
--- A load cut short by Stop starts over next time.
---@param wanted table<string, boolean> Source ids auras use ("buff_<struct name>"). Special attacks' cooldown debuffs are always built.
---@param onReady fun(changed: boolean) Called once the wanted buffs are listed, if any were.
---@param onDone fun(changed: boolean) Called when it's all built, or there was nothing to build.
function buffCatalogue.Load(wanted, onReady, onDone)
    if loading then return end
    if #entries > 0 or not buffEntries.CanRead() then
        onDone(false)
        return
    end
    cachedIDs = cachedIDs or PersistentDB:GetString(CACHE_KEY) or ""
    -- The saved ids still there (one may be gone after a game update) and
    -- their names; the wanted ones are built now.
    local rest, list = {}, {}
    for value in string.gmatch(cachedIDs, "%d+") do
        local structID = tonumber(value)
        local name = buffEntries.StructName(structID)
        if name ~= nil then
            -- Special attack cooldowns are listed from their debuffs, and
            -- there are only a dozen, so they're always built now.
            local isSpecialAttack = specialAttackCatalogue.IsCooldownDebuff(name)
            if wanted[buffEntries.SourceID(name)] or isSpecialAttack then
                local entry = buildEntry(structID)
                if entry ~= nil then list[#list + 1] = entry end
            else
                rest[#rest + 1] = structID
            end
        end
    end
    if #list > 0 then
        -- A copy: Finish drops duplicates from the list it's given.
        local wantedEntries = {}
        for index, entry in ipairs(list) do wantedEntries[index] = entry end
        entries = buffList.Finish(wantedEntries)
        onReady(true)
    end
    local nextIndex = 1
    loading = true
    Event.Logic.Subscribe(LOAD_EVENT_ID, function()
        for _ = 1, LOAD_PER_TICK do
            local structID = rest[nextIndex]
            if structID == nil then
                Event.Logic.Unsubscribe(LOAD_EVENT_ID)
                loading = false
                if #list > 0 then entries = buffList.Finish(list) end
                onDone(#list > 0)
                return
            end
            nextIndex = nextIndex + 1
            local entry = buildEntry(structID)
            if entry ~= nil then list[#list + 1] = entry end
        end
    end)
end

local scanning = false
-- Whether a walk has finished this session. Game config doesn't change while
-- the client runs, so world hops and lobby returns don't walk again.
local scanned = false

--- Ends a finished walk: replaces, saves and reports the list if the buffs
--- found differ from it.
---@param found BuffEntry[]
---@param onChanged fun()?
local function finishScan(found, onChanged)
    Event.Logic.Unsubscribe(EVENT_ID)
    scanning = false
    scanned = true
    local ids = idString(found)
    -- Against the saved ids, not the list: the list has had its duplicates
    -- dropped.
    if ids == cachedIDs then return end
    entries = buffList.Finish(found)
    cachedIDs = ids
    PersistentDB:SetString(CACHE_KEY, ids)
    if onChanged ~= nil then onChanged() end
end

--- Gives up a failed walk, keeping the current list; the next Scan retries.
local function abandonScan()
    Event.Logic.Unsubscribe(EVENT_ID)
    scanning = false
end

--- Walks every struct in the background, once per session (a walk cut
--- short by Stop starts over next time), to catch game updates. When it's
--- done and the buffs differ from the current list, the list is replaced
--- and saved.
---@param onChanged fun()? Called if the list changed.
function buffCatalogue.Scan(onChanged)
    if scanned or scanning or not buffEntries.CanRead() then return end
    local walk = gameApi.ConfigWalk("Struct")
    if walk == nil then return end
    scanning = true
    local found = {}
    Event.Logic.Subscribe(EVENT_ID, function()
        local reads = 0
        for _ = 1, SCAN_PER_TICK do
            local structID, _, ok = gameApi.NextInWalk(walk)
            if not ok then
                abandonScan()
                return
            end
            if structID == nil then
                finishScan(found, onChanged)
                return
            end
            local entry, isFresh = buildEntry(structID)
            if entry ~= nil then
                found[#found + 1] = entry
                if isFresh then reads = reads + 1 end
                if reads >= SCAN_READS_PER_TICK then return end
            end
        end
    end)
end

--- Stops a walk or load in progress. A load's partial list is dropped, so
--- the next Load starts over rather than taking it as complete.
function buffCatalogue.Stop()
    if scanning then
        Event.Logic.Unsubscribe(EVENT_ID)
        scanning = false
    end
    if loading then
        Event.Logic.Unsubscribe(LOAD_EVENT_ID)
        loading = false
        entries = {}
    end
end

--- Forgets the saved struct ids, so the next session loads no buffs up
--- front and its walk finds and saves them all again. The list this session
--- is kept.
function buffCatalogue.ClearSaved()
    cachedIDs = ""
    PersistentDB:SetString(CACHE_KEY, "")
end

--- Every buff listed so far, sorted by label.
---@return BuffEntry[]
function buffCatalogue.List()
    return entries
end

return buffCatalogue
