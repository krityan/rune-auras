-- A list of names or ids remembered between sessions: saved in PersistentDB
-- under one key as a sorted, comma-separated string, and read on first use.

---@alias RememberedEntry string|integer

---@class RememberedListOptions
---@field numeric boolean? Entries are integer ids rather than names.
---@field keep (fun(entry: RememberedEntry): boolean)? Whether an entry is still worth saving; others are left out of the next save.

---@class RememberedList
---@field private key string
---@field private numeric boolean
---@field private keep (fun(entry: RememberedEntry): boolean)?
---@field private entries table<RememberedEntry, true>? nil until first used.
local RememberedList = {}
RememberedList.__index = RememberedList

local rememberedList = {}

local SEPARATOR = ","
local NAME_PATTERN = "[^,]+"
local ID_PATTERN = "%d+"

--- A list remembered under a PersistentDB key. Nothing is read until it's used.
---@param key string
---@param options RememberedListOptions?
---@return RememberedList
function rememberedList.new(key, options)
    options = options or {}
    local self = setmetatable({}, RememberedList)
    self.key = key
    self.numeric = options.numeric == true
    self.keep = options.keep
    self.entries = nil
    return self
end

--- The entries, read from PersistentDB the first time.
---@return table<RememberedEntry, true>
---@private
function RememberedList:load()
    if self.entries ~= nil then
        return self.entries
    end

    self.entries = {}
    local saved = tostring(PersistentDB:GetString(self.key) or "")
    local pattern = self.numeric and ID_PATTERN or NAME_PATTERN

    for text in saved:gmatch(pattern) do
        local entry = self.numeric and tonumber(text) or text
        self.entries[entry] = true
    end

    return self.entries
end

--- Writes the entries worth keeping, sorted.
---@private
function RememberedList:save()
    local list = {}

    for entry in pairs(self.entries) do
        if self.keep == nil or self.keep(entry) then
            list[#list + 1] = entry
        end
    end

    table.sort(list)
    PersistentDB:SetString(self.key, table.concat(list, SEPARATOR))
end

--- Whether an entry is on the list.
---@param entry RememberedEntry
---@return boolean
function RememberedList:Contains(entry)
    return self:load()[entry] == true
end

--- Adds an entry, and saves the list if it wasn't on it.
---@param entry RememberedEntry
function RememberedList:Add(entry)
    local entries = self:load()
    if entries[entry] then
        return
    end

    entries[entry] = true
    self:save()
end

--- Removes an entry, and saves the list if it was on it.
---@param entry RememberedEntry
function RememberedList:Remove(entry)
    local entries = self:load()
    if not entries[entry] then
        return
    end

    entries[entry] = nil
    self:save()
end

return rememberedList
