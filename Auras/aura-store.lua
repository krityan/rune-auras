-- Saves and loads the player's auras in PersistentDB.
-- An aura is a table:
--   id        unique integer
--   name      shown in the aura list
--   display   display type id (see Auras/Registries/display-types)
--   source    data source id (see Auras/Registries/data-sources), nil until chosen
--   enabled   whether it is drawn
--   colour    0xRRGGBBAA
--   showText  whether to draw the value text
--   unlocked  whether it can be dragged on screen
--   anchor    anchor point id (see Auras/Helpers/anchors)
--   x, y      offset from the anchor point
--   textColour, textFont, textSize  value text style (see Auras/Helpers/fonts)
--   textTemplate  value text with placeholders (see Auras/Helpers/text-template)
--   limitDecimals, decimalsBelow  show values at or above decimalsBelow
--                 without decimals
--   group     id of the group it sits in, or nil at the top level. A group is
--             itself an aura with display "group" whose x/y move everything
--             in it (no anchor or size); its auras keep their own anchors.
--             Groups can nest.
-- plus any option the display type adds through its `defaults`.
-- Usage: local auraStore = require("Auras/aura-store")

local anchors = require("Auras/Helpers/anchors")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")
local fonts = require("Auras/Helpers/fonts")
local textTemplate = require("Auras/Helpers/text-template")

local auraStore = {}

local STORAGE_KEY = "auras"
local DEFAULT_COLOUR = 0xFFFFFFFF
auraStore.DEFAULT_COLOUR = DEFAULT_COLOUR
local DEFAULT_DISPLAY = "bar"
local GROUP_DISPLAY = "group"
auraStore.GROUP_DISPLAY = GROUP_DISPLAY
local DEFAULT_TEXT_COLOUR = 0xFFFFFFFF
-- With limitDecimals on, values at or above this many seconds show whole.
local DEFAULT_DECIMALS_BELOW = 10
-- New auras sit just below the middle of the screen.
local NEW_AURA_ANCHOR = "centre"
local NEW_AURA_X, NEW_AURA_Y = 0, 150

-- Fields holding 0xRRGGBBAA colours are named "colour" or end in "Colour".
-- PersistentDB rounds large numbers off (losing the alpha byte), so these
-- are saved as hex strings instead.
local function isColourKey(key)
    return key == "colour" or (type(key) == "string" and key:match("Colour$") ~= nil)
end

local auras = {}
local nextID = 1

-- Numbers can come back from storage as floats; the UI wants integers.
local function toInteger(value)
    local number = tonumber(value)
    if number == nil then return nil end
    return math.floor(number)
end

local function encodeColour(colour)
    return string.format("%08X", colour & 0xFFFFFFFF)
end

-- Older saves stored colours as numbers whose alpha byte was rounded away;
-- treat those as fully opaque.
local function decodeColour(value)
    if type(value) == "string" then
        return tonumber(value, 16)
    end
    local number = toInteger(value)
    if number == nil then return nil end
    return (number & 0xFFFFFF00) | 0xFF
end

local function applyDisplayDefaults(aura)
    local displayType = displayTypes.Get(aura.display)
    if displayType == nil then return end
    for key, value in pairs(displayType.module.defaults or {}) do
        if aura[key] == nil then aura[key] = value end
    end
end

-- Options that no longer exist, dropped on load so they stop being saved:
-- showInitialTick went with reading buffs off the buff bar.
local RETIRED_FIELDS = { showInitialTick = true }

local function normalize(saved)
    if type(saved) ~= "table" or toInteger(saved.id) == nil then return nil end
    -- Every other numeric aura field (id, position, sizes) is an integer.
    local aura = {}
    for key, value in pairs(saved) do
        if RETIRED_FIELDS[key] then
            -- Dropped.
        elseif isColourKey(key) then
            aura[key] = decodeColour(value)
        else
            aura[key] = type(value) == "number" and toInteger(value) or value
        end
    end
    aura.name = tostring(saved.name or "Aura")
    aura.display = displayTypes.Get(saved.display) ~= nil and saved.display or DEFAULT_DISPLAY
    aura.enabled = saved.enabled ~= false
    -- Source ids can be renamed (e.g. cooldowns now follow their var name).
    if aura.source ~= nil then aura.source = dataSources.CurrentID(aura.source) end
    aura.colour = aura.colour or DEFAULT_COLOUR
    aura.showText = saved.showText ~= false
    aura.unlocked = saved.unlocked == true
    -- Auras saved before anchors existed were positioned from the top left.
    aura.anchor = aura.anchor or anchors.DEFAULT
    aura.x = aura.x or 0
    aura.y = aura.y or 0
    aura.textColour = aura.textColour or DEFAULT_TEXT_COLOUR
    aura.textFont = aura.textFont or fonts.DEFAULT_FONT
    aura.textSize = aura.textSize or fonts.DEFAULT_SIZE
    aura.textTemplate = aura.textTemplate or textTemplate.DEFAULT
    aura.limitDecimals = saved.limitDecimals == true
    aura.decimalsBelow = aura.decimalsBelow or DEFAULT_DECIMALS_BELOW
    applyDisplayDefaults(aura)
    return aura
end

function auraStore.Load()
    auras = {}
    nextID = 1
    local saved = PersistentDB:Get(STORAGE_KEY)
    if type(saved) ~= "table" then return end
    for _, savedAura in ipairs(saved.auras or {}) do
        local aura = normalize(savedAura)
        if aura ~= nil then
            auras[#auras + 1] = aura
            nextID = math.max(nextID, aura.id + 1)
        end
    end
    nextID = math.max(nextID, toInteger(saved.nextID) or 1)
    -- A group that no longer exists (or isn't a group) can't hold auras.
    for _, aura in ipairs(auras) do
        if aura.group ~= nil and not auraStore.IsGroup(auraStore.Get(aura.group)) then
            aura.group = nil
        end
    end
end

function auraStore.Save()
    local saved = {}
    for index, aura in ipairs(auras) do
        local copy = {}
        for key, value in pairs(aura) do
            copy[key] = isColourKey(key) and encodeColour(value) or value
        end
        saved[index] = copy
    end
    PersistentDB:Set(STORAGE_KEY, {
        nextID = nextID,
        auras = saved,
    })
end

function auraStore.List()
    return auras
end

-- An aura's place in the list (its order), or nil.
local function indexOf(auraID)
    for index, aura in ipairs(auras) do
        if aura.id == auraID then return index end
    end
    return nil
end

function auraStore.Get(auraID)
    local index = indexOf(auraID)
    return index and auras[index] or nil
end

function auraStore.IsGroup(aura)
    return aura ~= nil and aura.display == GROUP_DISPLAY
end

-- The auras and groups directly inside a group (nil: the top level), in
-- list order.
function auraStore.Children(groupID)
    local children = {}
    for _, aura in ipairs(auras) do
        if aura.group == groupID then children[#children + 1] = aura end
    end
    return children
end

-- Whether `auraID` is `groupID` or one of the groups `groupID` sits in;
-- moving it there would put a group inside itself.
local function containsGroup(auraID, groupID)
    local visited = {}
    while groupID ~= nil and not visited[groupID] do
        if groupID == auraID then return true end
        visited[groupID] = true
        local group = auraStore.Get(groupID)
        groupID = group and group.group or nil
    end
    return false
end

-- Moves an aura or group dx, dy on screen through its own position. An
-- aura's offset points inwards from right/bottom anchors, hence the
-- direction; a group's x/y is a plain offset.
local function shiftBy(aura, dx, dy)
    if dx == 0 and dy == 0 then return end
    if auraStore.IsGroup(aura) then
        aura.x, aura.y = (aura.x or 0) + dx, (aura.y or 0) + dy
    else
        local directionX, directionY = anchors.Direction(aura.anchor)
        aura.x = (aura.x or 0) + directionX * dx
        aura.y = (aura.y or 0) + directionY * dy
    end
end

-- How far a group (and the groups it sits in) moves its contents: the sum
-- of their x/y. nil (the top level) moves nothing.
function auraStore.GroupOffset(groupID)
    local x, y, visited = 0, 0, {}
    while groupID ~= nil and not visited[groupID] do
        visited[groupID] = true
        local group = auraStore.Get(groupID)
        if group == nil then break end
        x, y = x + (group.x or 0), y + (group.y or 0)
        groupID = group.group
    end
    return x, y
end


-- Moves an aura or group into a group (nil: the top level), before one of
-- that group's contents (`beforeID`) or after them all (nil). Order is the
-- order of the store's list, which Children follows. Changing group keeps
-- it where it is on screen. Refuses a group that doesn't exist, moving a
-- group into itself or its own contents, and a `beforeID` that isn't in
-- the group. Returns whether anything changed.
function auraStore.Move(auraID, groupID, beforeID)
    local from = indexOf(auraID)
    if from == nil or beforeID == auraID then return false end
    local aura = auras[from]
    if groupID ~= nil then
        if not auraStore.IsGroup(auraStore.Get(groupID)) then return false end
        if containsGroup(auraID, groupID) then return false end
    end
    local before = beforeID ~= nil and auraStore.Get(beforeID) or nil
    if beforeID ~= nil and (before == nil or before.group ~= groupID) then return false end

    table.remove(auras, from)
    local to
    if before ~= nil then
        to = indexOf(beforeID)
    else
        -- After the group's last item (or at the very end if it's empty).
        to = #auras + 1
        for index = #auras, 1, -1 do
            if auras[index].group == groupID then to = index + 1 break end
        end
    end
    table.insert(auras, to, aura)

    local moved = to ~= from or aura.group ~= groupID
    if aura.group ~= groupID then
        -- Keep it where it is on screen: make up the difference between the
        -- old and new groups' offsets in its own position.
        local oldX, oldY = auraStore.GroupOffset(aura.group)
        local newX, newY = auraStore.GroupOffset(groupID)
        shiftBy(aura, oldX - newX, oldY - newY)
        aura.group = groupID
    end
    if moved then auraStore.Save() end
    return moved
end

function auraStore.Create(groupID)
    local aura = {
        id = nextID,
        name = "New aura",
        display = DEFAULT_DISPLAY,
        source = nil,
        enabled = true,
        colour = DEFAULT_COLOUR,
        showText = true,
        unlocked = false,
        anchor = NEW_AURA_ANCHOR,
        x = NEW_AURA_X,
        y = NEW_AURA_Y,
        textColour = DEFAULT_TEXT_COLOUR,
        textFont = fonts.DEFAULT_FONT,
        textSize = fonts.DEFAULT_SIZE,
        textTemplate = textTemplate.DEFAULT,
        limitDecimals = false,
        decimalsBelow = DEFAULT_DECIMALS_BELOW,
        group = groupID,
    }
    -- The usual spot below the middle of the screen can be outside a group.
    if groupID ~= nil then aura.x, aura.y = 0, 0 end
    applyDisplayDefaults(aura)
    nextID = nextID + 1
    auras[#auras + 1] = aura
    auraStore.Save()
    return aura
end

-- A new, empty group inside `groupID` (nil: the top level), not moving
-- anything yet.
function auraStore.CreateGroup(groupID)
    local group = {
        id = nextID,
        name = "New group",
        display = GROUP_DISPLAY,
        enabled = true,
        unlocked = false,
        x = 0,
        y = 0,
        group = groupID,
    }
    applyDisplayDefaults(group)
    nextID = nextID + 1
    auras[#auras + 1] = group
    auraStore.Save()
    return group
end

-- How far a copy is nudged from its original, so it doesn't sit exactly on
-- top of it.
local DUPLICATE_OFFSET = 10

-- Nudges an offset by DUPLICATE_OFFSET, the other way if that would leave
-- the range that keeps the aura on screen.
local function nudge(offset, minimum, maximum)
    local nudged = offset + DUPLICATE_OFFSET
    if maximum ~= nil and nudged > maximum then nudged = offset - DUPLICATE_OFFSET end
    if minimum ~= nil then nudged = math.max(minimum, nudged) end
    if maximum ~= nil then nudged = math.min(maximum, nudged) end
    return nudged
end

-- Copies an aura with all its settings into a new one, listed right after
-- the original. areaWidth/areaHeight, the game area's size if known, keep
-- the copy's offset on screen. Returns the copy, or nil if the aura doesn't
-- exist.
function auraStore.Duplicate(auraID, areaWidth, areaHeight)
    local index = indexOf(auraID)
    if index == nil then return nil end
    local original = auras[index]
    -- Every aura field is a plain value, so a shallow copy is a full one.
    local copy = {}
    for key, value in pairs(original) do copy[key] = value end
    copy.id = nextID
    copy.name = original.name .. " copy"
    copy.unlocked = false
    local minX, maxX, minY, maxY
    if areaWidth ~= nil and areaHeight ~= nil then
        minX, maxX, minY, maxY = anchors.OffsetRange(original.anchor,
            original.width or 0, original.height or 0, areaWidth, areaHeight)
    end
    copy.x = nudge(original.x or 0, minX, maxX)
    copy.y = nudge(original.y or 0, minY, maxY)
    nextID = nextID + 1
    table.insert(auras, index + 1, copy)
    auraStore.Save()
    return copy
end

-- Deleting a group keeps what was in it, moving it up a level without
-- moving it on screen. areaWidth/areaHeight, the game area's size if known,
-- are needed for that when the group is at the top level.
function auraStore.Delete(auraID)
    local index = indexOf(auraID)
    if index == nil then return false end
    local aura = auras[index]
    if auraStore.IsGroup(aura) then
        -- Its contents move up a level and stay where they are on screen,
        -- taking on the group's own offset.
        for _, child in ipairs(auras) do
            if child.group == auraID then
                child.group = aura.group
                shiftBy(child, aura.x or 0, aura.y or 0)
            end
        end
    end
    table.remove(auras, index)
    auraStore.Save()
    return true
end

-- Switching display type fills in the new type's option defaults.
function auraStore.Set(auraID, key, value)
    local aura = auraStore.Get(auraID)
    if aura == nil then return nil end
    if key == "display" and value ~= aura.display then
        -- Options mean different things per display type (a bar is wide, an
        -- icon square with a thinner border), so take all of the new type's
        -- defaults rather than keeping the old type's values.
        local displayType = displayTypes.Get(value)
        for option, default in pairs(displayType and displayType.module.defaults or {}) do
            aura[option] = default
        end
    end
    aura[key] = value
    if key == "display" then applyDisplayDefaults(aura) end
    auraStore.Save()
    return aura
end

return auraStore
