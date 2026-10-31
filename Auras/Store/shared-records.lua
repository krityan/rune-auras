-- The store's side of sharing: auras out as saved records, and records
-- back in as new auras. The text format belongs to Auras/Sharing/aura-share.

local auraGroups = require("Auras/Store/groups")
local auraPersistence = require("Auras/Store/persistence")
local auraRecord = require("Auras/Store/aura-record")
local auraTexts = require("Auras/Store/aura-texts")
local storedAuras = require("Auras/Store/stored-auras")

local sharedRecords = {}

--- An aura or group and everything in it as saved records. The first
--- record is the aura itself, moved to the top level at the same place on
--- screen. Each group comes before its contents. `unlocked` is left out.
---@param auraID integer
---@param areaWidth number? Game area width; without the size, the first record keeps its group offset.
---@param areaHeight number?
---@return table[]? records Saved forms (see auraRecord.ToSaved); nil if there's no such aura.
function sharedRecords.Export(auraID, areaWidth, areaHeight)
    local exported = storedAuras.Get(auraID)
    if exported == nil then return nil end
    local records = {}
    --- Appends an aura's record, then its contents', depth first.
    ---@param aura Aura
    local function add(aura)
        local record = auraRecord.ToSaved(aura)
        record.unlocked = nil
        records[#records + 1] = record
        for _, child in ipairs(storedAuras.Children(aura.id)) do add(child) end
    end
    add(exported)
    local exportedRecord = records[1]
    if exported.group ~= nil and areaWidth ~= nil and areaHeight ~= nil then
        local pointX, pointY = auraGroups.ScreenPoint(exported, areaWidth, areaHeight)
        exportedRecord.x, exportedRecord.y = auraGroups.TopLevelOffset(exported, pointX, pointY,
            areaWidth, areaHeight)
    end
    exportedRecord.group = nil
    return records
end

--- What an empty record of a display type loads as, in saved form, so
--- sharing can leave out fields at these values. Text nodes aren't
--- included (see auraTexts.Defaults).
---@param display DisplayID
---@return table record
function sharedRecords.LoadDefaults(display)
    local blank = auraRecord.FromSaved({ id = 0, display = display })
    blank.texts = nil
    return auraRecord.ToSaved(blank)
end

--- What a text node's missing fields load as on a record (see auraTexts.Defaults).
---@type fun(record: table): TextNode
sharedRecords.TextDefaults = auraTexts.Defaults

--- The work of Import, which undoes it if this errors.
---@param records table[]
---@param made Aura[] Each aura made is appended to it.
local function addRecords(records, made)
    local newIDs = {}
    for _, record in ipairs(records) do
        local copy = {}
        for key, value in pairs(record) do copy[key] = value end
        local parentID = record.group ~= nil and newIDs[record.group] or nil
        -- Only taken once the record loads, so a bad one uses up no id.
        copy.id, copy.group, copy.unlocked = storedAuras.NextID(), nil, false
        local aura = auraRecord.FromSaved(copy)
        if aura ~= nil then
            -- An id seen twice keeps its first meaning.
            if record.id ~= nil and newIDs[record.id] == nil then newIDs[record.id] = aura.id end
            storedAuras.TakeID()
            storedAuras.Add(aura)
            storedAuras.Touch(aura)
            made[#made + 1] = aura
            local parent = parentID ~= nil and storedAuras.Get(parentID) or nil
            if parent ~= nil and auraRecord.CanHold(parent, aura) then aura.group = parentID end
        end
    end
end

--- Adds shared records as new, locked auras with new ids, loaded as saved
--- ones are, and saves. A record keeps its group only if that group came
--- earlier in the list (no cycles) and can hold it; the rest, the exported
--- aura first, go at the top level, where Export placed them on screen.
--- Never into the selected group: a group imported into the one it came
--- from looked like nothing had happened.
---
--- On an error nothing is added, and the error is raised again.
---@param records table[] As Export makes them, already checked by Auras/Sharing/aura-share.
---@return Aura[] made In order.
function sharedRecords.Import(records)
    local made = {}
    local countBefore, freeIDBefore = storedAuras.Mark()
    local ok, problem = pcall(addRecords, records, made)
    if not ok then
        -- Nothing half-imported: the new auras were added at the end, and
        -- only they were changed.
        storedAuras.RollBack(countBefore, freeIDBefore)
        error(problem, 0)
    end
    auraPersistence.RequestSave()
    return made
end

return sharedRecords
