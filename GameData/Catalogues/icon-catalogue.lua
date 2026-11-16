-- The icons an aura can be given in place of its source's, named so they
-- can be searched: abilities' (with their greater versions, recast stages
-- and commands), buffs' and debuffs', and every wearable item's. Only icons
-- the game itself shows for these are offered, as some sprites crash the
-- client when drawn.

local gameApi = require("GameData/game-api")
local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local itemSlots = require("GameData/Catalogues/item-slots")

local iconCatalogue = {}

---@alias IconKind
---| "ability"
---| "buff"
---| "debuff"
---| "item"

--- An icon on offer.
---@class IconEntry
---@field kind IconKind What it's the icon of: a buff showing an item is still a buff.
---@field sprite integer? Sprite id; nil for an item.
---@field item integer? Item id; nil for a sprite.
---@field name string The name players know it by ("Dragon scimitar").
---@field key string Its struct's or item's config name (COMBATV2_BUFF_BLOOD_TITHE, DRAGON_SCIMITAR).
---@field search string What it's found by: its name, then its key, and those of anything else showing the same icon (a buff's item, the item's own), a line each, in lower case with underscores as spaces.

local LOAD_EVENT_ID = "runeAuras_iconCatalogue"
-- Items whose config names are read per Logic tick.
local CONFIG_NAMES_PER_TICK = 1000
-- The order kinds are listed in.
local KIND_ORDER = { ability = 1, buff = 2, debuff = 3, item = 4 }

--- The abilities' and buffs' icons, and the lists they were built from, to
--- tell when those change.
---@class CatalogueIcons
---@field entries IconEntry[] In listed order.
---@field sprites table<integer, IconEntry> Sprite id to its entry.
---@field items table<integer, IconEntry> Item id to the buff entry showing it.
---@field abilities AbilityEntry[]
---@field abilityCount integer
---@field buffs BuffEntry[]
---@field buffCount integer

--- The wearable items being listed (see LoadItems).
---@class ItemLoad
---@field slots integer[]
---@field slotIndex integer The next slot to read the names of.
---@field named NamedItem[] Every slot's items read so far.
---@field nextNamed integer The next of them to read the config name of.
---@field entries IconEntry[]
---@field onDone fun()

---@type CatalogueIcons?
local built = nil
---@type IconEntry[]? Every wearable item, in listed order, once loaded.
local items = nil
---@type ItemLoad? While items are being listed.
local loading = nil

--- A name and key as an entry's search text (see IconEntry.search).
---@param name string
---@param key string
---@return string
local function searchText(name, key)
    local spacedKey = key:lower():gsub("_", " ")
    return name:lower() .. "\n" .. spacedKey
end

--- Orders entries by kind, then name and key, then id.
---@param first IconEntry
---@param second IconEntry
---@return boolean
local function listedOrder(first, second)
    if first.kind ~= second.kind then return KIND_ORDER[first.kind] < KIND_ORDER[second.kind] end
    if first.search ~= second.search then return first.search < second.search end
    return (first.sprite or first.item) < (second.sprite or second.item)
end

--- Adds a sprite to the catalogue's icons. A sprite already there gets this
--- name and key added to what it's found by.
---@param icons CatalogueIcons
---@param kind IconKind
---@param spriteID number? The sprite id, as read from config; anything but a positive whole number is skipped.
---@param name string
---@param key string
local function addSprite(icons, kind, spriteID, name, key)
    spriteID = spriteID ~= nil and math.tointeger(spriteID) or nil
    if spriteID == nil or spriteID <= 0 then return end
    local search = searchText(name, key)
    local entry = icons.sprites[spriteID]
    if entry ~= nil then
        entry.search = entry.search .. "\n" .. search
        return
    end
    entry = { kind = kind, sprite = spriteID, name = name, key = key, search = search }
    icons.sprites[spriteID] = entry
    icons.entries[#icons.entries + 1] = entry
end

--- Adds a buff's item icon to the catalogue's icons. An item already there
--- gets this buff's name and struct name added to what it's found by. A new
--- one is found by the item's own name and config name too, as it stands
--- in for the item where that's wearable (see Search).
---@param icons CatalogueIcons
---@param buff BuffEntry
local function addBuffItem(icons, buff)
    local itemID = buff.object ~= nil and math.tointeger(buff.object) or nil
    if itemID == nil then return end
    local search = searchText(buff.name, buff.structName)
    local entry = icons.items[itemID]
    if entry ~= nil then
        entry.search = entry.search .. "\n" .. search
        return
    end
    local itemSearch = searchText(gameApi.ItemName(itemID) or "", gameApi.ItemConfigName(itemID) or "")
    entry = { kind = buff.kind, item = itemID, name = buff.name, key = buff.structName,
        search = search .. "\n" .. itemSearch }
    icons.items[itemID] = entry
    icons.entries[#icons.entries + 1] = entry
end

--- Adds every icon an ability can show, each found by the ability's struct name too.
---@param icons CatalogueIcons
---@param ability AbilityEntry
local function addAbility(icons, ability)
    local key = ability.structName or ""
    addSprite(icons, "ability", ability.baseIcon or ability.icon, ability.label, key)
    if ability.greater ~= nil then addSprite(icons, "ability", ability.greater.icon, "Greater " .. ability.label, key) end
    for _, stage in ipairs(ability.stages or {}) do
        addSprite(icons, "ability", stage.icon, stage.label or ability.label, key)
    end
    local command = ability.command
    if command ~= nil then addSprite(icons, "ability", command.icon, command.label or ability.label, key) end
end

--- The abilities', buffs' and debuffs' icons, built again whenever those
--- lists change (the buffs load in the background).
---@return CatalogueIcons
local function catalogueIcons()
    local abilities, buffs = abilityCatalogue.List(), buffCatalogue.List()
    local isCurrent = built ~= nil and built.abilities == abilities and built.abilityCount == #abilities
        and built.buffs == buffs and built.buffCount == #buffs
    if isCurrent then return built end
    local icons = { entries = {}, sprites = {}, items = {}, abilities = abilities, abilityCount = #abilities,
        buffs = buffs, buffCount = #buffs }
    for _, ability in ipairs(abilities) do addAbility(icons, ability) end
    for _, buff in ipairs(buffs) do
        addSprite(icons, buff.kind, buff.icon, buff.name, buff.structName)
        addBuffItem(icons, buff)
    end
    table.sort(icons.entries, listedOrder)
    built = icons
    return icons
end

--- Lists the next part of the wearable items: a slot's names, or once
--- they're all read, a batch of config names. Lists them all when that's done.
local function loadStep()
    local state = loading
    if state == nil then return end
    local slot = state.slots[state.slotIndex]
    if slot ~= nil then
        state.slotIndex = state.slotIndex + 1
        local named = itemSlots.Named(slot)
        table.move(named, 1, #named, #state.named + 1, state.named)
        return
    end
    local last = math.min(#state.named, state.nextNamed + CONFIG_NAMES_PER_TICK - 1)
    for index = state.nextNamed, last do
        local item = state.named[index]
        local key = gameApi.ItemConfigName(item.id) or ""
        state.entries[#state.entries + 1] = { kind = "item", item = item.id, name = item.label, key = key,
            search = searchText(item.label, key) }
    end
    state.nextNamed = last + 1
    if last < #state.named then return end
    Event.Logic.Unsubscribe(LOAD_EVENT_ID)
    loading = nil
    table.sort(state.entries, listedOrder)
    items = state.entries
    state.onDone()
end

--- Lists the wearable items in the background, once a session: a slot's
--- names each Logic tick, then their config names (CONFIG_NAMES_PER_TICK a
--- tick), as reading all of them at once would stall the game. Does nothing
--- once they're listed.
---@param onDone fun() Called once they're listed.
function iconCatalogue.LoadItems(onDone)
    if items ~= nil then return end
    if loading ~= nil then
        loading.onDone = onDone
        return
    end
    loading = { slots = itemSlots.Slots(), slotIndex = 1, named = {}, nextNamed = 1, entries = {}, onDone = onDone }
    Event.Logic.Subscribe(LOAD_EVENT_ID, loadStep)
end

--- Stops listing the items, if it's under way; the next LoadItems starts over.
function iconCatalogue.StopLoading()
    if loading == nil then return end
    Event.Logic.Unsubscribe(LOAD_EVENT_ID)
    loading = nil
end

--- Whether the items are listed, so searches include them.
---@return boolean
function iconCatalogue.ItemsLoaded()
    return items ~= nil
end

--- Whether a search text has every word in it.
---@param search string
---@param words string[]
---@return boolean
local function hasWords(search, words)
    for _, word in ipairs(words) do
        if not search:find(word, 1, true) then return false end
    end
    return true
end

--- The icons found by every word typed (any case, underscores as spaces),
--- in a name or a struct or config name: those whose name starts with what's
--- typed first, then the rest, each in listed order (abilities, buffs,
--- debuffs, then items once they're loaded, each by name). An item a buff
--- shows is listed once, as the buff. Nothing typed lists them all.
---@param query string
---@return IconEntry[]
function iconCatalogue.Search(query)
    local words = {}
    local spaced = query:lower():gsub("_", " ")
    for word in spaced:gmatch("%S+") do words[#words + 1] = word end
    local phrase = table.concat(words, " ")
    local icons = catalogueIcons()
    local starting, containing = {}, {}
    --- Adds a list's matches to those starting or containing what's typed.
    ---@param list IconEntry[]
    local function collect(list)
        for _, entry in ipairs(list) do
            local isBuffItem = entry.kind == "item" and icons.items[entry.item] ~= nil
            if not isBuffItem and hasWords(entry.search, words) then
                local into = entry.search:find(phrase, 1, true) == 1 and starting or containing
                into[#into + 1] = entry
            end
        end
    end
    collect(icons.entries)
    collect(items or {})
    return table.move(containing, 1, #containing, #starting + 1, starting)
end

--- Whether a sprite is one the catalogue offers (an ability's or buff's icon).
---@param spriteID number
---@return boolean
function iconCatalogue.OffersSprite(spriteID)
    return catalogueIcons().sprites[spriteID] ~= nil
end

--- Whether an item is one the catalogue offers (wearable, or a buff's icon).
---@param itemID number
---@return boolean
function iconCatalogue.OffersItem(itemID)
    local whole = math.tointeger(itemID)
    if whole == nil then return false end
    return itemSlots.IsWearable(whole) or catalogueIcons().items[whole] ~= nil
end

--- An icon's name: an item's own, or the first ability or buff showing a sprite.
---@param spriteID integer? nil for an item.
---@param itemID integer? nil for a sprite.
---@return string? name nil if it isn't known.
function iconCatalogue.Name(spriteID, itemID)
    if itemID ~= nil then return gameApi.ItemName(itemID) end
    local entry = spriteID ~= nil and catalogueIcons().sprites[spriteID] or nil
    return entry and entry.name or nil
end

return iconCatalogue
