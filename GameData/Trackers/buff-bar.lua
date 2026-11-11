-- The game's buff bar: which buff icons it shows, and the time left under
-- each, for the few buffs whose vars can't say they've ended early (see
-- BuffEntry.endsOffBuffBar). Those buffs must be shown in the bar: one the
-- player hides in its settings reads as ended. Read when asked, at most as
-- often as the bar redraws.

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")

local buffBar = {}

-- The bar's slots, BUFF_BAR__BUFF_1 to _50. A filled slot holds a few
-- components the game makes, the first sprite among them the buff's icon
-- and a text its time left; empty slots hold none, and filled ones needn't
-- be together.
local SLOT_PREFIX = "BUFF_BAR__BUFF_"
local SLOT_COUNT = 50
-- How often (in Logic ticks) the bar redraws: on its own clock, not the
-- server tick's, so a change can show at any point in a server tick.
local REDRAW_TICKS = 10

---@type string[]? The slots' component names, built once.
local slotNames = nil

-- How many seconds each unit a timer text can end with stands for; a bare
-- number is seconds.
local SECONDS_PER_UNIT = { s = 1, m = 60, h = 3600 }
-- What ShownSeconds gives for an icon the bar doesn't show.
local NONE_SHOWN = {}

-- What the bar showed at its last read, by sprite id and by item id: for
-- each icon, the seconds left in each slot showing it (false where no time
-- could be read).
---@type table<integer, (number|false)[]>
local shownSprites, shownItems = {}, {}
-- Whether the bar could be read at its last read.
local isLoaded = false
---@type integer? The Logic tick of the last read.
local readLogicTick = nil

-- What's been found in the slot being read (see noteComponent): its icon,
-- and the seconds its time left shows.
local foundSprite, foundItem = nil, nil
local foundSeconds = nil

--- The seconds a slot's timer text shows: whole seconds under a minute
--- ("57"), else whole units ("1m"). A buff without a timer shows its
--- stacks or charges there instead.
---@param text string
---@return number? seconds nil if it isn't a number.
local function timerSeconds(text)
    local count, unit = text:gsub("<[^>]*>", ""):match("^%s*(%d+)%s*([hms]?)%s*$")
    if count == nil then return nil end
    return tonumber(count) * (SECONDS_PER_UNIT[unit] or 1)
end

--- Notes what one of a slot's components shows: the first sprite
--- component's sprite (or the item it shows in place of one) is the icon,
--- and the first text that reads as a number is the time left.
---@param child userdata
---@return boolean stop Always false, so every component is seen.
local function noteComponent(child)
    local sprite = gameApi.SpriteID(child)
    if sprite ~= nil then
        if foundSprite == nil and foundItem == nil then
            if sprite >= 0 then
                foundSprite = sprite
            else
                local itemID = gameApi.AssociatedObjectID(child)
                if itemID ~= nil and itemID >= 0 then foundItem = itemID end
            end
        end
        return false
    end
    local text = gameApi.TextContent(child)
    if text ~= nil and foundSeconds == nil then foundSeconds = timerSeconds(text) end
    return false
end

--- Adds a slot's time left to an icon's list.
---@param shown table<integer, (number|false)[]> shownSprites or shownItems.
---@param icon integer
local function noteShown(shown, icon)
    local slots = shown[icon]
    if slots == nil then
        slots = {}
        shown[icon] = slots
    end
    slots[#slots + 1] = foundSeconds or false
end

--- One of the bar's slot components.
---@param index integer 1 to SLOT_COUNT.
---@return userdata? slot nil while the bar isn't loaded.
local function slotComponent(index)
    if slotNames == nil then
        slotNames = {}
        for slotIndex = 1, SLOT_COUNT do slotNames[slotIndex] = SLOT_PREFIX .. slotIndex end
    end
    local combinedID = gameApi.Cached(gameApi.ComponentID, slotNames[index])
    return combinedID and gameApi.ComponentByID(combinedID)
end

--- Reads the icons the bar shows into shownSprites and shownItems. It's
--- only read while a buff that ends off it is running, so a bar showing
--- nothing is taken as closed rather than empty.
---@return boolean loaded Whether the bar could be read and shows anything.
local function readIcons()
    shownSprites, shownItems = {}, {}
    local showsAny = false
    for index = 1, SLOT_COUNT do
        local slot = slotComponent(index)
        if slot == nil then return false end
        foundSprite, foundItem, foundSeconds = nil, nil, nil
        gameApi.EachDynamicChild(slot, noteComponent)
        if foundSprite ~= nil then
            noteShown(shownSprites, foundSprite)
            showsAny = true
        elseif foundItem ~= nil then
            noteShown(shownItems, foundItem)
            showsAny = true
        end
    end
    return showsAny
end

--- Reads the bar again once it may have redrawn since the last read (see
--- REDRAW_TICKS); until then the last read stands.
local function refresh()
    local now = gameClock.LogicTick()
    local isRecent = now ~= nil and readLogicTick ~= nil and now - readLogicTick < REDRAW_TICKS
    if isRecent then return end
    readLogicTick = now
    isLoaded = readIcons()
end

--- The time left in each slot the buff bar shows an icon in.
---@param sprite integer? The buff's sprite icon.
---@param itemID integer? The item it shows instead, for a buff without a sprite.
---@return (number|false)[]? seconds One per slot showing it (false where no time could be read), empty when none does; nil while the bar can't say (not loaded, or showing nothing). Callers share the list, so they mustn't change it.
function buffBar.ShownSeconds(sprite, itemID)
    refresh()
    if not isLoaded then return nil end
    local shown, icon = shownSprites, sprite
    if sprite == nil then shown, icon = shownItems, itemID end
    if icon == nil then return nil end
    return shown[icon] or NONE_SHOWN
end

--- Whether the buff bar has dropped a buff's icon: the bar is loaded and
--- doesn't show it. Buffs that share an icon can't be told apart here, so
--- one showing keeps the others.
---@param sprite integer? The buff's sprite icon.
---@param itemID integer? The item it shows instead, for a buff without a sprite.
---@return boolean
function buffBar.HasDropped(sprite, itemID)
    local shown = buffBar.ShownSeconds(sprite, itemID)
    return shown ~= nil and #shown == 0
end

--- Forgets the last read, on leaving the game.
function buffBar.Reset()
    shownSprites, shownItems = {}, {}
    isLoaded, readLogicTick = false, nil
end

return buffBar
