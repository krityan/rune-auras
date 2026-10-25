-- The auras in memory: the list in order, the next free id, and each
-- aura's version (how many times it changed). Only the Store's own files
-- change them; everything else goes through Auras/Store/aura-store.

local storedAuras = {}

---@type Aura[] Every aura and group, in list order.
local auras = {}
local nextID = 1
---@type table<integer, integer> Aura id to its Version. Not saved.
local versions = {}

--- Every aura and group, in list order. The live list: change it only
--- through Add, Remove and Replace.
---@return Aura[]
function storedAuras.List()
    return auras
end

--- An aura's place in the list.
---@param auraID integer?
---@return integer? index nil if there's no such aura.
function storedAuras.IndexOf(auraID)
    for index, aura in ipairs(auras) do
        if aura.id == auraID then return index end
    end
    return nil
end

--- The stored aura itself (not a copy), to read.
---@param auraID integer?
---@return Aura? aura nil if there's no such aura.
function storedAuras.Get(auraID)
    local index = storedAuras.IndexOf(auraID)
    return index and auras[index] or nil
end

--- The group an aura sits in. Skips the list search at the top level.
---@param aura Aura
---@return Aura? group nil at the top level, or if its group is gone.
function storedAuras.ParentOf(aura)
    if aura.group == nil then return nil end
    return storedAuras.Get(aura.group)
end

--- The auras and groups directly inside a group, in list order.
---@param groupID integer? nil for the top level.
---@return Aura[] children A new list.
function storedAuras.Children(groupID)
    local children = {}
    for _, aura in ipairs(auras) do
        if aura.group == groupID then children[#children + 1] = aura end
    end
    return children
end

--- How many times an aura has changed this session. The aura manager
--- re-applies, and Save writes, only auras whose version moved.
---@param auraID integer
---@return integer
function storedAuras.Version(auraID)
    return versions[auraID] or 0
end

--- Marks an aura changed (see Version). Anything changing an aura must, or
--- the change is neither drawn nor saved.
---@param aura Aura
function storedAuras.Touch(aura)
    versions[aura.id] = (versions[aura.id] or 0) + 1
end

--- The id for a new aura, used up.
---@return integer
function storedAuras.TakeID()
    local auraID = nextID
    nextID = nextID + 1
    return auraID
end

--- The id the next new aura will get, for the save's index.
---@return integer
function storedAuras.NextID()
    return nextID
end

--- Puts an aura in the list.
---@param aura Aura
---@param index integer? Its place; nil for the end.
function storedAuras.Add(aura, index)
    table.insert(auras, index or #auras + 1, aura)
end

--- Takes the aura at a place out of the list.
---@param index integer
---@return Aura aura
function storedAuras.Remove(index)
    return table.remove(auras, index)
end

--- Replaces the whole list, as loading does.
---@param list Aura[]
---@param firstFreeID integer The next id to give out; raised past any id in the list.
function storedAuras.Replace(list, firstFreeID)
    auras = list
    nextID = firstFreeID
    for _, aura in ipairs(list) do nextID = math.max(nextID, aura.id + 1) end
end

--- The list's length and next id, to go back to with RollBack.
---@return integer count
---@return integer firstFreeID
function storedAuras.Mark()
    return #auras, nextID
end

--- Drops auras added since Mark and gives their ids back, as a failed
--- import does. Only auras added at the end may have happened since.
---@param count integer
---@param firstFreeID integer
function storedAuras.RollBack(count, firstFreeID)
    for index = #auras, count + 1, -1 do auras[index] = nil end
    nextID = firstFreeID
end

return storedAuras
