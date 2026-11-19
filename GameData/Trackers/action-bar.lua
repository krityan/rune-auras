-- The game's action bars (the main bar and up to four more): which ability
-- icons they show, whether the game shows each as usable, and their
-- keybinds. An ability it can't use now (the wrong weapon, a missing shield,
-- too little adrenaline for its current cost) has its icon dimmed. Read when
-- asked: the icons at most as often as the buff bar is, the keybinds at most
-- once a server tick.

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")

local actionBar = {}

-- Each bar's slots are <bar>GRAPHIC_<n> (the icon) and <bar>TEXT_<n> (the
-- keybind): the main bar, then the additional bars 2 to 5, in the order an
-- ability's first slot is picked.
local BARS = { "TOPLEVEL_V2_COMBAT_BAR__", "TOPLEVEL_V2_COMBAT_BAR2__", "TOPLEVEL_V2_COMBAT_BAR3__",
    "TOPLEVEL_V2_COMBAT_BAR4__", "TOPLEVEL_V2_COMBAT_BAR5__" }
local SLOTS = 14
-- The tint of an icon the game shows as unusable; usable ones are untinted.
local DIMMED_RGB = 0x333333
-- How often (in Logic ticks) the bars' icons are read again while asked.
-- Their keybinds only change when the player edits them, so they're read
-- again at most once a server tick.
local READ_TICKS = 10

--- One slot's component names.
---@class ActionBarSlotNames
---@field icon string
---@field keybind string

---@type ActionBarSlotNames[]? Every slot, in bar then slot order, built once.
local slotNames = nil
---@type table<integer, boolean> Sprite id to whether a shown slot has it undimmed; absent when no shown slot has it.
local usableBySprite = {}
---@type table<integer, integer> Sprite id to the first shown slot (its place in slotNames) that has it.
local firstSlotBySprite = {}
---@type table<integer, string> A shown slot's place in slotNames to its keybind; absent without one.
local keybindBySlot = {}
---@type integer? The Logic tick of the last read.
local readLogicTick = nil
---@type integer? The server tick of the last keybind read.
local keybindServerTick = nil

--- Every slot's component names.
---@return ActionBarSlotNames[]
local function names()
    if slotNames == nil then
        slotNames = {}

        for _, bar in ipairs(BARS) do
            for slot = 1, SLOTS do
                slotNames[#slotNames + 1] = { icon = bar .. "GRAPHIC_" .. slot, keybind = bar .. "TEXT_" .. slot }
            end
        end
    end

    return slotNames
end

--- A game component by name.
---@param name string
---@return userdata?
local function component(name)
    local combinedID = gameApi.Cached(gameApi.ComponentID, name)
    return combinedID and gameApi.ComponentByID(combinedID)
end

--- A slot's keybind, without markup ("c-Q" for Ctrl+Q).
---@param slot ActionBarSlotNames
---@return string? keybind nil without one.
local function slotKeybind(slot)
    local text = component(slot.keybind)
    local content = text and gameApi.TextContent(text)
    if content == nil then
        return nil
    end

    content = content:gsub("<[^>]*>", "")

    if content == "" then
        return nil
    end

    return content
end

--- Whether a slot's icon shows an item (a potion, a weapon to switch to).
--- Its sprite id is then whatever the slot last showed: an ability moved
--- off a slot that an item took leaves its sprite id there.
---@param icon userdata
---@return boolean
local function showsItem(icon)
    local itemID = gameApi.AssociatedObjectID(icon)
    return itemID ~= nil and itemID >= 0
end

--- Empties a table in place, so a read reuses it rather than making a new one.
---@param list table
local function clear(list)
    for key in pairs(list) do
        list[key] = nil
    end
end

--- Reads every shown ability slot's icon and tint, and its keybind on the
--- first read in a server tick (until then each slot keeps the keybind it
--- had). A bar that isn't shown (an additional bar turned off) or loaded is
--- skipped, and so is a slot holding an item.
local function readBars()
    local serverTick = gameClock.ServerTicks()
    local readsKeybinds = serverTick ~= keybindServerTick
    keybindServerTick = serverTick
    clear(usableBySprite)
    clear(firstSlotBySprite)

    if readsKeybinds then
        clear(keybindBySlot)
    end

    for index, slot in ipairs(names()) do
        local icon = component(slot.icon)
        local sprite = icon and gameApi.SpriteID(icon)
        if sprite ~= nil and sprite >= 0 and gameApi.IsShown(icon) and not showsItem(icon) then
            local usable = gameApi.Tint(icon) ~= DIMMED_RGB
            usableBySprite[sprite] = usableBySprite[sprite] or usable
            firstSlotBySprite[sprite] = firstSlotBySprite[sprite] or index

            if readsKeybinds then
                keybindBySlot[index] = slotKeybind(slot)
            end
        end
    end
end

--- Reads the bars again once the last read is READ_TICKS old.
local function refresh()
    local now = gameClock.LogicTick()
    if now == nil or readLogicTick == nil or now - readLogicTick >= READ_TICKS then
        readLogicTick = now
        readBars()
    end
end

--- Whether the action bars show an ability as usable: some shown slot has
--- one of its icons undimmed. An ability can have several (its greater
--- version's, a recast stage's, a conjure's command), and the bar shows
--- whichever is current.
---@param sprites integer[] The ability's icons.
---@return boolean? usable nil when no shown slot has any of them (it isn't on a bar).
function actionBar.IsUsable(sprites)
    refresh()
    local onBar = false
    for _, sprite in ipairs(sprites) do
        local usable = usableBySprite[sprite]
        if usable then
            return true
        end

        onBar = onBar or usable == false
    end

    if onBar then
        return false
    end

    return nil
end

--- The keybind of an ability's first slot on the action bars, the main bar
--- first and then the additional bars in order, by any of its icons (see
--- IsUsable).
---@param sprites integer[] The ability's icons.
---@return string? keybind nil when it isn't on a bar, or its first slot has no keybind.
function actionBar.Keybind(sprites)
    refresh()
    local first = nil
    for _, sprite in ipairs(sprites) do
        local index = firstSlotBySprite[sprite]
        if index ~= nil and (first == nil or index < first) then
            first = index
        end
    end

    return first and keybindBySlot[first]
end

--- Forgets the last read, on leaving the game.
function actionBar.Reset()
    clear(usableBySprite)
    clear(firstSlotBySprite)
    clear(keybindBySlot)
    readLogicTick, keybindServerTick = nil, nil
end

return actionBar
