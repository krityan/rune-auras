-- The items worn in each slot, with their names. The plugin API's item
-- configs don't give an item's slot, so item-slot-data.lua lists them. Items
-- added to the game since it was made aren't listed.

local gameApi = require("GameData/game-api")
local SLOT_ITEMS = require("GameData/Catalogues/item-slot-data")

local itemSlots = {}

---@class NamedItem
---@field id integer
---@field name string
---@field label string Its name, followed by what sets it apart from items with the same name, e.g. "Death guard (tier 70)".

---@type table<integer, NamedItem[]> Slot to its named items; listed on first use.
local namedBySlot = {}

--- Orders items by name, then id.
---@param first NamedItem
---@param second NamedItem
---@return boolean
local function byName(first, second)
    if first.name ~= second.name then return first.name < second.name end
    return first.id < second.id
end

--- The words of an item's config name, split at underscores
--- (NECRO_UNDERWORLD_ARMGUARD_T70).
---@param itemID integer
---@return string[] words Empty if it has no config name.
local function configWords(itemID)
    local words = {}
    for word in (gameApi.ItemConfigName(itemID) or ""):gmatch("[^_]+") do words[#words + 1] = word end
    return words
end

--- A config name word as players say it: T70 or TIER70 is "tier 70",
--- anything else lower case.
---@param word string
---@return string
local function readableWord(word)
    local tier = word:match("^T(%d+)$") or word:match("^TIER(%d+)$")
    if tier ~= nil then return "tier " .. tier end
    return word:lower()
end

--- How many words every list has in common at its start, and then at its
--- end (never overlapping the start).
---@param lists string[][]
---@return integer lead
---@return integer tail
local function sharedWords(lists)
    local shortest = math.huge
    for _, words in ipairs(lists) do shortest = math.min(shortest, #words) end
    local function allMatch(pickWord)
        local word = pickWord(lists[1])
        for _, words in ipairs(lists) do
            if pickWord(words) ~= word then return false end
        end
        return true
    end
    local lead = 0
    while lead < shortest and allMatch(function(words) return words[lead + 1] end) do lead = lead + 1 end
    local tail = 0
    while lead + tail < shortest and allMatch(function(words) return words[#words - tail] end) do tail = tail + 1 end
    return lead, tail
end

--- Labels items that share a name by the words their config names don't
--- share ("tier 70", "used"). Where that still leaves two the same, the id
--- tells them apart.
---@param items NamedItem[] Changed in place.
local function labelSameNamed(items)
    local lists = {}
    for index, item in ipairs(items) do lists[index] = configWords(item.id) end
    local lead, tail = sharedWords(lists)
    local parts, partCounts = {}, {}
    for index, words in ipairs(lists) do
        local differing = {}
        for position = lead + 1, #words - tail do differing[#differing + 1] = readableWord(words[position]) end
        parts[index] = table.concat(differing, " ")
        partCounts[parts[index]] = (partCounts[parts[index]] or 0) + 1
    end
    for index, item in ipairs(items) do
        local part = parts[index]
        if partCounts[part] > 1 then part = part == "" and tostring(item.id) or (part .. ", " .. item.id) end
        item.label = part == "" and item.name or (item.name .. " (" .. part .. ")")
    end
end

--- Labels every item: its name, and for items sharing a name, what differs.
---@param named NamedItem[] Sorted by name; changed in place.
local function labelAll(named)
    local first = 1
    while first <= #named do
        local last = first
        while named[last + 1] ~= nil and named[last + 1].name == named[first].name do last = last + 1 end
        if last == first then
            named[first].label = named[first].name
        else
            labelSameNamed(table.move(named, first, last, 1, {}))
        end
        first = last + 1
    end
end

--- A slot's items that have a name (some have an empty one), by name, each
--- labelled. The first call for a slot reads its items' names (up to ~5,000,
--- the main hand), and the config names of those sharing one. Never write to it.
---@param slot integer One of wornEquipment.SLOTS.
---@return NamedItem[]
function itemSlots.Named(slot)
    local named = namedBySlot[slot]
    if named ~= nil then return named end
    named = {}
    for _, itemID in ipairs(SLOT_ITEMS[slot] or {}) do
        local name = gameApi.ItemName(itemID)
        if name ~= nil and name ~= "" then named[#named + 1] = { id = itemID, name = name } end
    end
    table.sort(named, byName)
    labelAll(named)
    namedBySlot[slot] = named
    return named
end

return itemSlots
