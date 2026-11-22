-- The auras selected in the main window's list: one, several (Ctrl or Shift
-- clicks), or none. The primary is the one clicked last, which a single
-- selection edits and a Shift click ranges from.

local auraStore = require("Auras/Store/aura-store")

local auraSelection = {}

---@type integer[] The selected ids, in the order they were selected.
local ids = {}
---@type table<integer, boolean> The same ids, for lookups.
local chosen = {}
---@type integer?
local primary = nil

--- Selects nothing.
function auraSelection.Clear()
    ids, chosen, primary = {}, {}, nil
end

--- Selects one aura alone, or nothing.
---@param auraID integer? nil for none.
function auraSelection.Only(auraID)
    auraSelection.Clear()

    if auraID ~= nil then
        ids, chosen, primary = { auraID }, { [auraID] = true }, auraID
    end
end

--- Adds an aura to the selection, as the primary, or takes it out (the
--- last one still selected becoming the primary).
---@param auraID integer
function auraSelection.Toggle(auraID)
    if not chosen[auraID] then
        ids[#ids + 1] = auraID
        chosen[auraID] = true
        primary = auraID
        return
    end

    chosen[auraID] = nil

    for index, id in ipairs(ids) do
        if id == auraID then
            table.remove(ids, index)
            break
        end
    end

    primary = ids[#ids]
end

--- Selects every aura from the primary to one, inclusive, in the order the
--- list shows them, replacing the selection. The primary stays, so another
--- Shift click ranges from the same place. Without a primary in the list,
--- it selects that aura alone.
---@param auraID integer
---@param shownIDs integer[] The list's rows, top to bottom.
function auraSelection.Range(auraID, shownIDs)
    local fromIndex, toIndex
    for index, id in ipairs(shownIDs) do
        if id == primary then
            fromIndex = index
        end

        if id == auraID then
            toIndex = index
        end
    end

    if fromIndex == nil or toIndex == nil then
        auraSelection.Only(auraID)
        return
    end

    local anchor = primary
    auraSelection.Clear()
    local step = fromIndex <= toIndex and 1 or -1
    for index = fromIndex, toIndex, step do
        local id = shownIDs[index]
        ids[#ids + 1] = id
        chosen[id] = true
    end

    primary = anchor
end

--- The selected ids, in the order they were selected. Not to be changed.
---@return integer[]
function auraSelection.IDs()
    return ids
end

--- The selected ids as a set. Not to be changed.
---@return table<integer, boolean>
function auraSelection.Set()
    return chosen
end

---@return integer
function auraSelection.Count()
    return #ids
end

---@param auraID integer?
---@return boolean
function auraSelection.Has(auraID)
    return auraID ~= nil and chosen[auraID] == true
end

--- The aura clicked last, which a single selection edits.
---@return integer? auraID nil with nothing selected.
function auraSelection.Primary()
    return primary
end

--- Drops auras that no longer exist (deleted), keeping the rest.
---@return boolean changed Whether any was dropped.
function auraSelection.Prune()
    local kept = {}
    for _, id in ipairs(ids) do
        if auraStore.Get(id) ~= nil then
            kept[#kept + 1] = id
        end
    end

    if #kept == #ids then
        return false
    end

    local keptPrimary = auraStore.Get(primary) ~= nil and primary or kept[#kept]
    auraSelection.Clear()

    for _, id in ipairs(kept) do
        ids[#ids + 1] = id
        chosen[id] = true
    end

    primary = keptPrimary
    return true
end

--- Whether an aura is inside a selected group, at any depth.
---@param aura Aura
---@return boolean
local function isInSelectedGroup(aura)
    local seen = {}
    local groupID = aura.group

    -- A damaged save's loop of groups ends when a group comes round again.
    while groupID ~= nil and not seen[groupID] do
        if chosen[groupID] then
            return true
        end

        seen[groupID] = true
        local group = auraStore.Get(groupID)
        groupID = group and group.group
    end

    return false
end

--- The selected auras that aren't inside another selected group, in list
--- order: what moving or grouping the selection moves, as a selected
--- group takes its contents with it.
---@return Aura[]
function auraSelection.Roots()
    local roots = {}
    for _, aura in ipairs(auraStore.List()) do
        if chosen[aura.id] and not isInSelectedGroup(aura) then
            roots[#roots + 1] = aura
        end
    end

    return roots
end

--- The display type every selected aura has, when they all have the same
--- one and none is a group: what lets them be edited together.
---@return DisplayID? display nil otherwise (or with nothing selected).
function auraSelection.SharedDisplay()
    local display = nil
    for _, auraID in ipairs(ids) do
        local aura = auraStore.Get(auraID)
        if aura == nil or auraStore.IsGroup(aura) or (display ~= nil and aura.display ~= display) then
            return nil
        end

        display = aura.display
    end

    return display
end

--- The selected ids with the primary first, for editing them together
--- (its values are the ones shown).
---@return integer[]
function auraSelection.PrimaryFirst()
    local ordered = { primary }
    for _, auraID in ipairs(ids) do
        if auraID ~= primary then
            ordered[#ordered + 1] = auraID
        end
    end

    return ordered
end

--- Roots' ids.
---@return integer[]
function auraSelection.RootIDs()
    local rootIDs = {}
    for _, aura in ipairs(auraSelection.Roots()) do
        rootIDs[#rootIDs + 1] = aura.id
    end

    return rootIDs
end

return auraSelection
