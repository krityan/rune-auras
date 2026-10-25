-- Saving and loading the auras in PersistentDB: one key per aura plus an
-- index, written a few at a time and read back (see Save).

local serializer = require("Auras/Helpers/serializer")
local auraRecord = require("Auras/Store/aura-record")
local savedValues = require("Auras/Store/saved-values")
local storedAuras = require("Auras/Store/stored-auras")

local auraPersistence = {}

local STORAGE_KEY = "auras"
-- Each aura's own key is this and its id (see Save).
local AURA_KEY_PREFIX = "aura."
-- Saved with the auras. Before 2, a group's x/y shifted its contents, which
-- kept anchors measured from the screen; see auraGroups.MigratePositions.
local POSITIONS_VERSION = 2
-- What a save without a version, or one still waiting for MigratePositions, has.
local OLD_POSITIONS_VERSION = 1
-- Values read back from PersistentDB may differ by this fraction (it loses precision).
local READ_BACK_TOLERANCE = 1e-3
-- Auras written (and read back) per Save call; SavePending does the rest.
-- The client stops a Lua call after 1s, and a hundred-odd writes went past it.
local MAX_WRITES_PER_SAVE = 16

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
-- Whether the loaded auras still use the old group positions, waiting for
-- MigratePositions.
local positionsPending = false

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

--- The saved records an index points at, read from their own keys. Notes
--- each id in `savedIDs`.
---@param index table The saved index (see Save).
---@return table[] records In list order; missing or damaged keys are skipped.
local function readRecords(index)
    local records = {}
    for _, auraID in ipairs(index.ids) do
        local record = PersistentDB:Get(auraKey(auraID))
        if type(record) == "table" then records[#records + 1] = record end
        savedIDs[auraID] = true
    end
    return records
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

--- Replaces the list with the saved auras (see Save for the layout). Reads
--- the older single-key save too. Drops groups that no longer exist, and
--- notes whether positions need MigratePositions.
function auraPersistence.Load()
    storedAuras.Replace({}, 1)
    savedForms, savedIDs, savedVersions = {}, {}, {}
    legacySave = false
    local index = PersistentDB:Get(STORAGE_KEY)
    if type(index) ~= "table" then return end
    -- Saves before per-aura keys held every aura in the index itself; the
    -- next save moves them to their own keys.
    local hasPerAuraKeys = type(index.ids) == "table"
    legacySave = not hasPerAuraKeys and type(index.auras) == "table"
    local records = hasPerAuraKeys and readRecords(index) or index.auras
    local loaded = {}
    for _, savedAura in ipairs(records or {}) do
        local aura = auraRecord.FromSaved(savedAura)
        if aura ~= nil then loaded[#loaded + 1] = aura end
    end
    storedAuras.Replace(loaded, savedValues.ToInteger(index.nextID) or 1)
    -- What was just loaded is what's on disk, so the next save doesn't
    -- write every aura again (with a few hundred, encoding, writing and
    -- reading them all back went past the client's 1s limit on one call).
    -- What FromSaved fills in is filled in again on every load. The old
    -- single-value save does need every aura written to its own key.
    if not legacySave then
        for _, aura in ipairs(loaded) do savedVersions[aura.id] = storedAuras.Version(aura.id) end
    end
    dropMissingGroups()
    local positionsVersion = savedValues.ToInteger(index.positionsVersion) or OLD_POSITIONS_VERSION
    positionsPending = positionsVersion < POSITIONS_VERSION and anyGrouped()
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
    clearDeletedKeys(presentIDs)
    local took = writeIndex(orderedIDs)
    if took then legacySave = false end
    if not took and not warnedSaveFailed then
        warnedSaveFailed = true
        log("Rune Auras: your auras couldn't be saved; changes since loading may be lost on reload.")
    end
end

--- Carries on a save that had more to write than one call takes (see
--- Save). Call every frame.
function auraPersistence.SavePending()
    if savePending then auraPersistence.Save() end
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
