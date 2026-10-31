-- Saved auras as the rest of the plugin uses them: lookups, the operations
-- that change auras, and loading and saving. Files outside Auras/Store use
-- only this one; it's built from the folder's other modules. Drawing auras
-- is aura-manager's job.

local anchors = require("Auras/Helpers/anchors")
local conditions = require("Auras/Registries/conditions")
local dataSources = require("Auras/Registries/data-sources")
local auraGroups = require("Auras/Store/groups")
local auraPersistence = require("Auras/Store/persistence")
local auraRecord = require("Auras/Store/aura-record")
local auraTexts = require("Auras/Store/aura-texts")
local savedValues = require("Auras/Store/saved-values")
local sharedRecords = require("Auras/Store/shared-records")
local storedAuras = require("Auras/Store/stored-auras")

local auraStore = {}

local touch = storedAuras.Touch
local save = auraPersistence.RequestSave

-- The other Store modules' functions and constants, exposed here so other
-- folders only use this module. Each is documented where it's defined.
auraStore.DEFAULT_COLOUR = auraRecord.DEFAULT_COLOUR
auraStore.IsColourKey = savedValues.IsColourKey
auraStore.List = storedAuras.List
auraStore.Get = storedAuras.Get
auraStore.Children = storedAuras.Children
auraStore.ChildrenByGroup = storedAuras.ChildrenByGroup
auraStore.TOP_LEVEL = storedAuras.TOP_LEVEL
auraStore.Version = storedAuras.Version
auraStore.IsGroup = auraRecord.IsGroup
auraStore.IsDynamicGroup = auraRecord.IsDynamicGroup
auraStore.CanHold = auraRecord.CanHold
auraStore.HasDefaultName = auraRecord.HasDefaultName
auraStore.NewText = auraTexts.New
auraStore.NextTextKey = auraTexts.NextKey
auraStore.ScreenPoint = auraGroups.ScreenPoint
auraStore.Move = auraGroups.Move
auraStore.ResetGroupOffset = auraGroups.ResetGroupOffset
auraStore.MigratePositions = auraGroups.MigratePositions
auraStore.Load = auraPersistence.Load
auraStore.SavePending = auraPersistence.SavePending
auraStore.SaveNow = auraPersistence.SaveNow
auraStore.ExportRecords = sharedRecords.Export
auraStore.AddImported = sharedRecords.Import
auraStore.LoadDefaults = sharedRecords.LoadDefaults
auraStore.TextDefaults = sharedRecords.TextDefaults

--- Adds a new aura with default options at the end of the list, and saves
--- (see auraRecord.NewAura).
---@param groupID integer? Group to put it in (not checked); nil for the top level.
---@return Aura
function auraStore.Create(groupID)
    local aura = auraRecord.NewAura(storedAuras.TakeID(), groupID)
    storedAuras.Add(aura)
    save()
    return aura
end

--- Adds a new, empty group at the end of the list, and saves.
---@param groupID integer? Parent group (not checked); nil for the top level.
---@return Aura group
function auraStore.CreateGroup(groupID)
    local group = auraRecord.NewGroup(storedAuras.TakeID(), groupID)
    storedAuras.Add(group)
    save()
    return group
end

--- Adds a new, empty dynamic group at the end of the list, and saves. Its
--- parent must not be a dynamic group, which holds auras only.
---@param groupID integer? Parent group (not checked); nil for the top level.
---@return Aura group
function auraStore.CreateDynamicGroup(groupID)
    local group = auraRecord.NewDynamicGroup(storedAuras.TakeID(), groupID)
    storedAuras.Add(group)
    save()
    return group
end

-- How far a copy is nudged from its original, so it doesn't sit exactly on
-- top of it.
local DUPLICATE_OFFSET = 10

--- Moves an offset by DUPLICATE_OFFSET, the other way if that would leave
--- the range that keeps the aura on screen.
---@param offset number
---@param minimum number? nil: no limit.
---@param maximum number?
---@return number
local function nudge(offset, minimum, maximum)
    local nudged = offset + DUPLICATE_OFFSET
    if maximum ~= nil and nudged > maximum then nudged = offset - DUPLICATE_OFFSET end
    if minimum ~= nil then nudged = math.max(minimum, nudged) end
    if maximum ~= nil then nudged = math.min(maximum, nudged) end
    return nudged
end

--- Copies an aura into a new one listed right after it, nudged so it isn't
--- on top of the original, and saves. Locked. A group's contents aren't
--- copied.
---@param auraID integer
---@param areaWidth number? Game area width, to keep the copy on screen.
---@param areaHeight number?
---@return Aura? copy nil if there's no such aura.
function auraStore.Duplicate(auraID, areaWidth, areaHeight)
    local index = storedAuras.IndexOf(auraID)
    if index == nil then return nil end
    local original = storedAuras.List()[index]
    -- A deep copy: conditions, texts and load are nested tables.
    local copy = conditions.Copy(original)
    copy.id = storedAuras.TakeID()
    copy.name = original.name .. " copy"
    copy.unlocked = false
    -- In a group the offset is from the group's point, with no screen edge
    -- to keep inside.
    local minX, maxX, minY, maxY
    if areaWidth ~= nil and areaHeight ~= nil and original.group == nil then
        minX, maxX, minY, maxY = anchors.OffsetRange(original.anchor,
            original.width or 0, original.height or 0, areaWidth, areaHeight)
    end
    copy.x = nudge(original.x or 0, minX, maxX)
    copy.y = nudge(original.y or 0, minY, maxY)
    storedAuras.Add(copy, index + 1)
    save()
    return copy
end

--- Deletes an aura or group, and saves. A group's contents move up a level,
--- staying where they are on screen.
---@param auraID integer
---@param areaWidth number? Game area width; without the size, contents are regrouped but not kept in place.
---@param areaHeight number?
---@return boolean deleted false if there's no such aura.
function auraStore.Delete(auraID, areaWidth, areaHeight)
    local index = storedAuras.IndexOf(auraID)
    if index == nil then return false end
    local aura = storedAuras.List()[index]
    if auraRecord.IsGroup(aura) then
        for _, child in ipairs(storedAuras.List()) do
            if child.group == auraID then auraGroups.Regroup(child, aura.group, areaWidth, areaHeight) end
        end
    end
    storedAuras.Remove(index)
    save()
    return true
end

--- A group's descendants: every aura and group inside it, at any depth.
---@param groupID integer
---@return table<integer, boolean> descendants Their ids.
local function descendantsOf(groupID)
    local descendants = { [groupID] = true }
    -- A descendant can come before its group in the list, so it's walked
    -- until a pass finds nothing new.
    local found = true
    while found do
        found = false
        for _, aura in ipairs(storedAuras.List()) do
            if aura.group ~= nil and descendants[aura.group] and not descendants[aura.id] then
                descendants[aura.id] = true
                found = true
            end
        end
    end
    descendants[groupID] = nil
    return descendants
end

--- How many descendants a group has: auras and groups at any depth.
---@param groupID integer
---@return integer
function auraStore.DescendantCount(groupID)
    local count = 0
    for _ in pairs(descendantsOf(groupID)) do count = count + 1 end
    return count
end

--- Deletes a group and everything in it, at any depth, and saves. An aura
--- that isn't a group is deleted alone.
---@param auraID integer
---@return boolean deleted false if there's no such aura.
function auraStore.DeleteWithContents(auraID)
    if storedAuras.IndexOf(auraID) == nil then return false end
    local doomed = descendantsOf(auraID)
    doomed[auraID] = true
    local list = storedAuras.List()
    for index = #list, 1, -1 do
        if doomed[list[index].id] then storedAuras.Remove(index) end
    end
    save()
    return true
end

--- Deletes every aura and group, and saves, which clears each one's saved
--- key. Ids aren't reused afterwards.
---@return integer count How many auras and groups were deleted.
function auraStore.DeleteAll()
    local count = #storedAuras.List()
    storedAuras.Replace({}, storedAuras.NextID())
    save()
    return count
end

--- Sets one of an aura's fields, touches it and saves (see auraRecord.SetField).
---@param auraID integer
---@param key string An Aura field, or a display type option.
---@param value any
---@return Aura? aura nil if there's no such aura.
function auraStore.Set(auraID, key, value)
    local aura = storedAuras.Get(auraID)
    if aura == nil then return nil end
    auraRecord.SetField(aura, key, value)
    touch(aura)
    save()
    return aura
end

--- Changes an aura in place, then tidies, touches and saves it: for nested
--- fields (conditions, load, texts) or several fields at once. One field is
--- Set's job.
---@param auraID integer
---@param change fun(aura: Aura) Writes the aura's fields.
---@return Aura? aura nil if there's no such aura; change isn't called.
function auraStore.Edit(auraID, change)
    local aura = storedAuras.Get(auraID)
    if aura == nil then return nil end
    change(aura)
    auraRecord.Tidy(aura)
    touch(aura)
    save()
    return aura
end

--- Moves an aura's offset to a new anchor without moving it on screen, and
--- saves. In a group the anchor is the aura's attach point, and its group's
--- point stays put.
---@param auraID integer
---@param anchorID AnchorID
---@param width number The aura's size on screen.
---@param height number
---@param areaWidth number? Game area width. Without it, a top-level aura only changes anchor.
---@param areaHeight number?
function auraStore.SetAnchor(auraID, anchorID, width, height, areaWidth, areaHeight)
    auraStore.Edit(auraID, function(aura)
        if aura.group ~= nil then
            local left, top = anchors.FromPoint(aura.anchor, aura.x, aura.y, width, height, 0, 0)
            aura.x, aura.y = anchors.ToPoint(anchorID, left, top, width, height, 0, 0)
        elseif areaWidth ~= nil and areaHeight ~= nil then
            local left, top = anchors.ToScreen(aura.anchor, aura.x, aura.y, width, height, areaWidth, areaHeight)
            aura.x, aura.y = anchors.FromScreen(anchorID, left, top, width, height, areaWidth, areaHeight)
        end
        aura.anchor = anchorID
    end)
end

--- Calls a function for an aura and each of its checks (conditions' and
--- load's): every table of it with a `source` field.
---@param aura Aura
---@param fn fun(holder: Aura|Check, aura: Aura)
local function forAuraSourceHolders(aura, fn)
    fn(aura, aura)
    for _, condition in ipairs(aura.conditions or {}) do
        for _, check in ipairs(condition.checks or {}) do fn(check, aura) end
    end
    for _, check in ipairs(aura.load and aura.load.checks or {}) do fn(check, aura) end
end

--- forAuraSourceHolders over every aura.
---@param fn fun(holder: Aura|Check, aura: Aura)
local function forEachSourceHolder(fn)
    for _, aura in ipairs(storedAuras.List()) do forAuraSourceHolders(aura, fn) end
end

--- Whether an aura shows, or one of its checks reads, a source that passes a test.
---@param aura Aura
---@param test fun(sourceID: string): boolean
---@return boolean
function auraStore.ReadsSource(aura, test)
    local reads = false
    forAuraSourceHolders(aura, function(holder)
        if holder.source ~= nil and test(holder.source) then reads = true end
    end)
    return reads
end

--- Every data source an aura shows or a check reads.
---@return table<string, boolean> used Source id to true.
function auraStore.UsedSources()
    local used = {}
    forEachSourceHolder(function(holder)
        if holder.source ~= nil then used[holder.source] = true end
    end)
    return used
end

--- Gives sources saved with an id that's since moved (a buff's duplicate, a
--- channel that was a buff) the new one, and saves once if any moved. Load
--- does this too, but ids only resolve once the catalogues are readable.
---@return boolean moved
function auraStore.MigrateSources()
    local moved = false
    forEachSourceHolder(function(holder, aura)
        local currentID = holder.source ~= nil and dataSources.CurrentID(holder.source) or nil
        if currentID == holder.source then return end
        holder.source = currentID
        -- A check notes the type its source was picked from, and a source
        -- can move to another type (a channel that was a buff).
        local source = currentID ~= nil and dataSources.Get(currentID) or nil
        if holder.sourceType ~= nil and source ~= nil then holder.sourceType = source.type end
        touch(aura)
        moved = true
    end)
    if moved then save() end
    return moved
end

return auraStore
