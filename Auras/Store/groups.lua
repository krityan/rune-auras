-- Where auras sit in groups: each record's point on screen, and moving
-- auras between groups and along the list while keeping them where they
-- are on screen.

local anchors = require("Auras/Helpers/anchors")
local auraRecord = require("Auras/Store/aura-record")
local auraPersistence = require("Auras/Store/persistence")
local storedAuras = require("Auras/Store/stored-auras")

local auraGroups = {}

-- A point has no size: passed to anchors as the width and height.
local NO_SIZE = 0

local touch = storedAuras.Touch

--- Where an aura's point is on screen: for a group, the point its contents
--- are placed from; for an aura, its attach point (its anchor's spot on
--- it). Sizes cancel out, so only the game area's is needed.
---@param aura Aura
---@param areaWidth number Game area width.
---@param areaHeight number
---@return number x
---@return number y
function auraGroups.ScreenPoint(aura, areaWidth, areaHeight)
    local x, y, visited = 0, 0, {}
    while aura ~= nil and not visited[aura.id] do
        visited[aura.id] = true
        local group = storedAuras.ParentOf(aura)
        if group == nil then
            local left, top = anchors.ToScreen(aura.anchor, aura.x or 0, aura.y or 0, NO_SIZE, NO_SIZE,
                areaWidth, areaHeight)
            return x + left, y + top
        end

        local dx, dy = anchors.ScreenDelta(aura.x or 0, aura.y or 0)
        x, y = x + dx, y + dy
        aura = group
    end

    return x, y
end

--- A top-level offset from the screen anchor that puts an aura's point at
--- a screen position, as if it had no group.
---@param aura Aura
---@param pointX number Screen x.
---@param pointY number
---@param areaWidth number Game area width.
---@param areaHeight number
---@return number x
---@return number y
function auraGroups.TopLevelOffset(aura, pointX, pointY, areaWidth, areaHeight)
    return anchors.FromScreen(aura.anchor, pointX, pointY, NO_SIZE, NO_SIZE, areaWidth, areaHeight)
end

--- Sets an aura's x/y so its point (see ScreenPoint) is at pointX, pointY.
---@param aura Aura Changed in place and touched.
---@param pointX number Screen x.
---@param pointY number
---@param areaWidth number Game area width.
---@param areaHeight number
local function placeAt(aura, pointX, pointY, areaWidth, areaHeight)
    local group = storedAuras.ParentOf(aura)
    if group ~= nil then
        local groupX, groupY = auraGroups.ScreenPoint(group, areaWidth, areaHeight)
        aura.x, aura.y = anchors.ScreenDelta(pointX - groupX, pointY - groupY)
    else
        aura.x, aura.y = auraGroups.TopLevelOffset(aura, pointX, pointY, areaWidth, areaHeight)
    end

    touch(aura)
end

--- Puts an aura in another group, keeping it where it is on screen. Doesn't
--- check the group can hold it, and doesn't save.
---@param aura Aura Changed in place and touched.
---@param groupID integer? nil for the top level.
---@param areaWidth number? Game area width; without the size it's regrouped but not kept in place.
---@param areaHeight number?
function auraGroups.Regroup(aura, groupID, areaWidth, areaHeight)
    if areaWidth == nil or areaHeight == nil then
        aura.group = groupID
        touch(aura)
        return
    end

    local pointX, pointY = auraGroups.ScreenPoint(aura, areaWidth, areaHeight)
    aura.group = groupID
    placeAt(aura, pointX, pointY, areaWidth, areaHeight)
end

--- Puts a group's point back on its anchor (or its parent's point), moving
--- a plain group's contents the other way so nothing moves on screen. A
--- dynamic group's contents grow from its point, so they move with it.
--- Saves on change.
---@param groupID integer
---@param areaWidth number Game area width.
---@param areaHeight number
---@return boolean changed false if it isn't a group or has no offset.
function auraGroups.ResetGroupOffset(groupID, areaWidth, areaHeight)
    local group = storedAuras.Get(groupID)
    if not auraRecord.IsGroup(group) then
        return false
    end

    local hasOffset = (group.x or 0) ~= 0 or (group.y or 0) ~= 0
    if not hasOffset then
        return false
    end

    local oldX, oldY = auraGroups.ScreenPoint(group, areaWidth, areaHeight)
    group.x, group.y = 0, 0
    touch(group)

    if not auraRecord.IsDynamicGroup(group) then
        local newX, newY = auraGroups.ScreenPoint(group, areaWidth, areaHeight)
        for _, child in ipairs(storedAuras.List()) do
            if child.group == groupID then
                local dx, dy = anchors.ScreenDelta(oldX - newX, oldY - newY)
                child.x, child.y = (child.x or 0) + dx, (child.y or 0) + dy
                touch(child)
            end
        end
    end

    auraPersistence.RequestSave()
    return true
end

--- Converts a save from before group points (see persistence's
--- POSITIONS_VERSION) once the game area's size is known: each aura in a group
--- keeps its screen spot, measured from the group's point. Saves on change.
---@param areaWidth number Game area width.
---@param areaHeight number
---@return boolean converted false if there was nothing to convert.
function auraGroups.MigratePositions(areaWidth, areaHeight)
    if not auraPersistence.PositionsPending() then
        return false
    end

    auraPersistence.PositionsMigrated()

    for _, aura in ipairs(storedAuras.List()) do
        local inGroup = storedAuras.ParentOf(aura) ~= nil
        -- A plain group's offset from its parent already worked as it does now.
        local isPlainGroup = auraRecord.IsGroup(aura) and not auraRecord.IsDynamicGroup(aura)
        if inGroup and not isPlainGroup then
            -- Its old screen spot, as an offset (right and up) from the
            -- group's point, which was the screen's top left.
            aura.x, aura.y = anchors.ScreenDelta(anchors.ToScreen(aura.anchor, aura.x or 0, aura.y or 0, NO_SIZE,
                NO_SIZE, areaWidth, areaHeight))
            touch(aura)
        end
    end

    auraPersistence.RequestSave()
    return true
end

--- Whether `auraID` is `groupID` or one of the groups it sits in, so
--- moving the aura there would put a group inside itself.
---@param auraID integer
---@param groupID integer?
---@return boolean
local function containsGroup(auraID, groupID)
    local visited = {}
    while groupID ~= nil and not visited[groupID] do
        if groupID == auraID then
            return true
        end

        visited[groupID] = true
        local group = storedAuras.Get(groupID)
        groupID = group and group.group or nil
    end

    return false
end

--- The list index just after a group's last item: the very end if it has
--- none.
---@param groupID integer? nil for the top level.
---@return integer
local function afterLastInGroup(groupID)
    local auras = storedAuras.List()
    for index = #auras, 1, -1 do
        if auras[index].group == groupID then
            return index + 1
        end
    end

    return #auras + 1
end

--- Moves an aura or group to a new place in the list, keeping it where it
--- is on screen. Refuses a missing group, one that can't hold it, a group
--- going into itself, or a `beforeID` outside the group. Saves on change.
---@param auraID integer
---@param groupID integer? Destination group; nil for the top level.
---@param beforeID integer? Item in that group to go before; nil for after them all.
---@param areaWidth number? Game area width; without the size it's regrouped but not kept in place.
---@param areaHeight number?
---@return boolean moved
function auraGroups.Move(auraID, groupID, beforeID, areaWidth, areaHeight)
    local fromIndex = storedAuras.IndexOf(auraID)
    if fromIndex == nil or beforeID == auraID then
        return false
    end

    local aura = storedAuras.List()[fromIndex]
    if groupID ~= nil then
        if not auraRecord.CanHold(storedAuras.Get(groupID), aura) then
            return false
        end

        if containsGroup(auraID, groupID) then
            return false
        end
    end

    local before = beforeID ~= nil and storedAuras.Get(beforeID) or nil
    if beforeID ~= nil and (before == nil or before.group ~= groupID) then
        return false
    end

    storedAuras.Remove(fromIndex)
    local toIndex = before ~= nil and storedAuras.IndexOf(beforeID) or afterLastInGroup(groupID)
    storedAuras.Add(aura, toIndex)

    local moved = toIndex ~= fromIndex or aura.group ~= groupID

    -- In or out of a dynamic group, it's the aura's position (unused while
    -- it's in one) that's kept in place.
    if aura.group ~= groupID then
        auraGroups.Regroup(aura, groupID, areaWidth, areaHeight)
    end

    if moved then
        auraPersistence.RequestSave()
    end

    return moved
end

--- Where moved items go before once they've left their places: `beforeID`,
--- or if that's one of them, the next item in its group that isn't.
---@param groupID integer? The group `beforeID` is in.
---@param beforeID integer?
---@param moving table<integer, boolean> The ids being moved.
---@return integer? beforeID nil for after the group's last item.
local function firstNotMoving(groupID, beforeID, moving)
    if beforeID == nil or not moving[beforeID] then
        return beforeID
    end

    local passed = false
    for _, aura in ipairs(storedAuras.List()) do
        if aura.group == groupID then
            if aura.id == beforeID then
                passed = true
            elseif passed and not moving[aura.id] then
                return aura.id
            end
        end
    end

    return nil
end

--- Moves several auras or groups to one place in the list, as Move does
--- one, keeping their order and where they are on screen. Refuses them all
--- if any can't go there, so a move never half happens. Saves on change.
---@param auraIDs integer[] In list order, none inside another of them.
---@param groupID integer? Destination group; nil for the top level.
---@param beforeID integer? Item in that group to go before (one of them is allowed); nil for after them all.
---@param areaWidth number? Game area width; without the size they're regrouped but not kept in place.
---@param areaHeight number?
---@return boolean moved
function auraGroups.MoveMany(auraIDs, groupID, beforeID, areaWidth, areaHeight)
    local group = groupID ~= nil and storedAuras.Get(groupID) or nil
    if groupID ~= nil and group == nil then
        return false
    end

    local moving = {}
    for _, auraID in ipairs(auraIDs) do
        local aura = storedAuras.Get(auraID)
        local canGo = aura ~= nil and (groupID == nil
            or (auraRecord.CanHold(group, aura) and not containsGroup(auraID, groupID)))
        if not canGo then
            return false
        end

        moving[auraID] = true
    end

    beforeID = firstNotMoving(groupID, beforeID, moving)
    local before = beforeID ~= nil and storedAuras.Get(beforeID) or nil
    if beforeID ~= nil and (before == nil or before.group ~= groupID) then
        return false
    end

    local moved = false
    for _, auraID in ipairs(auraIDs) do
        if auraGroups.Move(auraID, groupID, beforeID, areaWidth, areaHeight) then
            moved = true
        end
    end

    return moved
end

return auraGroups
