-- Saving and loading the auras in PersistentDB: one key per aura plus an
-- index, written a few at a time and read back (see Save), and read a batch a
-- frame (see Load).

local serializer = require("Auras/Helpers/serializer")
local auraRecord = require("Auras/Store/aura-record")
local savedValues = require("Auras/Store/saved-values")
local storedAuras = require("Auras/Store/stored-auras")
local textMigration = require("Auras/Store/text-migration")

local auraPersistence = {}

local STORAGE_KEY = "auras"
-- Each aura's own key is this and its id (see Save).
local AURA_KEY_PREFIX = "aura."
-- Saved with the auras. Before 2, a group's x/y shifted its contents, which
-- kept anchors measured from the screen; see auraGroups.MigratePositions.
local POSITIONS_VERSION = 2
-- What a save without a version, or one still waiting for MigratePositions, has.
local OLD_POSITIONS_VERSION = 1
-- Saved with the auras. Before 2, texts were typed; see textMigration.
local TEXTS_VERSION = 2
-- What a save without a texts version has.
local OLD_TEXTS_VERSION = 1
-- Values read back from PersistentDB may differ by this fraction (it loses precision).
local READ_BACK_TOLERANCE = 1e-3
-- Auras written (and read back) per Save call; SavePending does the rest.
-- The client stops a Lua call after 1s, and a hundred-odd writes went past it.
local MAX_WRITES_PER_SAVE = 16
-- Requested saves are debounced: one waits this many frames for changes to
-- stop, so a burst of edits (a slider drag, typing) is saved once.
local SAVE_DELAY_FRAMES = 30
-- The debounce's longest wait while changes keep coming.
local MAX_SAVE_DELAY_FRAMES = 300
-- Saved auras read per frame while loading.
local LOAD_PER_FRAME = 64
local LOAD_EVENT_ID = "runeAuras_loadAuras"

-- What the last save wrote: each aura's saved form (to skip writing ones
-- that haven't changed) and which ids have keys (see Save).
local savedForms = {}
local savedIDs = {}
-- Each aura's version (see Version) when it was last written, so a save
-- only copies and encodes auras that changed since.
local savedVersions = {}
-- Whether the save on disk is the old single-value one (see Load): its list
-- is the only copy of any aura not yet written to its own key.
local legacySave = false
local warnedSaveFailed = false
local warnedAuraFailed = false
local savePending = false
-- A save asked for with RequestSave: frames until it runs, and until it
-- runs however often it's asked again. nil when none is waiting.
local quietFramesLeft = nil
local maxFramesLeft = nil
-- Whether the loaded auras still use the old group positions, waiting for
-- MigratePositions.
local positionsPending = false
-- Whether the save on disk still has typed texts: the loaded auras are
-- migrated, but on disk until every one of them is written again.
local textsPending = false

--- A load spread over frames (see Load).
---@class AuraLoad
---@field ids any[] The index's aura ids, in list order.
---@field count integer How many of `ids` are read: up to the first gap, if it has one.
---@field nextIndex integer The position in `ids` to read next.
---@field loaded Aura[] The auras read so far, in list order.
---@field nextID integer? The index's next free id.
---@field positionsVersion integer The index's positions version.
---@field inBatch boolean Set while a frame's work runs, so it's still set on the next frame only if that work stopped with an error.
---@field onLoaded fun()

---@type AuraLoad? The load in progress. Kept if it stops short, so saves stay off rather than write an incomplete list.
local loading = nil

--- The PersistentDB key an aura is saved under.
---@param auraID integer
---@return string
local function auraKey(auraID)
    return AURA_KEY_PREFIX .. tostring(auraID)
end

--- PersistentDB:Set as a plain function, for pcall.
---@param key string
---@param value any
local function setKey(key, value)
    PersistentDB:Set(key, value)
end

--- Takes auras out of groups that no longer exist (or aren't groups), to
--- the top level.
local function dropMissingGroups()
    for _, aura in ipairs(storedAuras.List()) do
        if aura.group ~= nil and not auraRecord.IsGroup(storedAuras.Get(aura.group)) then
            aura.group = nil
        end
    end
end

--- Whether any aura or group sits in a group.
---@return boolean
local function anyGrouped()
    for _, aura in ipairs(storedAuras.List()) do
        if aura.group ~= nil then return true end
    end
    return false
end

--- A saved record as an aura, its typed texts converted first while the
--- save still has them (see textMigration).
---@param record any
---@return Aura? aura nil for a record that isn't a valid aura.
local function auraFromSaved(record)
    if textsPending and type(record) == "table" then textMigration.MigrateRecord(record) end
    return auraRecord.FromSaved(record)
end

--- Fills the list with the loaded auras. Asks for a save that writes them
--- back if their texts were converted, drops groups that no longer exist,
--- and notes whether positions need MigratePositions.
---@param loaded Aura[]
---@param nextID integer? The index's next free id.
---@param positionsVersion integer
local function finishLoad(loaded, nextID, positionsVersion)
    storedAuras.Replace(loaded, nextID or 1)
    -- What was just loaded is what's on disk, so the next save doesn't
    -- write every aura again (with a few hundred, encoding, writing and
    -- reading them all back went past the client's 1s limit on one call).
    -- What FromSaved fills in is filled in again on every load. The old
    -- single-value save, and one with typed texts, do need every aura
    -- written again.
    if not legacySave and not textsPending then
        for _, aura in ipairs(loaded) do savedVersions[aura.id] = storedAuras.Version(aura.id) end
    end
    if textsPending then auraPersistence.RequestSave() end
    dropMissingGroups()
    positionsPending = positionsVersion < POSITIONS_VERSION and anyGrouped()
end

--- A load's work for one frame: the next LOAD_PER_FRAME auras, or, on the
--- frame after the last, filling the list and calling onLoaded.
local function loadStep()
    local current = loading
    if current.inBatch then
        -- The last frame's work stopped with an error. The load stops there,
        -- and saves stay off.
        Event.Draw.Unsubscribe(LOAD_EVENT_ID)
        log("Rune Auras: your saved auras couldn't be loaded, so nothing will be saved until the plugin is reloaded.")
        return
    end
    current.inBatch = true
    if current.nextIndex > current.count then
        finishLoad(current.loaded, current.nextID, current.positionsVersion)
        Event.Draw.Unsubscribe(LOAD_EVENT_ID)
        loading = nil
        current.onLoaded()
        return
    end
    local last = math.min(current.nextIndex + LOAD_PER_FRAME - 1, current.count)
    for position = current.nextIndex, last do
        local auraID = current.ids[position]
        savedIDs[auraID] = true
        local aura = auraFromSaved(PersistentDB:Get(auraKey(auraID)))
        if aura ~= nil then current.loaded[#current.loaded + 1] = aura end
    end
    current.nextIndex = last + 1
    current.inBatch = false
end

--- Replaces the list with the saved auras (see Save for the layout). They're
--- read over the next frames, LOAD_PER_FRAME a frame, as a few hundred read
--- at once stalled the frame; the list stays empty, and saves wait, until
--- every one is read, then it's filled at once and onLoaded is called. The
--- older single-key save is read at once. Converts typed texts (see
--- textMigration) and asks for a save that writes them back. Drops groups
--- that no longer exist, and notes whether positions need MigratePositions.
---@param onLoaded fun() Called once the list is filled: straight away when there's nothing to read over frames.
function auraPersistence.Load(onLoaded)
    auraPersistence.StopLoading()
    loading = nil
    storedAuras.Replace({}, 1)
    savedForms, savedIDs, savedVersions = {}, {}, {}
    legacySave, textsPending = false, false
    local index = PersistentDB:Get(STORAGE_KEY)
    if type(index) ~= "table" then
        onLoaded()
        return
    end
    -- Saves before per-aura keys held every aura in the index itself; the
    -- next save moves them to their own keys.
    local hasPerAuraKeys = type(index.ids) == "table"
    legacySave = not hasPerAuraKeys and type(index.auras) == "table"
    local textsVersion = savedValues.ToInteger(index.textsVersion) or OLD_TEXTS_VERSION
    textsPending = textsVersion < TEXTS_VERSION
    local nextID = savedValues.ToInteger(index.nextID)
    local positionsVersion = savedValues.ToInteger(index.positionsVersion) or OLD_POSITIONS_VERSION
    if not hasPerAuraKeys then
        local loaded = {}
        for _, record in ipairs(legacySave and index.auras or {}) do
            local aura = auraFromSaved(record)
            if aura ~= nil then loaded[#loaded + 1] = aura end
        end
        finishLoad(loaded, nextID, positionsVersion)
        onLoaded()
        return
    end
    local count = 0
    for _ in ipairs(index.ids) do count = count + 1 end
    loading = {
        ids = index.ids,
        count = count,
        nextIndex = 1,
        loaded = {},
        nextID = nextID,
        positionsVersion = positionsVersion,
        inBatch = false,
        onLoaded = onLoaded,
    }
    Event.Draw.Subscribe(LOAD_EVENT_ID, loadStep)
end

--- Stops a load in progress, on unloading. Saves stay off, as the list isn't
--- complete.
function auraPersistence.StopLoading()
    Event.Draw.Unsubscribe(LOAD_EVENT_ID)
end

--- Whether a value read back from PersistentDB holds what was written.
--- Numbers come back with some precision lost, so they only have to be close.
---@param written any
---@param readBack any
---@return boolean
local function sameSaved(written, readBack)
    if type(written) == "number" and type(readBack) == "number" then
        return math.abs(written - readBack) <= READ_BACK_TOLERANCE * math.max(1, math.abs(written))
    end
    if type(written) ~= "table" or type(readBack) ~= "table" then return written == readBack end
    for key, value in pairs(written) do
        if not sameSaved(value, readBack[key]) then return false end
    end
    for key in pairs(readBack) do
        if written[key] == nil then return false end
    end
    return true
end

--- Writes an aura's saved form to its key and reads it back.
---@param auraID integer
---@param copy table Its saved form (auraRecord.ToSaved).
---@return boolean took Whether the value read back matches.
local function writeAura(auraID, copy)
    local key = auraKey(auraID)
    if not pcall(setKey, key, copy) then return false end
    return sameSaved(copy, PersistentDB:Get(key))
end

--- Clears the keys of auras that were saved but no longer exist.
---@param presentIDs table<integer, boolean> Ids of the auras there are now.
local function clearDeletedKeys(presentIDs)
    for auraID in pairs(savedIDs) do
        if not presentIDs[auraID] then
            -- Cleared rather than left behind; an empty table if nil isn't
            -- accepted.
            if not pcall(setKey, auraKey(auraID), nil) then pcall(setKey, auraKey(auraID), {}) end
            savedForms[auraID], savedVersions[auraID] = nil, nil
        end
    end
    savedIDs = presentIDs
end

--- Writes the index (see Save) and reads it back.
---@param orderedIDs integer[] Every aura's id, in list order.
---@return boolean took Whether it reads back with every id.
local function writeIndex(orderedIDs)
    pcall(setKey, STORAGE_KEY, {
        nextID = storedAuras.NextID(),
        positionsVersion = positionsPending and OLD_POSITIONS_VERSION or POSITIONS_VERSION,
        textsVersion = textsPending and OLD_TEXTS_VERSION or TEXTS_VERSION,
        ids = orderedIDs,
    })
    local readBack = PersistentDB:Get(STORAGE_KEY)
    return type(readBack) == "table" and type(readBack.ids) == "table" and #readBack.ids == #orderedIDs
end

--- Saves what changed since the last save. Each aura has its own key
--- (`aura.<id>`) and an index (`auras`) holds `nextID`, `positionsVersion`
--- and `ids` in list order: PersistentDB silently refuses a value over its
--- size limit, and one key for every aura stopped saving at 49 of them.
---
--- Only auras whose Version moved are encoded, and only changed forms are
--- written, at most MAX_WRITES_PER_SAVE per call; SavePending finishes the
--- rest. Each write is read back, retried next save if it didn't take, with
--- one warning. The index goes last, once every aura's key has taken; then
--- keys of deleted auras are cleared.
function auraPersistence.Save()
    -- Until a load has filled the list, a save would write an incomplete one
    -- over what's saved. A requested save stays waiting.
    if loading ~= nil then return end
    -- This save covers every change a waiting request was for.
    quietFramesLeft, maxFramesLeft = nil, nil
    local orderedIDs, presentIDs = {}, {}
    local failedAura = nil
    local writeCount, pending = 0, false
    for index, aura in ipairs(storedAuras.List()) do
        local auraID = aura.id
        orderedIDs[index] = auraID
        presentIDs[auraID] = true
        local version = storedAuras.Version(auraID)
        local changed = savedVersions[auraID] ~= version
        if changed and writeCount >= MAX_WRITES_PER_SAVE then
            pending = true
        elseif changed then
            local copy = auraRecord.ToSaved(aura)
            local form = serializer.Encode(copy)
            if savedForms[auraID] == form then
                savedVersions[auraID] = version
            else
                writeCount = writeCount + 1
                if writeAura(auraID, copy) then
                    savedForms[auraID], savedVersions[auraID] = form, version
                else
                    failedAura = failedAura or aura
                end
            end
        end
    end
    savePending = pending
    if failedAura ~= nil and not warnedAuraFailed then
        warnedAuraFailed = true
        log(formatStr("Rune Auras: the aura \"{}\" couldn't be saved (it may be too big); its changes may be lost on reload.",
            tostring(failedAura.name)))
    end
    -- The index waits for the rest of the writes, so it never lists an aura
    -- whose key isn't written yet. Writing it also replaces the old save's
    -- list, the only copy of an aura whose own key didn't take, so that
    -- waits until they all have.
    if pending or (failedAura ~= nil and legacySave) then return end
    -- An aura that didn't take still has its typed text on disk.
    if failedAura == nil then textsPending = false end
    clearDeletedKeys(presentIDs)
    local took = writeIndex(orderedIDs)
    if took then legacySave = false end
    if not took and not warnedSaveFailed then
        warnedSaveFailed = true
        log("Rune Auras: your auras couldn't be saved; changes since loading may be lost on reload.")
    end
end

--- Debounces a save: it runs once changes stop, after SAVE_DELAY_FRAMES
--- with no new request, or MAX_SAVE_DELAY_FRAMES after the first. Changes
--- are in memory (and drawn) at once; only writing them waits. See SaveNow
--- for when no later frame may come.
function auraPersistence.RequestSave()
    quietFramesLeft = SAVE_DELAY_FRAMES
    maxFramesLeft = maxFramesLeft or MAX_SAVE_DELAY_FRAMES
end

--- Runs a requested save when it's due, and carries on a save that had
--- more to write than one call takes (see Save). Call every frame.
function auraPersistence.SavePending()
    if quietFramesLeft ~= nil then
        quietFramesLeft, maxFramesLeft = quietFramesLeft - 1, maxFramesLeft - 1
        local isDue = quietFramesLeft <= 0 or maxFramesLeft <= 0
        if isDue then auraPersistence.Save() end
        return
    end
    if savePending then auraPersistence.Save() end
end

--- Saves a requested or unfinished save straight away, e.g. on leaving the
--- game or unloading. Still at most MAX_WRITES_PER_SAVE auras: the rest wait
--- for SavePending, if another frame comes.
function auraPersistence.SaveNow()
    if quietFramesLeft ~= nil or savePending then auraPersistence.Save() end
end

--- Whether the loaded auras still use group positions from before group
--- points (see auraGroups.MigratePositions).
---@return boolean
function auraPersistence.PositionsPending()
    return positionsPending
end

--- Notes that positions have been migrated, so the next save records the
--- current positions version.
function auraPersistence.PositionsMigrated()
    positionsPending = false
end

return auraPersistence
